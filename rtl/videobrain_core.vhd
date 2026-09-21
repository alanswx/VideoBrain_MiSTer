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

    -- Keyboard matrix, 9 columns x 4 rows, flattened by column, active high.
    kbd_matrix : IN std_logic_vector(35 DOWNTO 0);
    joy_fire   : IN std_logic_vector(3 DOWNTO 0);

    audio_code : OUT std_logic_vector(1 DOWNTO 0);
    audio_stb  : OUT std_logic;
    joy_enable : OUT std_logic;

    f8_po_a_n : OUT uv8;
    f8_po_b_n : OUT uv8;

    brclk_ena  : OUT std_logic;

    -- Pixel output from the internal renderer.
    ce_pix : OUT std_logic;
    vid_idx: OUT std_logic_vector(4 DOWNTO 0);
    vid_r  : OUT uv8;
    vid_g  : OUT uv8;
    vid_b  : OUT uv8;
    vid_de : OUT std_logic;
    vid_hs : OUT std_logic;
    vid_vs : OUT std_logic;
    vid_hb : OUT std_logic;
    vid_vb : OUT std_logic;

    -- Debug only. The record itself stays internal: Quartus cannot carry a
    -- VHDL record across the SystemVerilog boundary at the top level.
    fifo_valid : OUT std_logic;
    fifo_level : OUT unsigned(3 DOWNTO 0);

    hblank   : OUT std_logic;
    vblank   : OUT std_logic;
    burst    : OUT std_logic;
    csync    : OUT std_logic;
    scanline : OUT std_logic;
    field    : OUT std_logic;
    hpos     : OUT unsigned(7 DOWNTO 0);
    vpos     : OUT unsigned(8 DOWNTO 0);

    -- renderer controls, consumed by whatever drives fifo_pop
    final_mod  : OUT uv8;
    background : OUT uv8;
    x_zoom     : OUT std_logic;
    y_zoom     : OUT std_logic;
    video_en   : OUT std_logic;

    dl_addr  : IN unsigned(15 DOWNTO 0);
    dl_data  : IN uv8;
    dl_wr    : IN std_logic;
    dl_index : IN uv8;
    cart_type: IN uv8;

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

  SIGNAL brclk_ena_l : std_logic;
  SIGNAL dmareq0 : std_logic;
  SIGNAL line_start_l   : std_logic;
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

  SIGNAL po_a_n_l, po_b_n_l, pi_b_n_l : uv8;
  SIGNAL uv_o_kbd_l : std_logic;
  SIGNAL x_zoom_l, y_zoom_l : std_logic;
  SIGNAL fifo_pop_l   : std_logic;
  SIGNAL fifo_entry_l : uv201_fifo_entry_t;
  SIGNAL fifo_valid_l : std_logic;
  SIGNAL hblank_l, vblank_l : std_logic;
  SIGNAL hpos_l : unsigned(7 DOWNTO 0);
  SIGNAL final_mod_l, background_l : uv8;

  SIGNAL io_addr  : uv8;
  SIGNAL io_rd    : std_logic;
  SIGNAL io_wr    : std_logic;
  SIGNAL io_wdata : uv8;
  SIGNAL io_rdata : uv8;
  SIGNAL smi_rdata : uv8;
  SIGNAL smi_sel   : std_logic;

  SIGNAL int_req    : std_logic;
  SIGNAL int_vector : uv16;
  SIGNAL int_ack    : std_logic;
  SIGNAL ext_int    : std_logic;

  SIGNAL uv_o_int_l  : std_logic;
  SIGNAL uv_o_frz_l  : std_logic;
  SIGNAL uv_y_int_l  : uv8;
  SIGNAL uv_yint_ho_l : std_logic;

