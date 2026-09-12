--------------------------------------------------------------------------------
-- VideoBrain UV202 - wait-state / DMA arbiter (MVP)
--------------------------------------------------------------------------------
-- Reference: kevtris "Videobrain Unwrapped" V0.05, section "Wait States"
--------------------------------------------------------------------------------
--
-- SCOPE (MVP): this module implements the *structure* of UV202's bus
-- arbitration - CPU access classification, wait insertion, DMA request/grant
-- handshake - using the doc's simpler "sunk cost" table rather than the
-- fully cycle-exact model (modulo-4 UV201-read stretch, DMA-collision
-- setup-penalty doubling, the 48-BRCLK breakover point in the fetcher's own
-- cycle accounting). Those refinements belong here eventually, but they are
-- an ACCURACY upgrade to this module's internals, not a change to its
-- interface - nothing outside uv202_arbiter needs to change when we tighten
-- the timing later. Marking this explicitly so it's clear this is not a
-- structural placeholder, just a lower-fidelity implementation of the same
-- contract.
--
-- Fixed durations produced by this MVP state machine (all in BRCLKs):
--   RAM/cart read or write      : 1 setup + 3 body + 1 done/grant = 5
--   UV201 register read/write   : 1 setup + 5 body + 1 done/grant = 7
--   DMA fetch (per byte)        : 1 setup + 3 body + 1 done/grant = 5
--
-- The source doc's low-end access costs are 4 BRCLK for RAM/cart/DMA and
-- 6 BRCLK for UV201. This implementation is one BRCLK longer because
-- ST_DONE is a separate state in which the grant pulse is issued. Keep that
-- discrepancy explicit until a testbench establishes whether ST_DONE should
-- be folded into the final ST_BODY cycle.
--
-- *** TODO (non-blocking): replace fixed UV201-read duration with the
-- *** modulo-4 brclk_phase-dependent stretch (5/6/7/8 BRCLK per the doc's
-- *** "UV201 register reads" section) once uv202_clkgen's brclk_phase
-- *** output is wired in here. Also replace fixed DMA body duration with
-- *** dmacycles = (3*spritewidth)+1 once uv201_fetcher exists and can
-- *** supply spritewidth per fetch. Interface (wack/dmareq/cpu stall)
-- *** does not change.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY uv202_arbiter IS
  PORT (
    clk        : IN  std_logic;
    reset_na   : IN  std_logic;
    brclk_ena  : IN  std_logic;   -- from uv202_clkgen

    -- CPU-side access request. `cpu_req` is a level held by the bus-
    -- interface module (f8_busif, not yet written) while it wants an
    -- access serviced; `cpu_class` selects which wait duration applies.
    -- This mirrors CPUREQ0/CPUREQ1//800-BFF from the real chip, pre-decoded
    -- into a single enum rather than three separate strobe pins.
    cpu_req    : IN  std_logic;
    cpu_class  : IN  bus_access_t;   -- ACC_RAM_RD/WR, ACC_CART_RD/WR, ACC_UV201_RD/WR
    cpu_grant  : OUT std_logic;      -- 1 BRCLK pulse: perform the access now
    cpu_wack   : OUT std_logic;      -- level high while access is in flight
                                       -- (matches WACK pin 8 semantics: high
                                       -- during access, falling edge restarts
                                       -- the CPU clock)
    cpu_stall  : OUT std_logic;      -- combinational: mask this into cpu_ena
                                       -- upstream (uv202_arbiter does not
                                       -- own cpu_ena directly, it just says
                                       -- whether the CPU should be held)

    -- DMA request/grant, x2 (primary + secondary UV201, per UMIREQ0/1 and
    -- DMAREQ0/1 pins). Requesting device holds umireq high until granted;
    -- grant is a single BRCLK pulse telling that UV201 "your DMA byte is
    -- available on bd_dma this cycle" (bd_dma bus itself lives in
    -- sys_bus/buffered_bus, not here - this module only sequences WHO gets
    -- the bus WHEN).
    umireq0    : IN  std_logic;
    umireq1    : IN  std_logic;
    dmareq0    : OUT std_logic;   -- 1 BRCLK grant pulse to primary UV201
    dmareq1    : OUT std_logic;   -- 1 BRCLK grant pulse to secondary UV201

    -- true while any access (CPU or DMA) is in flight - useful for
    -- higher-level sequencing / debug
    busy       : OUT std_logic
    );
END ENTITY uv202_arbiter;

