--------------------------------------------------------------------------------
-- VideoBrain machine core assembly
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.f8_pack.ALL;
USE work.uv201_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY videobrain_core IS
  GENERIC (
    CLK_DIV_MCLK : positive := 1;
    CPU_CLK_DIV  : positive := 7
    );
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    f8_pi_a_n : IN  uv8;
    f8_pi_b_n : IN  uv8;
    f8_po_a_n : OUT uv8;
    f8_po_b_n : OUT uv8;

    fifo_pop   : IN  std_logic;
    fifo_valid : OUT std_logic;
    fifo_entry : OUT uv201_fifo_entry_t;
    fifo_level : OUT unsigned(3 DOWNTO 0);

    hblank   : OUT std_logic;
    vblank   : OUT std_logic;
    burst    : OUT std_logic;
    csync    : OUT std_logic;
    scanline : OUT std_logic;
    field    : OUT std_logic;
    hpos     : OUT unsigned(7 DOWNTO 0);
    vpos     : OUT unsigned(8 DOWNTO 0);

    pc0 : OUT uv16;
    pc1 : OUT uv16;
    dc0 : OUT uv16
    );
END ENTITY videobrain_core;

ARCHITECTURE rtl OF videobrain_core IS

  SIGNAL cpu_dr, cpu_dw : uv8;
  SIGNAL cpu_dv : std_logic;
  SIGNAL romc : uv5;
  SIGNAL tick : std_logic;
  SIGNAL phase : uint4;
  SIGNAL cpu_ce : std_logic;

  SIGNAL ext_addr  : unsigned(13 DOWNTO 0);
  SIGNAL ext_rd    : std_logic;
  SIGNAL ext_wr    : std_logic;
  SIGNAL ext_wdata : uv8;
  SIGNAL ext_rdata : uv8;
  SIGNAL ext_req   : std_logic;
  SIGNAL ext_class : bus_access_t;
  SIGNAL ext_grant : std_logic;

  SIGNAL brclk_ena : std_logic;
  SIGNAL dmareq0 : std_logic;
  SIGNAL hblank_falling : std_logic;
  SIGNAL hblank_rising  : std_logic;
  SIGNAL field_l : std_logic;
  SIGNAL vpos_l  : unsigned(8 DOWNTO 0);

  SIGNAL uv_o_enb : std_logic;
  SIGNAL uv_o_a_b : std_logic;
  SIGNAL uv_obj_addr  : uv8;
  SIGNAL uv_obj_rdata : uv8;
  SIGNAL bb_addr  : unsigned(12 DOWNTO 0);
  SIGNAL bb_rdata : uv8;

  SIGNAL fetch_umireq : std_logic;
  SIGNAL fifo_writable : std_logic;
  SIGNAL fifo_wr_en : std_logic;
  SIGNAL fifo_wr_entry : uv201_fifo_entry_t;

