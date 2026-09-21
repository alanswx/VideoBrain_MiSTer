`timescale 1ns/1ns
//
// Simulation top for the VideoBrain core.
//
// The core is supplied as a Verilog netlist produced by "ghdl synth" from
// rtl/*.vhd -- see the Makefile.  Only the netlist's port names are stable,
// so everything the harness needs is a real port on videobrain_core.
//
// videobrain_core has no pixel path: it exposes the UV201 FIFO and takes
// fifo_pop as an input, so the renderer lives here.  It follows MAME
// uv201.cpp screen_update(): MSB-first bytes, 0 bits take the background
// register, the 5-bit result is XORed with the final modifier, and the
// gaps between objects take the background unmodified.
//

module top(
   input         clk_sys /*verilator public_flat*/,
   input         reset /*verilator public_flat*/,

   output [7:0]  VGA_R /*verilator public_flat*/,
   output [7:0]  VGA_G /*verilator public_flat*/,
   output [7:0]  VGA_B /*verilator public_flat*/,
   output        VGA_HS,
   output        VGA_VS,
   output        VGA_HB,
   output        VGA_VB,
   output        VGA_DE /*verilator public_flat*/,
   output        ce_pix /*verilator public_flat*/,

   output [15:0] AUDIO_L,
   output [15:0] AUDIO_R,

   input         ioctl_download,
   input         ioctl_upload,
   input         ioctl_wr,
   input [24:0]  ioctl_addr,
   input [7:0]   ioctl_dout,
   input [7:0]   ioctl_din,
   input [7:0]   ioctl_index,
   output reg    ioctl_wait = 1'b0,

   input [10:0]  ps2_key,

   // Keyboard matrix, 9 columns x 4 rows flattened by column, active high.
   input [35:0]  kbd_matrix /*verilator public_flat*/,
   input [3:0]   joy_fire /*verilator public_flat*/,
   input [7:0]   cart_type /*verilator public_flat*/
);

   wire        brclk_ena /*verilator public_flat*/;
   wire        hblank, vblank, csync, burst, scanline, field;
   wire [7:0]  hpos /*verilator public_flat*/;
   wire [8:0]  vpos /*verilator public_flat*/;

   wire        fifo_valid /*verilator public_flat*/;
   wire [3:0]  fifo_level /*verilator public_flat*/;

   wire [7:0]  final_mod /*verilator public_flat*/;
   wire [7:0]  background /*verilator public_flat*/;
   wire        x_zoom, y_zoom;
   wire        video_en /*verilator public_flat*/;

   wire [15:0] pc0 /*verilator public_flat*/;
   wire [15:0] pc1 /*verilator public_flat*/;
   wire [15:0] dc0 /*verilator public_flat*/;
   wire [7:0]  po_a_n /*verilator public_flat*/;
   wire [7:0]  po_b_n /*verilator public_flat*/;
   wire [1:0]  audio_code /*verilator public_flat*/;
   wire        audio_stb;
   wire        joy_enable;

   wire        dl_wr = ioctl_download & ioctl_wr;
   wire [4:0]  idx_r /*verilator public_flat*/;
   wire [7:0]  vid_r, vid_g, vid_b;
   wire        vid_de, vid_hs, vid_vs, vid_hb, vid_vb;

   videobrain_core core(
      .clk        (clk_sys),
      .reset_na   (~reset),

      .kbd_matrix (kbd_matrix),
      .joy_fire   (joy_fire),
      .audio_code (audio_code),
      .audio_stb  (audio_stb),
      .joy_enable (joy_enable),
      .f8_po_a_n  (po_a_n),
      .f8_po_b_n  (po_b_n),

      .brclk_ena  (brclk_ena),
      .ce_pix     (ce_pix),
      .vid_idx    (idx_r),
      .vid_r      (vid_r),
      .vid_g      (vid_g),
      .vid_b      (vid_b),
      .vid_de     (vid_de),
      .vid_hs     (vid_hs),
      .vid_vs     (vid_vs),
      .vid_hb     (vid_hb),
      .vid_vb     (vid_vb),
      .fifo_valid (fifo_valid),
      .fifo_level (fifo_level),

      .hblank     (hblank),
      .vblank     (vblank),
      .burst      (burst),
      .csync      (csync),
      .scanline   (scanline),
      .field      (field),
      .hpos       (hpos),
      .vpos       (vpos),

      .final_mod  (final_mod),
      .background (background),
      .x_zoom     (x_zoom),
      .y_zoom     (y_zoom),
      .video_en   (video_en),

      .dl_addr    (ioctl_addr[15:0]),
      .dl_data    (ioctl_dout),
      .dl_wr      (dl_wr),
      .dl_index   (ioctl_index),
      .cart_type  (cart_type),

      .pc0        (pc0),
      .pc1        (pc1),
      .dc0        (dc0)
   );

   // The pixel path lives in rtl/uv201/uv201_render.vhd so the simulator and
   // the FPGA build share one renderer.
   assign VGA_R  = vid_r;
   assign VGA_G  = vid_g;
   assign VGA_B  = vid_b;
   assign VGA_DE = vid_de;
   assign VGA_HB = vid_hb;
   assign VGA_VB = vid_vb;
   assign VGA_HS = vid_hs;
   assign VGA_VS = vid_vs;

   // 2-bit R-2R DAC on port 0 bits 1:0, clocked by port 1 bit 4.
   wire signed [15:0] dac = {2'b00, audio_code, 12'b0} - 16'sd6000;
   assign AUDIO_L = dac;
   assign AUDIO_R = dac;

endmodule
