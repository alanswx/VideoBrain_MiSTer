--------------------------------------------------------------------------------
-- VideoBrain unified CPU-side memory bus
--------------------------------------------------------------------------------
-- Reference: kevtris "Videobrain Unwrapped" V0.05, "Address Space" / "CPU
--            Bus" section. uv202_pack's ADDR_*/cpu_addr_fold.
--------------------------------------------------------------------------------
--
-- WHY THIS MODULE EXISTS: f8_busif drives a generic ext_addr/ext_rd/ext_wr/
-- ext_wdata/ext_rdata interface (see f8_busif.vhd header) but has no idea
-- what's actually on the other end of it. uv202_arbiter separately decides
-- WHEN an access may proceed (wait-stating) but doesn't touch data at all.
-- Neither module can be exercised meaningfully without something that
-- decodes ext_addr and actually returns/stores a byte. This is that
-- something: a combinational read mux + per-device write-enable demux over
-- RES1 ROM, RES2 ROM, 1K system RAM, the UV201 register file, and a
-- cartridge stub.
--
-- SCOPE (MVP):
--   - RES1/RES2: modeled as plain arrays, contents all-zero. No ROM image
--     loading mechanism exists yet (MiSTer-style loader / init-file is a
--     top-level integration concern, not this module's job) - TODO,
--     non-blocking for bring-up work that doesn't depend on real ROM
--     contents (register/DMA/timing bring-up).
--   - RAM: 1K (0x0C00-0x0FFF), combinational read / registered write.
--     Real hardware is 8x 2102 (async SRAM); modeling it as combinational-
--     read here assumes the wait-state handshake (ext_req/ext_grant in
--     f8_busif, already flagged unverified there) has already burned
--     enough cycles that memory access itself can be zero-latency from
--     this module's point of view. If/when RAM gets inferred as real
--     block RAM with registered read, that adds exactly the 1-cycle
--     latency the arbiter's still-undecided ST_DONE timing (STATUS.md
--     open decision #4) was already weighing - worth resolving both
--     together rather than separately.
--   - UV201 registers: routed to uv201_regs.vhd (separate module, already
--     written) via its reg_addr/reg_we/reg_wdata/reg_rdata port.
--   - Cartridge: stub only. Reads return 0xFF (matches kevtris's own note
--     about open-bus/pulldown behavior being implementation-defined - 0xFF
--     rather than his 0x00 perf-board choice is arbitrary and doesn't
--     matter for MVP bring-up); writes are dropped. Real cartridge slot
--     modeling (ROM sizes, bankswitching, RAM-in-cart per the doc's
--     0900-0BFF note) is out of scope here - a future
--     videobrain_cart_slot.vhd, not this file's job.
--   - Buffered-bus (what the UV201 DMA fetcher sees, per the doc's
--     "Buffered Bus" section) is NOT modeled here at all - this module is
--     CPU-side only. The fetcher (not yet written) will need its own,
--     narrower 8K-address-space view of RES2/RAM/cart; deliberately not
--     retrofitted onto this entity's interface preemptively since we don't
--     yet know what shape uv201_fetcher.vhd wants it in.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY sys_bus IS
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    -- f8_busif side (see f8_busif.vhd ext_* ports)
    ext_addr  : IN  unsigned(13 DOWNTO 0);
    ext_rd    : IN  std_logic;
    ext_wr    : IN  std_logic;
    ext_wdata : IN  uv8;
    ext_rdata : OUT uv8;

    -- UV201 status-register inputs, passed straight through to
    -- uv201_regs.vhd (see that entity for why these exist)
    uv_cur_field   : IN std_logic;
    uv_cur_vpos    : IN unsigned(8 DOWNTO 0);
    uv_capture_stb : IN std_logic;
    uv_capture_x   : IN uv8;

    -- UV201 command-register bit taps and object-RAM read port, passed
    -- straight through from uv201_regs.vhd for consumption by the (not yet
    -- written) fetcher/renderer and by videobrain_top.vhd
    uv_o_x_zm   : OUT std_logic;
    uv_o_frz    : OUT std_logic;
    uv_o_enb    : OUT std_logic;
    uv_o_int    : OUT std_logic;
    uv_o_kbd    : OUT std_logic;
    uv_o_y_zm   : OUT std_logic;
    uv_o_a_b    : OUT std_logic;
    uv_o_yint_ho: OUT std_logic;
    uv_y_int    : OUT uv8;

    uv_obj_addr  : IN  uv8;
    uv_obj_rdata : OUT uv8
    );
END ENTITY sys_bus;