BEGIN

  u_cpu : ENTITY work.f8_cpu
    PORT MAP (
      dr       => cpu_dr,
      dw       => cpu_dw,
      dv       => cpu_dv,
      romc     => romc,
      tick     => tick,
      phase    => phase,
      po_a_n   => po_a_n_l,
      pi_a_n   => x"FF",
      po_b_n   => po_b_n_l,
      pi_b_n   => pi_b_n_l,
      clk      => clk,
      ce       => cpu_ce,
      reset_na => reset_na,
      intreq   => int_req,
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
      io_addr    => io_addr,
      io_rd      => io_rd,
      io_wr      => io_wr,
      io_wdata   => io_wdata,
      io_rdata   => io_rdata,
      int_vector => int_vector,
      int_ack    => int_ack,
      pc0o      => pc0,
      pc1o      => pc1,
      dc0o      => dc0
      );

  -- Only the SMI answers external I/O so far; ports 0/1 are inside the CPU.
  io_rdata <= smi_rdata WHEN smi_sel = '1' ELSE (OTHERS => '1');

  u_smi : ENTITY work.f3853
    PORT MAP (
      clk        => clk,
      reset_na   => reset_na,
      ce         => brclk_ena_l,
      io_addr    => io_addr,
      io_rd      => io_rd,
      io_wr      => io_wr,
      io_wdata   => io_wdata,
      io_rdata   => smi_rdata,
      io_sel     => smi_sel,
      ext_int    => ext_int,
      int_req    => int_req,
      int_vector => int_vector,
      int_ack    => int_ack
      );

  u_yint : ENTITY work.uv201_yint
    PORT MAP (
      clk            => clk,
      reset_na       => reset_na,
      brclk_ena      => brclk_ena_l,
      hblank_falling => hblank_falling,
      cur_vpos       => vpos_l,
      y_int          => uv_y_int_l,
      yint_ho        => uv_yint_ho_l,
      cmd_int        => uv_o_int_l,
      cmd_frz        => uv_o_frz_l,
      irq_pulse      => ext_int
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
      brclk_ena      => brclk_ena_l,
      brclk_phase    => OPEN,
      cpu_ena_raw    => OPEN,
      cpu_ce         => cpu_ce,
      hblank         => hblank_l,
      vblank         => vblank_l,
      burst          => burst,
      csync          => csync,
      scanline       => scanline,
      field          => field_l,
      hpos           => hpos_l,
      vpos           => vpos_l,
      line_start     => line_start_l,
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
      uv_o_x_zm      => x_zoom_l,
      uv_o_frz       => uv_o_frz_l,
      uv_o_enb       => uv_o_enb,
      uv_o_int       => uv_o_int_l,
      uv_o_kbd       => uv_o_kbd_l,
      uv_o_y_zm      => y_zoom_l,
      uv_o_a_b       => uv_o_a_b,
      uv_o_yint_ho   => uv_yint_ho_l,
      uv_y_int       => uv_y_int_l,
      uv_final_mod   => final_mod_l,
      uv_background  => background_l,
      uv_obj_addr    => uv_obj_addr,
      uv_obj_rdata   => uv_obj_rdata,
      dl_addr        => dl_addr,
      dl_data        => dl_data,
      dl_wr          => dl_wr,
      dl_index       => dl_index,
      cart_type      => cart_type
      );

  u_io : ENTITY work.videobrain_io
    PORT MAP (
      clk          => clk,
      reset_na     => reset_na,
      port_a_n     => po_a_n_l,
      port_b_n     => po_b_n_l,
      port_b_in_n  => pi_b_n_l,
      kbd_matrix   => kbd_matrix,
      joy_fire     => joy_fire,
      uv_kbd       => uv_o_kbd_l,
      key_latch    => OPEN,
      joy_enable   => joy_enable,
      accessory_p5 => OPEN,
      accessory_p1 => OPEN,
      audio_code   => audio_code,
      audio_stb    => audio_stb
      );

  f8_po_a_n <= po_a_n_l;
  f8_po_b_n <= po_b_n_l;

  u_fetcher : ENTITY work.uv201_fetcher
    PORT MAP (
      clk           => clk,
      reset_na      => reset_na,
      brclk_ena     => brclk_ena_l,
      line_start    => line_start_l,
      fifo_clear    => hblank_rising,
      vpos          => vpos_l,
      video_en      => uv_o_enb,
      list_a        => uv_o_a_b,
      x_zoom        => x_zoom_l,
      y_zoom        => y_zoom_l,
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
      brclk_ena     => brclk_ena_l,
      hblank_rising => hblank_rising,
      wr_en         => fifo_wr_en,
      wr_entry      => fifo_wr_entry,
      writable      => fifo_writable,
      full          => OPEN,
      rd_pop        => fifo_pop_l,
      rd_valid      => fifo_valid_l,
      rd_entry      => fifo_entry_l,
      level         => fifo_level
      );

  u_render : ENTITY work.uv201_render
    PORT MAP (
      clk        => clk,
      reset_na   => reset_na,
      brclk_ena  => brclk_ena_l,
      hblank     => hblank_l,
      vblank     => vblank_l,
      hpos       => hpos_l,
      vpos       => vpos_l,
      fifo_valid => fifo_valid_l,
      fifo_entry => fifo_entry_l,
      fifo_pop   => fifo_pop_l,
      final_mod  => std_logic_vector(final_mod_l),
      background => std_logic_vector(background_l),
      x_zoom     => x_zoom_l,
      video_en   => uv_o_enb,
      ce_pix     => ce_pix,
      idx        => vid_idx,
      r          => vid_r,
      g          => vid_g,
      b          => vid_b,
      de         => vid_de,
      hs         => vid_hs,
      vs         => vid_vs,
      hb         => vid_hb,
      vb         => vid_vb
      );

  hblank     <= hblank_l;
  vblank     <= vblank_l;
  hpos       <= hpos_l;
  final_mod  <= final_mod_l;
  background <= background_l;
  fifo_valid <= fifo_valid_l;

  field    <= field_l;
  vpos     <= vpos_l;
  video_en <= uv_o_enb;
  x_zoom   <= x_zoom_l;
  y_zoom   <= y_zoom_l;
  brclk_ena <= brclk_ena_l;

END ARCHITECTURE rtl;
