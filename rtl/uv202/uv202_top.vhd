--------------------------------------------------------------------------------
-- VideoBrain UV202 - structural top
--------------------------------------------------------------------------------
-- Collects the portions of the UV202 that are already understood well enough
-- to stand on their own: clock enables, raster timing, and bus arbitration.
--
-- Deliberately NOT included here:
--   * f8_busif: CPU/ROMC glue lives at machine level.
--   * memory/data muxing: sys_bus/buffered_bus own address/data routing.
--   * F3853 SMI/interrupt handling: separate device at machine level.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY uv202_top IS
  GENERIC (
    CLK_DIV_MCLK : positive := 1;
    CPU_CLK_DIV  : positive := 7
    );
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    -- CPU-side arbitration request from f8_busif.
    cpu_req    : IN  std_logic;
    cpu_class  : IN  bus_access_t;
    cpu_grant  : OUT std_logic;
    cpu_wack   : OUT std_logic;
    cpu_stall  : OUT std_logic;

    -- UV201 DMA request/grant pair.  Channel 1 is retained because the real
    -- UV202 provides it even though the base machine has one UV201.
    umireq0 : IN  std_logic;
    umireq1 : IN  std_logic;
    dmareq0 : OUT std_logic;
    dmareq1 : OUT std_logic;

    -- Clock-enable outputs.  cpu_ce is the CPU enable after UV202 wait-state
    -- gating; cpu_ena_raw is the free-running CPU oscillator enable.
    mclk_ena    : OUT std_logic;
    brclk_ena   : OUT std_logic;
    brclk_phase : OUT uv2;
    cpu_ena_raw : OUT std_logic;
    cpu_ce      : OUT std_logic;

    -- Raster/timing outputs.
    hblank  : OUT std_logic;
    vblank  : OUT std_logic;
    burst   : OUT std_logic;
    csync   : OUT std_logic;
    scanline: OUT std_logic;
    field   : OUT std_logic;
    hpos    : OUT unsigned(7 DOWNTO 0);
    vpos    : OUT unsigned(8 DOWNTO 0);
    line_start     : OUT std_logic;
    hblank_falling : OUT std_logic;
    hblank_rising  : OUT std_logic;

    busy : OUT std_logic
    );
END ENTITY uv202_top;

ARCHITECTURE rtl OF uv202_top IS
  SIGNAL mclk_ena_l    : std_logic;
  SIGNAL brclk_ena_l   : std_logic;
  SIGNAL brclk_phase_l : uv2;
  SIGNAL cpu_ena_l     : std_logic;
  SIGNAL cpu_stall_l   : std_logic;
BEGIN

  u_clkgen : ENTITY work.uv202_clkgen
    GENERIC MAP (
      CLK_DIV_MCLK => CLK_DIV_MCLK,
      CPU_CLK_DIV  => CPU_CLK_DIV
      )
    PORT MAP (
      clk         => clk,
      reset_na    => reset_na,
      mclk_ena    => mclk_ena_l,
      brclk_ena   => brclk_ena_l,
      cpu_ena     => cpu_ena_l,
      brclk_phase => brclk_phase_l
      );

  u_timing : ENTITY work.uv202_timing
    PORT MAP (
      clk            => clk,
      reset_na       => reset_na,
      brclk_ena      => brclk_ena_l,
      hblank         => hblank,
      vblank         => vblank,
      burst          => burst,
      csync          => csync,
      scanline       => scanline,
      field          => field,
      hpos           => hpos,
      vpos           => vpos,
      line_start     => line_start,
      hblank_falling => hblank_falling,
      hblank_rising  => hblank_rising
      );

  u_arbiter : ENTITY work.uv202_arbiter
    PORT MAP (
      clk        => clk,
      reset_na   => reset_na,
      brclk_ena  => brclk_ena_l,
      cpu_req    => cpu_req,
      cpu_class  => cpu_class,
      cpu_grant  => cpu_grant,
      cpu_wack   => cpu_wack,
      cpu_stall  => cpu_stall_l,
      umireq0    => umireq0,
      umireq1    => umireq1,
      dmareq0    => dmareq0,
      dmareq1    => dmareq1,
      busy       => busy
      );

  mclk_ena    <= mclk_ena_l;
  brclk_ena   <= brclk_ena_l;
  brclk_phase <= brclk_phase_l;
  cpu_ena_raw <= cpu_ena_l;
  cpu_stall   <= cpu_stall_l;

  -- The F8 CPU receives the independent CPU oscillator enable only when the
  -- UV202 is not stretching the current external access.
  cpu_ce <= cpu_ena_l AND NOT cpu_stall_l;

END ARCHITECTURE rtl;