BEGIN

  u_cpu : ENTITY work.f8_cpu
    PORT MAP (
      dr       => cpu_dr,
      dw       => cpu_dw,
      dv       => cpu_dv,
      romc     => romc,
      tick     => tick,
      phase    => phase,
      po_a_n   => f8_po_a_n,
      pi_a_n   => f8_pi_a_n,
      po_b_n   => f8_po_b_n,
      pi_b_n   => f8_pi_b_n,
      clk      => clk,
      ce       => cpu_ce,
      reset_na => reset_na,
      acco     => OPEN,
      visaro   => OPEN,
      iozcso   => OPEN
      );

  u_busif : ENTITY work.f8_busif
    PORT MAP (
      dw        => cpu_dw,
      dr        => cpu_dr,
      dv        => OPEN,
      romc      => romc,
      tick      => tick,
      phase     => phase,
      clk       => clk,
      ce        => cpu_ce,
      reset_na  => reset_na,
      ext_addr  => ext_addr,
      ext_rd    => ext_rd,
      ext_wr    => ext_wr,
      ext_wdata => ext_wdata,
      ext_rdata => ext_rdata,
      ext_req   => ext_req,
      ext_class => ext_class,
      ext_grant => ext_grant,
      pc0o      => pc0,
      pc1o      => pc1,
      dc0o      => dc0
      );

  u_uv202 : ENTITY work.uv202_top
    GENERIC MAP (
      CLK_DIV_MCLK => CLK_DIV_MCLK,
      CPU_CLK_DIV  => CPU_CLK_DIV
      )
    PORT MAP (
      clk            => clk,
      reset_na       => reset_na,
      cpu_req        => ext_req,
      cpu_class      => ext_class,
      cpu_grant      => ext_grant,
      cpu_wack       => OPEN,
      cpu_stall      => OPEN,
      umireq0        => fetch_umireq,
      umireq1        => '0',
      dmareq0        => dmareq0,
      dmareq1        => OPEN,
      mclk_ena       => OPEN,
      brclk_ena      => brclk_ena,
      brclk_phase    => OPEN,
      cpu_ena_raw    => OPEN,
      cpu_ce         => cpu_ce,
      hblank         => hblank,
      vblank         => vblank,
      burst          => burst,
      csync          => csync,
      scanline       => scanline,
      field          => field_l,
      hpos           => hpos,
      vpos           => vpos_l,
      hblank_falling => hblank_falling,
      hblank_rising  => hblank_rising,
      busy           => OPEN
      );

  u_sys_bus : ENTITY work.sys_bus
    PORT MAP (
      clk            => clk,
      reset_na       => reset_na,
      ext_addr       => ext_addr,
      ext_rd         => ext_rd,
      ext_wr         => ext_wr,
      ext_wdata      => ext_wdata,
      ext_rdata      => ext_rdata,
      bb_addr        => bb_addr,
      bb_rdata       => bb_rdata,
      uv_cur_field   => field_l,
      uv_cur_vpos    => vpos_l,
      uv_capture_stb => '0',
      uv_capture_x   => (OTHERS => '0'),
      uv_o_x_zm      => OPEN,
      uv_o_frz       => OPEN,
      uv_o_enb       => uv_o_enb,
      uv_o_int       => OPEN,
      uv_o_kbd       => OPEN,
      uv_o_y_zm      => OPEN,
      uv_o_a_b       => uv_o_a_b,
      uv_o_yint_ho   => OPEN,
      uv_y_int       => OPEN,
      uv_final_mod   => OPEN,
      uv_background  => OPEN,
      uv_obj_addr    => uv_obj_addr,
      uv_obj_rdata   => uv_obj_rdata
      );

  u_fetcher : ENTITY work.uv201_fetcher
    PORT MAP (
      clk           => clk,
      reset_na      => reset_na,
      brclk_ena     => brclk_ena,
      line_start    => hblank_falling,
      fifo_clear    => hblank_rising,
      vpos          => vpos_l,
      video_en      => uv_o_enb,
      list_a        => uv_o_a_b,
      obj_addr      => uv_obj_addr,
      obj_rdata     => uv_obj_rdata,
      bb_addr       => bb_addr,
      bb_rdata      => bb_rdata,
      umireq        => fetch_umireq,
      dmareq        => dmareq0,
      fifo_writable => fifo_writable,
      fifo_wr_en    => fifo_wr_en,
      fifo_wr_entry => fifo_wr_entry,
      busy          => OPEN
      );

  u_fifo : ENTITY work.uv201_fifo
    PORT MAP (
      clk           => clk,
      reset_na      => reset_na,
      brclk_ena     => brclk_ena,
      hblank_rising => hblank_rising,
      wr_en         => fifo_wr_en,
      wr_entry      => fifo_wr_entry,
      writable      => fifo_writable,
      full          => OPEN,
      rd_pop        => fifo_pop,
      rd_valid      => fifo_valid,
      rd_entry      => fifo_entry,
      level         => fifo_level
      );

  field <= field_l;
  vpos  <= vpos_l;

END ARCHITECTURE rtl;
