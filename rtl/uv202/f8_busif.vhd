--------------------------------------------------------------------------------
-- VideoBrain F8 bus interface (f8_busif)
--------------------------------------------------------------------------------
-- Reference: MiSTer ChannelF_MiSTer rtl/chf/f8_psu.vhd (ROMC state machine
--            and PC0/PC1/DC0 register behavior - VideoBrain does not use a
--            3851 PSU, so this module reimplements only the address-
--            tracking half of f8_psu, with the local-ROM/IO-port/interrupt-
--            priority-chain half removed and replaced by an external bus
--            request to sys_bus, mediated by uv202_arbiter.)
--            kevtris "Videobrain Unwrapped" V0.05, "Address Space" section.
--------------------------------------------------------------------------------
--
-- WHY THIS MODULE EXISTS: f8_cpu.vhd (the bare F3850 core) has no address
-- registers of its own - on real F8 systems PC0/PC1/DC0 live in whichever
-- peripheral chip is decoding ROMC states (the 3851 PSU on Channel F).
-- VideoBrain uses a bare 3850 + external RAM/ROM/cartridge/UV201 instead of
-- a 3851, so nothing in the existing Channel F tree tracks PC0/PC1/DC0 the
-- way our system needs (routed to a real 14-bit address bus, not a local
-- ROM). This module is that missing piece: it is a straight copy of
-- f8_psu's ROMC case statement (same states, same PC0/PC1/DC0 semantics)
-- with `mem`/IO-port/interrupt-priority-chain logic stripped out and
-- replaced by ext_addr/ext_rd/ext_wr/ext_wdata/ext_rdata talking to
-- sys_bus.vhd.
--
-- *** SCOPE / KNOWN GAPS (non-blocking, flagged for later work) ***
--
-- 1. INTERRUPTS: f8_cpu.vhd, as pulled from ChannelF_MiSTer, has NO
--    interrupt input at all - romc selection there depends only on
--    bcc/test/opcode, never on an external int-pending signal. Channel F
--    apparently doesn't need this (or handles it elsewhere in a way we
--    haven't looked at yet). VideoBrain uses Y-interrupts fairly
--    routinely (UV201 ext_int -> F3853 SMI -> CPU). This is a genuine
--    gap: either f8_cpu.vhd needs an interrupt-request input added (ROMC
--    01111/10011 forced-entry, per the F8 architecture manual), or we
--    need to confirm some other mechanism. NOT implemented here. Does
--    not block CPU/UV201 register or DMA bring-up, which don't require
--    interrupts to validate.
--
-- 2. WAIT-STATE HANDSHAKE TIMING IS UNVERIFIED IN SIMULATION. The
--    scheme below: on phase=1 (before f8_psu-equivalent behavior would
--    sample/drive at phase=2), or on phase=4 before the phase=6 write
--    commit, if the address about to be touched is in a "slow" region,
--    busif asserts `ext_req`/`ext_class`/`ext_addr` and the *external*
--    ce gating (owned by uv202_top, not this module) holds the shared
--    `ce` low until uv202_arbiter's `cpu_grant` pulse arrives, at which
--    point ce resumes for exactly the cycle where phase advances past
--    the point that needs ext_rdata/ext_wdata. This should work given
--    f8_cpu/f8_psu's existing ce-gating convention (freezing phase
--    entirely when ce=0, matching real hardware's "CPU stopped, waits
--    inserted" description) - but the exact phase numbers used below
--    (1 vs 2, 4 vs 6) are inferred from f8_psu's existing phase=2/
--    phase=6 convention, not independently re-derived, and have NOT
--    been bench/sim-verified against real ROMC timing. Flagging
--    explicitly rather than presenting as settled. This needs its own
--    testbench (feed known ROMC/phase sequences, check ext_req/ext_addr
--    line up) before being trusted for real code.
--
-- Both gaps are isolated to this file's internals; nothing about
-- sys_bus's or uv202_arbiter's interfaces needs to change to fix either.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.f8_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY f8_busif IS
  PORT (
    -- F8 shared bus (see f8_cpu.vhd / f8_psu.vhd / channel_f.vhd for the
    -- bus-mux convention: `dw` in = current shared bus value, `dr`/`dv`
    -- out = this device's contribution, muxed externally with priority)
    dw       : IN  uv8;
    dr       : OUT uv8;
    dv       : OUT std_logic;

    romc     : IN  uv5;
    tick     : IN  std_logic;
    phase    : IN  uint4;

    clk      : IN  std_logic;
    ce       : IN  std_logic;   -- gated externally by uv202_top for wait states
    reset_na : IN  std_logic;

    -- external unified memory bus (sys_bus.vhd)
    ext_addr  : OUT unsigned(13 DOWNTO 0);  -- 14-bit CPU-side address
    ext_rd    : OUT std_logic;
    ext_wr    : OUT std_logic;
    ext_wdata : OUT uv8;
    ext_rdata : IN  uv8;

    -- wait-state request to uv202_arbiter. Asserted combinationally one
    -- cycle ahead of the point where ext_rdata/ext_wdata must be valid;
    -- see gap #2 above regarding exact phase alignment.
    ext_req   : OUT std_logic;
    ext_class : OUT bus_access_t;
    ext_grant : IN  std_logic;   -- 1-cycle pulse from uv202_arbiter.cpu_grant

    -- debug/status taps
    pc0o     : OUT uv16;
    pc1o     : OUT uv16;
    dc0o     : OUT uv16
    );
END ENTITY f8_busif;

ARCHITECTURE rtl OF f8_busif IS

  SIGNAL dc0, pc0, pc1 : uv16 := (OTHERS => '0');
  SIGNAL dr_l : uv8 := (OTHERS => '0');
  SIGNAL dv_l : std_logic := '0';

  SIGNAL ext_req_l   : std_logic := '0';
  SIGNAL ext_class_l : bus_access_t := ACC_NONE;
  SIGNAL ext_addr_l  : unsigned(13 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ext_rd_l    : std_logic := '0';
  SIGNAL ext_wr_l    : std_logic := '0';
  SIGNAL ext_wdata_l : uv8 := (OTHERS => '0');

  -- classify a 14-bit CPU-side address into its wait-state bucket and
  -- whether it's read or write access, per doc "Address Space" section
  -- and uv202_pack's ADDR_* constants. The 2800-3FFF mirror of 0800-1FFF
  -- is folded via the shared uv202_pack.cpu_addr_fold() (also used by
  -- sys_bus, so the wait-class decision here and the device-routing
  -- decision there can't drift apart); the wider 4000-FFFF mirrors happen
  -- naturally because only PC0/DC0 bits 13:0 reach this function.
  --
  -- RESOLVED (was STATUS.md open decision #1): RES1 and RES2 used to share
  -- ACC_NONE, silently giving RES2 RES1's 0-wait treatment even though the
  -- doc lists 4-6 BRCLK for RES2. They're now distinct: RES1 stays
  -- ACC_NONE (genuinely 0-wait, bypasses uv202_arbiter's request path
  -- entirely) and RES2 is ACC_RES2 (routed through the arbiter, which
  -- gives it the same 3-cycle body as RAM/cart via its `OTHERS` case).
  FUNCTION classify(a : unsigned(13 DOWNTO 0); is_write : std_logic)
    RETURN bus_access_t IS
    VARIABLE a_eff : unsigned(13 DOWNTO 0) := cpu_addr_fold(a);
    VARIABLE result : bus_access_t;
  BEGIN
    -- NOTE: assigning through a variable here (rather than
    -- `RETURN x WHEN c ELSE y;` directly) is deliberate, not stylistic -
    -- GHDL 4.1 rejects the conditional-expression form inside a return
    -- statement even under --std=08, but accepts the identical expression
    -- as a variable assignment. Confirmed by isolated test against this
    -- exact GHDL version; keeping this pattern anywhere else a
    -- `RETURN ... WHEN ... ELSE ...;` is written in this codebase.
    IF a_eff < to_unsigned(ADDR_UV201_LO, 14) THEN
      result := ACC_NONE;   -- RES1, 0-wait, not classified as a slow access
    ELSIF a_eff <= to_unsigned(ADDR_UV201_HI, 14) THEN
      result := ACC_UV201_WR WHEN is_write = '1' ELSE ACC_UV201_RD;
    ELSIF a_eff <= to_unsigned(ADDR_CART1_HI, 14) THEN
      result := ACC_CART_WR WHEN is_write = '1' ELSE ACC_CART_RD;
    ELSIF a_eff <= to_unsigned(ADDR_RAM_HI, 14) THEN
      result := ACC_RAM_WR WHEN is_write = '1' ELSE ACC_RAM_RD;
    ELSIF a_eff <= to_unsigned(ADDR_CART2_HI, 14) THEN
      result := ACC_CART_WR WHEN is_write = '1' ELSE ACC_CART_RD;
    ELSIF a_eff <= to_unsigned(ADDR_RES2_HI, 14) THEN
      result := ACC_RES2;
    ELSE
      result := ACC_NONE;   -- unreachable for a 14-bit address after mirror fold
    END IF;
    RETURN result;
  END FUNCTION;

BEGIN

  ----------------------------------------------------------------------------
  -- ROMC state machine: PC0/PC1/DC0 tracking, identical semantics to
  -- f8_psu.vhd's process, with `mem`-array reads replaced by ext_rdata
  -- and the address-space check (`pchk` in f8_psu) replaced by
  -- classify()/ext_req handshaking. States that don't touch memory
  -- (register-only PC0/PC1/DC0 moves) behave exactly as in f8_psu and
  -- need no external bus interaction at all.
  ----------------------------------------------------------------------------

  PROCESS(clk, reset_na) IS
    VARIABLE addr_v    : unsigned(13 DOWNTO 0);
    VARIABLE is_write_v : std_logic;
    VARIABLE cls_v      : bus_access_t;
  BEGIN
    IF reset_na = '0' THEN
      pc0 <= (OTHERS => '0');
      pc1 <= (OTHERS => '0');
      dc0 <= (OTHERS => '0');
      dr_l <= (OTHERS => '0');
      dv_l <= '0';
      ext_req_l <= '0';
      ext_rd_l  <= '0';
      ext_wr_l  <= '0';

    ELSIF rising_edge(clk) THEN
      IF ce = '1' THEN
        IF phase = 2 THEN
          dv_l <= '0';
        END IF;
        ext_rd_l <= '0';
        ext_wr_l <= '0';

        CASE romc IS
          ----------------------------------------------------------------
          -- Address-generating states requiring an external memory read:
          -- 00000 IFETCH (PC0), 00001 immediate-w/-adj (PC0),
          -- 00010 DC0 read+incr, 00011 immediate operand (PC0),
          -- 01100 PC0 read -> PC0lo, 01110 PC0 read -> DC0lo,
          -- 10001 PC0 read -> DC0hi
          ----------------------------------------------------------------
          WHEN "00000" =>
            IF phase = 1 THEN
              addr_v := pc0(13 DOWNTO 0);
              cls_v  := classify(addr_v, '0');
              IF cls_v /= ACC_NONE THEN
                ext_req_l   <= '1';
                ext_class_l <= cls_v;
                ext_addr_l  <= addr_v;
              END IF;
            END IF;
            IF phase = 2 THEN
              ext_req_l <= '0';
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
              ext_addr_l <= pc0(13 DOWNTO 0);
            END IF;
            IF phase = 6 THEN
              pc0 <= pc0 + 1;
            END IF;

          WHEN "00001" =>
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
              ext_addr_l <= pc0(13 DOWNTO 0);
            END IF;
            IF phase = 6 THEN
              pc0 <= pc0 + sext(dw, 16);
            END IF;

          WHEN "00010" =>
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
              ext_addr_l <= dc0(13 DOWNTO 0);
            END IF;
            IF phase = 6 THEN
              dc0 <= dc0 + 1;
            END IF;

          WHEN "00011" =>
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
              ext_addr_l <= pc0(13 DOWNTO 0);
            END IF;
            IF phase = 6 THEN
              pc0 <= pc0 + 1;
            END IF;

          WHEN "00100" =>
            IF phase = 6 THEN
              pc0 <= pc1;
            END IF;

          WHEN "00101" =>
            -- store dw into [DC0], increment DC0 (RAM write path)
            IF phase = 4 THEN
              cls_v := classify(dc0(13 DOWNTO 0), '1');
              IF cls_v /= ACC_NONE THEN
                ext_req_l   <= '1';
                ext_class_l <= cls_v;
                ext_addr_l  <= dc0(13 DOWNTO 0);
                ext_wdata_l <= dw;
              END IF;
            END IF;
            IF phase = 6 THEN
              ext_req_l <= '0';
              ext_wr_l  <= '1';
              ext_wdata_l <= dw;
              ext_addr_l  <= dc0(13 DOWNTO 0);
              dc0 <= dc0 + 1;
            END IF;

          WHEN "00110" =>
            IF phase = 2 THEN
              dr_l <= dc0(15 DOWNTO 8);
              dv_l <= '1';
            END IF;

          WHEN "00111" =>
            IF phase = 2 THEN
              dr_l <= pc1(15 DOWNTO 8);
              dv_l <= '1';
            END IF;

          WHEN "01000" =>
            IF phase = 6 THEN
              pc1 <= pc0;
              pc0 <= x"0000";
            END IF;

          WHEN "01001" =>
            IF phase = 2 THEN
              dr_l <= dc0(7 DOWNTO 0);
              dv_l <= '1';
            END IF;

          WHEN "01010" =>
            IF phase = 6 THEN
              dc0 <= dc0 + sext(dw, 16);
            END IF;

          WHEN "01011" =>
            IF phase = 2 THEN
              dr_l <= pc1(7 DOWNTO 0);
              dv_l <= '1';
            END IF;

          WHEN "01100" =>
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
              ext_addr_l <= pc0(13 DOWNTO 0);
            END IF;
            IF phase = 6 THEN
              pc0(7 DOWNTO 0) <= dw;
            END IF;

          WHEN "01101" =>
            pc1 <= pc0 + 1;

          WHEN "01110" =>
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
              ext_addr_l <= pc0(13 DOWNTO 0);
            END IF;
            IF phase = 6 THEN
              dc0(7 DOWNTO 0) <= dw;
            END IF;

          -- 01111 (interrupt vector low) / 10011 (interrupt vector high):
          -- NOT implemented - see gap #1 above. int_req_l tied low means
          -- these states, if ever entered, will simply not drive dr/dv
          -- from this module.

          WHEN "10001" =>
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
              ext_addr_l <= pc0(13 DOWNTO 0);
            END IF;
            IF phase = 6 THEN
              dc0(15 DOWNTO 8) <= dw;
            END IF;

          WHEN "10010" =>
            IF phase = 6 THEN
              pc1 <= pc0;
              pc0(7 DOWNTO 0) <= dw;
            END IF;

          WHEN "10100" =>
            IF phase = 6 THEN
              pc0(15 DOWNTO 8) <= dw;
            END IF;

          WHEN "10101" =>
            IF phase = 6 THEN
              pc1(15 DOWNTO 8) <= dw;
            END IF;

          WHEN "10110" =>
            IF phase = 6 THEN
              dc0(15 DOWNTO 8) <= dw;
            END IF;

          WHEN "10111" =>
            IF phase = 6 THEN
              pc0(7 DOWNTO 0) <= dw;
            END IF;

          WHEN "11000" =>
            IF phase = 6 THEN
              pc1(7 DOWNTO 0) <= dw;
            END IF;

          WHEN "11001" =>
            IF phase = 6 THEN
              dc0(7 DOWNTO 0) <= dw;
            END IF;

          WHEN "11110" =>
            IF phase = 2 THEN
              dr_l <= pc0(7 DOWNTO 0);
              dv_l <= '1';
            END IF;

          WHEN "11111" =>
            IF phase = 2 THEN
              dr_l <= pc0(15 DOWNTO 8);
              dv_l <= '1';
            END IF;

          WHEN OTHERS =>
            NULL;   -- 10000 (priority inhibit), 11010/11011/11100 (I/O port,
                     -- N/A - VideoBrain's IO ports 0/1 are handled by the
                     -- keyboard/sound glue, not this module), 11101 (DC0/
                     -- DC1 swap, no DC1 register modeled - matches f8_psu)

        END CASE;

        IF reset_na = '0' THEN
          pc0 <= x"0000";
          pc1 <= x"0000";
          dc0 <= x"0000";
        END IF;
      END IF;
    END IF;
  END PROCESS;

  dr <= dr_l;
  dv <= dv_l;

  ext_addr  <= ext_addr_l;
  ext_rd    <= ext_rd_l;
  ext_wr    <= ext_wr_l;
  ext_wdata <= ext_wdata_l;
  ext_req   <= ext_req_l;
  ext_class <= ext_class_l;

  pc0o <= pc0;
  pc1o <= pc1;
  dc0o <= dc0;

END ARCHITECTURE rtl;
