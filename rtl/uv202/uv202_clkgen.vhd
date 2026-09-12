--------------------------------------------------------------------------------
-- VideoBrain UV202 - clock generator
--------------------------------------------------------------------------------
-- Reference: kevtris "Videobrain Unwrapped" V0.05, sections:
--   "Conventions in this document" (MCLK/CPUCLK/BRCLK definitions)
--   UV202 pin 4/5 (Xin/Xout), pin 7 (CPUCLK), pin 33 (BRCLK), pin 34 (COLCLK)
--------------------------------------------------------------------------------
--
-- Real hardware: UV202 is clocked from a 14.318181MHz crystal (Xin/Xout).
-- Internally it divides by 4 to make BRCLK (3.579545MHz, also mirrored out
-- as COLCLK for the NTSC encoder) and attempts to divide by 7 to make a
-- 2.045MHz CPUCLK - but that /7 output stops one cycle too late and glitches
-- the CPU during wait states, so real consoles ignore it and instead run the
-- F8 CPU from a *separate* 4MHz oscillator through a JK flip-flop (/2),
-- giving a clean external 2.0MHz CPUCLK with no relation to UV202's internal
-- dividers.
--
-- On FPGA we have no reason to reproduce the bug. This module:
--   1. Takes a single fast reference clock `clk` (expected = MCLK, i.e. the
--      14.318181MHz UV202 crystal rate, oversampled to whatever the FPGA
--      PLL actually runs at - see NOTE below on the `clk`/`clk_ena_mclk`
--      convention used throughout this core).
--   2. Produces `brclk_ena`: a 1-`clk`-wide enable pulse at BRCLK rate
--      (MCLK/4), 50% duty cycle equivalent for anything that samples on
--      brclk_ena rising activity.
--   3. Produces `cpu_ena`: a clean, glitch-free enable pulse at ~2.0MHz
--      (nominally MCLK/7, but free-running and NOT phase-locked to the
--      real hardware's broken divider - matches the "external 2MHz osc"
--      behavior, not the UV202 pin 7 behavior).
--
-- All of this core's modules are single-clock-domain (`clk` = MCLK-rate
-- oversampling clock) and use enable pulses rather than separate clock
-- nets, matching the ce/tick convention already used in f8_cpu.vhd /
-- f8_psu.vhd. uv202_arbiter is responsible for stalling `cpu_ena` to
-- implement wait states; this module only produces the free-running base
-- enables.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY uv202_clkgen IS
  GENERIC (
    -- Ratio of `clk` to MCLK. clk_div_mclk=1 means `clk` itself IS MCLK
    -- rate (one clk edge = one MCLK edge). If the FPGA system clock is
    -- some multiple of MCLK, set this higher and clkgen will additionally
    -- divide down to a single MCLK-rate enable first.
    CLK_DIV_MCLK : positive := 1;

    -- CPU enable divisor, applied to the MCLK-rate enable. Default 7
    -- matches the real ~2.045MHz rate (14.318181/7); the doc notes real
    -- consoles actually run 2.0MHz exactly off a separate oscillator, so
    -- treat this as approximate/tunable rather than load-bearing for any
    -- cycle-exact CPU timing (there isn't any - see "Wait States" section,
    -- cycle-counted code is explicitly not possible on this hardware).
    CPU_CLK_DIV  : positive := 7
    );
  PORT (
    clk        : IN  std_logic;
    reset_na   : IN  std_logic;

    -- MCLK-rate enable, asserted for 1 `clk` cycle out of every
    -- CLK_DIV_MCLK. If CLK_DIV_MCLK=1 this is tied high.
    mclk_ena   : OUT std_logic;

    -- BRCLK-rate enable (MCLK/4). This is the master heartbeat for
    -- uv202_timing, uv202_arbiter, and everything in uv201/.
    brclk_ena  : OUT std_logic;

    -- Free-running ~2MHz CPU enable, gated externally by uv202_arbiter
    -- to implement wait states (i.e. arbiter ANDs this with "not waiting"
    -- before it reaches f8_cpu's `ce` input).
    cpu_ena    : OUT std_logic;

    -- 2-bit BRCLK sub-phase counter, free-running, used by uv201_fetcher
    -- for the modulo-4 UV201-register-read stretch behavior documented
    -- under "UV201 register reads".
    brclk_phase : OUT uv2
    );
END ENTITY uv202_clkgen;

ARCHITECTURE rtl OF uv202_clkgen IS

  SIGNAL mclk_div_cnt : natural RANGE 0 TO CLK_DIV_MCLK-1 := 0;
  SIGNAL mclk_ena_l   : std_logic;

  SIGNAL brclk_div_cnt : natural RANGE 0 TO BRCLK_DIV-1 := 0;
  SIGNAL brclk_ena_l   : std_logic;
  SIGNAL brclk_phase_l : uv2 := (OTHERS => '0');

  SIGNAL cpu_div_cnt : natural RANGE 0 TO CPU_CLK_DIV-1 := 0;
  SIGNAL cpu_ena_l   : std_logic;

BEGIN

  ----------------------------------------------------------------------------
  -- Stage 1: clk -> mclk_ena
  ----------------------------------------------------------------------------

  gen_mclk_passthru : IF CLK_DIV_MCLK = 1 GENERATE
    mclk_ena_l <= '1';
  END GENERATE;

  gen_mclk_divide : IF CLK_DIV_MCLK > 1 GENERATE
    PROCESS(clk, reset_na) IS
    BEGIN
      IF reset_na = '0' THEN
        mclk_div_cnt <= 0;
        mclk_ena_l   <= '0';
      ELSIF rising_edge(clk) THEN
        IF mclk_div_cnt = CLK_DIV_MCLK-1 THEN
          mclk_div_cnt <= 0;
          mclk_ena_l   <= '1';
        ELSE
          mclk_div_cnt <= mclk_div_cnt + 1;
          mclk_ena_l   <= '0';
        END IF;
      END IF;
    END PROCESS;
  END GENERATE;

  mclk_ena <= mclk_ena_l;

  ----------------------------------------------------------------------------
  -- Stage 2: mclk_ena -> brclk_ena (divide by 4), plus free-running 2-bit
  -- phase counter (kept ALWAYS running, independent of HBLANK, so
  -- uv201_fetcher can read it directly - the real chip's "modulo 4 counter
  -- that continuously runs" per the doc).
  ----------------------------------------------------------------------------

  PROCESS(clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      brclk_div_cnt <= 0;
      brclk_ena_l   <= '0';
      brclk_phase_l <= (OTHERS => '0');
    ELSIF rising_edge(clk) THEN
      brclk_ena_l <= '0';
      IF mclk_ena_l = '1' THEN
        IF brclk_div_cnt = BRCLK_DIV-1 THEN
          brclk_div_cnt <= 0;
          brclk_ena_l   <= '1';
          brclk_phase_l <= brclk_phase_l + 1;
        ELSE
          brclk_div_cnt <= brclk_div_cnt + 1;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  brclk_ena   <= brclk_ena_l;
  brclk_phase <= brclk_phase_l;

  ----------------------------------------------------------------------------
  -- Stage 3: mclk_ena -> cpu_ena (free-running ~2MHz enable, NOT gated by
  -- brclk - the real CPU clock is an independent oscillator, not derived
  -- from UV202's internal BRCLK chain). uv202_arbiter stalls this
  -- externally by masking the enable it forwards to f8_cpu's `ce`.
  ----------------------------------------------------------------------------

  PROCESS(clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      cpu_div_cnt <= 0;
      cpu_ena_l   <= '0';
    ELSIF rising_edge(clk) THEN
      cpu_ena_l <= '0';
      IF mclk_ena_l = '1' THEN
        IF cpu_div_cnt = CPU_CLK_DIV-1 THEN
          cpu_div_cnt <= 0;
          cpu_ena_l   <= '1';
        ELSE
          cpu_div_cnt <= cpu_div_cnt + 1;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  cpu_ena <= cpu_ena_l;

END ARCHITECTURE rtl;
