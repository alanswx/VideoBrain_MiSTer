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
   output reg    ce_pix /*verilator public_flat*/,

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
   input [3:0]   joy_fire /*verilator public_flat*/
);

   wire        brclk_ena /*verilator public_flat*/;
   wire        hblank, vblank, csync, burst, scanline, field;
   wire [7:0]  hpos /*verilator public_flat*/;
   wire [8:0]  vpos /*verilator public_flat*/;

   wire        fifo_valid /*verilator public_flat*/;
   wire [3:0]  fifo_level /*verilator public_flat*/;
   wire        ent_gap;
   wire [7:0]  ent_payload;
   wire [4:0]  ent_color;

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
   wire        fifo_pop;

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
      .fifo_pop   (fifo_pop),
      .fifo_valid (fifo_valid),
      .\fifo_entry_fifo_entry[is_gap]  (ent_gap),
      .\fifo_entry_fifo_entry[payload] (ent_payload),
      .\fifo_entry_fifo_entry[color]   (ent_color),
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

      .pc0        (pc0),
      .pc1        (pc1),
      .dc0        (dc0)
   );

   // ----------------------------------------------------------------------
   // UV201 pixel path
   // ----------------------------------------------------------------------
   // One FIFO entry is consumed per pixel until it is exhausted: a gap entry
   // covers `payload` background pixels, a data entry covers 8.  The FIFO is
   // show-ahead, so the head can be used in the same cycle it is popped.

   reg [7:0] shift_reg;
   reg [2:0] shift_cnt;          // pixels left in the current byte, 0 = none
   reg [4:0] shift_color;
   reg [7:0] gap_cnt;            // background pixels left in the current gap
   reg       shift_active;
   reg       dbl;                 // X zoom: second pixel of the current pair

   wire active = ~hblank & ~vblank;
   wire need_entry = active & ~shift_active & (gap_cnt == 8'd0) & fifo_valid;

   // The FIFO only acts on a pop while brclk_ena is high.
   assign fifo_pop = need_entry & brclk_ena;

   always @(posedge clk_sys) begin
      if (reset) begin
         shift_active <= 1'b0;
         shift_cnt    <= 3'd0;
         gap_cnt      <= 8'd0;
      end else if (brclk_ena) begin
         if (~active) begin
            shift_active <= 1'b0;
            shift_cnt    <= 3'd0;
            gap_cnt      <= 8'd0;
            dbl          <= 1'b0;
         end else if (shift_active) begin
            // With X zoom each bit covers two pixels, so only advance on the
            // second of the pair.
            if (x_zoom & ~dbl) begin
               dbl <= 1'b1;
            end else begin
               dbl <= 1'b0;
               shift_reg <= {shift_reg[6:0], 1'b0};
               if (shift_cnt == 3'd0) shift_active <= 1'b0;
               else                   shift_cnt <= shift_cnt - 3'd1;
            end
         end else if (gap_cnt != 8'd0) begin
            gap_cnt <= gap_cnt - 8'd1;
         end else if (fifo_valid) begin
            if (ent_gap) begin
               // This cycle emits the gap's first pixel.
               gap_cnt <= (ent_payload == 8'd0) ? 8'd0 : ent_payload - 8'd1;
            end else if (x_zoom) begin
               // bit 7 is emitted now and once more; the shift happens then.
               shift_reg    <= ent_payload;
               shift_color  <= ent_color;
               shift_cnt    <= 3'd7;
               shift_active <= 1'b1;
               dbl          <= 1'b1;
            end else begin
               shift_reg    <= {ent_payload[6:0], 1'b0};
               shift_color  <= ent_color;
               shift_cnt    <= 3'd6;   // bit 7 emitted now, 6 more then the last
               shift_active <= 1'b1;
               dbl          <= 1'b0;
            end
         end
      end
   end

   // Pixel currently being emitted, chosen the same way as the state update.
   wire        fresh_data = ~shift_active & (gap_cnt == 8'd0) & fifo_valid & ~ent_gap;
   wire        obj_bit    = shift_active ? shift_reg[7] : ent_payload[7];
   wire [4:0]  obj_color  = shift_active ? shift_color  : ent_color;
   wire        in_object  = shift_active | fresh_data;

   wire [4:0]  idx = in_object ? ((obj_bit ? obj_color : background[4:0]) ^ final_mod[4:0])
                               : background[4:0];

   // uv201.cpp initialize_palette(): bit 4 selects the intensity pair,
   // bits 2:0 are blue/green/red.  High intensity lifts "off" to 0xC0, so a
   // high-intensity black is grey rather than black.
   wire [7:0] off = idx[4] ? 8'hC0 : 8'h00;
   wire [7:0] on  = idx[4] ? 8'hFF : 8'hA0;
   wire [7:0] r   = idx[0] ? on : off;
   wire [7:0] g   = idx[1] ? on : off;
   wire [7:0] b   = idx[2] ? on : off;

   // ----------------------------------------------------------------------
   // Pixel output
   // ----------------------------------------------------------------------
   // One pixel is one BRCLK, so the video outputs are latched at the BRCLK
   // edge and ce_pix marks the cycle on which they are new. `idx` is combinational
   // from the pre-edge shifter state, which is the pixel this period emitted.
   // CSYNC carries both syncs; HS and VS are split back out for the harness.

   reg [4:0] idx_r;
   reg [7:0] vga_r_r, vga_g_r, vga_b_r;
   reg       de_r, hb_r, vb_r, hs_r, vs_r;

   always @(posedge clk_sys) begin
      ce_pix <= brclk_ena;
      if (brclk_ena) begin
         // COMMAND_ENB clear blanks the screen, as in screen_update().
         idx_r   <= (active & video_en) ? idx : 5'd0;
         vga_r_r <= (active & video_en) ? r : 8'h00;
         vga_g_r <= (active & video_en) ? g : 8'h00;
         vga_b_r <= (active & video_en) ? b : 8'h00;
         de_r    <= active;
         hb_r    <= hblank;
         vb_r    <= vblank;
         hs_r    <= (hpos < 8'd18);
         vs_r    <= (vpos < 9'd3);
      end
   end

   assign VGA_R  = vga_r_r;
   assign VGA_G  = vga_g_r;
   assign VGA_B  = vga_b_r;
   assign VGA_DE = de_r;
   assign VGA_HB = hb_r;
   assign VGA_VB = vb_r;
   assign VGA_HS = hs_r;
   assign VGA_VS = vs_r;

   // 2-bit R-2R DAC on port 0 bits 1:0, clocked by port 1 bit 4.
   wire signed [15:0] dac = {2'b00, audio_code, 12'b0} - 16'sd6000;
   assign AUDIO_L = dac;
   assign AUDIO_R = dac;

endmodule