ARCHITECTURE rtl OF uv202_arbiter IS

  TYPE state_t IS (
    ST_IDLE,
    ST_SETUP,      -- 1 BRCLK setup penalty (doc: "at the start of any bus
                    -- access, a 1 BRCLK penalty occurs")
    ST_BODY,       -- the access itself, duration depends on grant_class
    ST_DONE        -- 1 BRCLK to drop WACK / issue grant pulse
    );

  SIGNAL state       : state_t := ST_IDLE;
  SIGNAL body_len     : natural RANGE 0 TO 15;
  SIGNAL body_cnt     : natural RANGE 0 TO 15;

  -- what's being serviced right now (latched at grant time so cpu_req/
  -- umireq can change mid-access without corrupting an in-flight cycle)
  TYPE grant_kind_t IS (GK_NONE, GK_CPU, GK_DMA0, GK_DMA1);
  SIGNAL grant_kind  : grant_kind_t := GK_NONE;

  -- simple 1-bit round robin pointer between DMA0/DMA1 when both request
  -- simultaneously (doc: "the UV202 will alternate between servicing
  -- them" for simultaneous requests from two UV201s)
  SIGNAL dma_rr       : std_logic := '0';

  SIGNAL cpu_wack_l   : std_logic := '0';
  SIGNAL cpu_grant_l  : std_logic := '0';
  SIGNAL dmareq0_l    : std_logic := '0';
  SIGNAL dmareq1_l    : std_logic := '0';

  FUNCTION body_len_for(k : grant_kind_t; c : bus_access_t) RETURN natural IS
  BEGIN
    CASE k IS
      WHEN GK_CPU =>
        CASE c IS
          WHEN ACC_UV201_RD | ACC_UV201_WR =>
            RETURN WAIT_CPU_RDWR + 2;   -- 5-cycle body; 7 total with setup+done
          WHEN OTHERS =>
            RETURN WAIT_CPU_RDWR;       -- 3-cycle body; 5 total with setup+done
        END CASE;
      WHEN GK_DMA0 | GK_DMA1 =>
        RETURN WAIT_DMA_BODY;           -- 3-cycle body; 5 total with setup+done
      WHEN OTHERS =>
        RETURN 0;
    END CASE;
  END FUNCTION;

BEGIN

  PROCESS(clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      state      <= ST_IDLE;
      grant_kind <= GK_NONE;
      body_len    <= 0;
      body_cnt    <= 0;
      dma_rr      <= '0';
      cpu_wack_l  <= '0';
      cpu_grant_l <= '0';
      dmareq0_l   <= '0';
      dmareq1_l   <= '0';

    ELSIF rising_edge(clk) THEN

      -- pulses default low each cycle, held only during brclk_ena ticks
      -- where explicitly asserted below
      cpu_grant_l <= '0';
      dmareq0_l   <= '0';
      dmareq1_l   <= '0';

      IF brclk_ena = '1' THEN
        CASE state IS

          WHEN ST_IDLE =>
            cpu_wack_l <= '0';

            -- priority: CPU access wins over DMA when both request
            -- simultaneously (doc: "If a CPU read and a DMA request both
            -- occur simultaneously, the CPU read is serviced first")
            IF cpu_req = '1' THEN
              grant_kind <= GK_CPU;
              state      <= ST_SETUP;

            ELSIF umireq0 = '1' AND umireq1 = '1' THEN
              -- both DMA channels want service: alternate per round robin
              IF dma_rr = '0' THEN
                grant_kind <= GK_DMA0;
              ELSE
                grant_kind <= GK_DMA1;
              END IF;
              dma_rr <= NOT dma_rr;
              state  <= ST_SETUP;

            ELSIF umireq0 = '1' THEN
              grant_kind <= GK_DMA0;
              state      <= ST_SETUP;

            ELSIF umireq1 = '1' THEN
              grant_kind <= GK_DMA1;
              state      <= ST_SETUP;

            ELSE
              grant_kind <= GK_NONE;
            END IF;

          WHEN ST_SETUP =>
            -- doc: "if a CPU read follows a DMA read, no penalty is
            -- inserted" - MVP simplification: we always take the 1 BRCLK
            -- setup penalty (WAIT_SETUP_PENALTY) for simplicity/safety
            -- margin. This costs at most 1 extra BRCLK of CPU wait vs.
            -- real hardware in the best case and is a correctness-safe
            -- direction to be wrong in (never faster than real hardware,
            -- never risks a race). Flagged for tightening alongside the
            -- other TODO items above.
            body_len <= body_len_for(grant_kind, cpu_class);
            body_cnt <= 0;
            IF grant_kind = GK_CPU THEN
              cpu_wack_l <= '1';
            END IF;
            state <= ST_BODY;

          WHEN ST_BODY =>
            IF body_cnt = body_len - 1 THEN
              state <= ST_DONE;
            ELSE
              body_cnt <= body_cnt + 1;
            END IF;

          WHEN ST_DONE =>
            CASE grant_kind IS
              WHEN GK_CPU =>
                cpu_grant_l <= '1';
                cpu_wack_l  <= '0';   -- falling edge here = "restart CPU clock"
              WHEN GK_DMA0 =>
                dmareq0_l <= '1';
              WHEN GK_DMA1 =>
                dmareq1_l <= '1';
              WHEN OTHERS =>
                NULL;
            END CASE;
            grant_kind <= GK_NONE;
            state      <= ST_IDLE;

        END CASE;
      END IF;
    END IF;
  END PROCESS;

  cpu_grant <= cpu_grant_l;
  cpu_wack  <= cpu_wack_l;
  cpu_stall <= to_std_logic(state /= ST_IDLE) OR cpu_req;  -- hold CPU low
                                                             -- whenever an
                                                             -- access (ours
                                                             -- or someone
                                                             -- else's) is
                                                             -- outstanding
  dmareq0   <= dmareq0_l;
  dmareq1   <= dmareq1_l;
  busy      <= to_std_logic(state /= ST_IDLE);

END ARCHITECTURE rtl;