ARCHITECTURE rtl OF sys_bus IS

  SIGNAL a_eff : unsigned(13 DOWNTO 0);

  -- RES1: 0000-07FF (2K), zero-wait, not gated by ext_rd/ext_wr - always
  -- driven from address, matching the "RES1 doesn't route through the
  -- arbiter" decision in f8_busif.classify().
  TYPE rom_t IS ARRAY (0 TO 2047) OF uv8;
  SIGNAL res1_rom : rom_t := (OTHERS => (OTHERS => '0'));  -- TODO: load image
  SIGNAL res2_rom : rom_t := (OTHERS => (OTHERS => '0'));  -- TODO: load image

  -- system RAM: 0C00-0FFF (1K)
  TYPE ram_t IS ARRAY (0 TO 1023) OF uv8;
  SIGNAL sys_ram : ram_t := (OTHERS => (OTHERS => '0'));

  SIGNAL uv_reg_addr  : uv8;
  SIGNAL uv_reg_we    : std_logic;
  SIGNAL uv_reg_wdata : uv8;
  SIGNAL uv_reg_rdata : uv8;

  SIGNAL rdata_l : uv8;

BEGIN

  a_eff <= cpu_addr_fold(ext_addr);

  ----------------------------------------------------------------------------
  -- UV201 register file instance
  ----------------------------------------------------------------------------

  u_uv201_regs : ENTITY work.uv201_regs
    PORT MAP (
      clk         => clk,
      reset_na    => reset_na,
      reg_addr    => uv_reg_addr,
      reg_we      => uv_reg_we,
      reg_wdata   => uv_reg_wdata,
      reg_rdata   => uv_reg_rdata,
      cur_field   => uv_cur_field,
      cur_vpos    => uv_cur_vpos,
      capture_stb => uv_capture_stb,
      capture_x   => uv_capture_x,
      o_x_zm      => uv_o_x_zm,
      o_frz       => uv_o_frz,
      o_enb       => uv_o_enb,
      o_int       => uv_o_int,
      o_kbd       => uv_o_kbd,
      o_y_zm      => uv_o_y_zm,
      o_a_b       => uv_o_a_b,
      o_yint_ho   => uv_o_yint_ho,
      y_int       => uv_y_int,
      obj_addr    => uv_obj_addr,
      obj_rdata   => uv_obj_rdata
      );

  uv_reg_addr  <= std_logic_vector(a_eff(7 DOWNTO 0));
  uv_reg_we    <= ext_wr WHEN (a_eff >= to_unsigned(ADDR_UV201_LO, 14) AND
                                a_eff <= to_unsigned(ADDR_UV201_HI, 14))
                  ELSE '0';
  uv_reg_wdata <= ext_wdata;

  ----------------------------------------------------------------------------
  -- RAM write (registered). Read is combinational, folded into rdata mux
  -- below - see MVP scope note at top of file re: latency.
  ----------------------------------------------------------------------------

  PROCESS (clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      NULL;  -- RAM contents undefined on real hardware after reset too
              -- (see doc: signature-byte-guarded clear routine runs at
              -- boot); not resetting the array avoids a large synth-time
              -- reset fan-out for no behavioral benefit.
    ELSIF rising_edge(clk) THEN
      IF ext_wr = '1' AND a_eff >= to_unsigned(ADDR_RAM_LO, 14)
                       AND a_eff <= to_unsigned(ADDR_RAM_HI, 14) THEN
        sys_ram(to_integer(a_eff - to_unsigned(ADDR_RAM_LO, 14))) <= ext_wdata;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- read mux (combinational)
  ----------------------------------------------------------------------------

  PROCESS (a_eff, res1_rom, res2_rom, sys_ram, uv_reg_rdata) IS
  BEGIN
    IF a_eff <= to_unsigned(ADDR_RES1_HI, 14) THEN
      rdata_l <= res1_rom(to_integer(a_eff));

    ELSIF a_eff <= to_unsigned(ADDR_UV201_HI, 14) THEN
      rdata_l <= uv_reg_rdata;

    ELSIF a_eff <= to_unsigned(ADDR_CART1_HI, 14) THEN
      rdata_l <= (OTHERS => '1');  -- cartridge-mapped window stub, open bus

    ELSIF a_eff <= to_unsigned(ADDR_RAM_HI, 14) THEN
      rdata_l <= sys_ram(to_integer(a_eff - to_unsigned(ADDR_RAM_LO, 14)));

    ELSIF a_eff <= to_unsigned(ADDR_CART2_HI, 14) THEN
      rdata_l <= (OTHERS => '1');  -- cartridge ROM stub, open bus

    ELSIF a_eff <= to_unsigned(ADDR_RES2_HI, 14) THEN
      rdata_l <= res2_rom(to_integer(a_eff - to_unsigned(ADDR_RES2_LO, 14)));

    ELSE
      rdata_l <= (OTHERS => '1');  -- unreachable after mirror fold
    END IF;
  END PROCESS;

  ext_rdata <= rdata_l;

END ARCHITECTURE rtl;
