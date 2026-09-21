//============================================================================
//  VideoBrain Family Computer for MiSTer
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 0;   // unsigned
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// The UV201 visible area is 189 dots by 242 lines on a 4:3 screen.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"VideoBrain;;",
	"-;",
	"F1,BIN,Load Cartridge;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"-;",
	"O[5],Joystick,Off,On;",
	"O[7:6],Cartridge,Standard,Timeshare,Money Minder;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J,Fire;",
	"jn,A;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0;

wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 14.318181 MHz is the UV202 master clock; BRCLK, and one pixel, is /4.
wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked;

///////////////////////   ROM LOADING   //////////////////////////

// Main_MiSTer uploads boot<N>.rom at ioctl_index N<<6, so boot.rom arrives
// at index 0. It holds RES1 then RES2, 2K each, and address bit 11 selects.
// The cartridge comes from the OSD at index 1.
wire boot_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire cart_dl = ioctl_download && (ioctl_index[7:0] == 8'd1);

wire [7:0] dl_index = cart_dl               ? 8'd2 :
                      ioctl_addr[11]        ? 8'd1 : 8'd0;

wire [15:0] dl_addr = {4'd0, ioctl_addr[11:0]};
wire        dl_wr   = (boot_dl | cart_dl) & ioctl_wr;

///////////////////////   KEYBOARD   /////////////////////////////

// 9 columns by 4 rows, bit = col * 4 + row, active high. Columns 0-7 are
// selected by the CPU's port 0 latch, column 8 by UV201 CMD_KBD.
// Layout from the board netlist and MAME vidbrain.cpp.
reg [35:0] kbd_matrix = 0;

wire       key_pressed = ps2_key[9];
wire [8:0] key_code    = ps2_key[8:0];
reg        key_toggle  = 0;

always @(posedge clk_sys) begin
	key_toggle <= ps2_key[10];
	if (reset) kbd_matrix <= 0;
	else if (key_toggle != ps2_key[10]) begin
		case (key_code)
			'h043: kbd_matrix[0]  <= key_pressed;  // I
			'h044: kbd_matrix[1]  <= key_pressed;  // O
			'h04D: kbd_matrix[2]  <= key_pressed;  // P
			'h04C: kbd_matrix[3]  <= key_pressed;  // ;

			'h03C: kbd_matrix[4]  <= key_pressed;  // U
			'h042: kbd_matrix[5]  <= key_pressed;  // K
			'h04B: kbd_matrix[6]  <= key_pressed;  // L
			'h041: kbd_matrix[7]  <= key_pressed;  // ,

			'h035: kbd_matrix[8]  <= key_pressed;  // Y
			'h03B: kbd_matrix[9]  <= key_pressed;  // J
			'h03A: kbd_matrix[10] <= key_pressed;  // M
			'h012: kbd_matrix[11] <= key_pressed;  // left shift
			'h059: kbd_matrix[11] <= key_pressed;  // right shift

			'h02C: kbd_matrix[12] <= key_pressed;  // T
			'h033: kbd_matrix[13] <= key_pressed;  // H
			'h031: kbd_matrix[14] <= key_pressed;  // N
			'h066: kbd_matrix[15] <= key_pressed;  // backspace = ERASE/RESTART

			'h02D: kbd_matrix[16] <= key_pressed;  // R
			'h034: kbd_matrix[17] <= key_pressed;  // G
			'h032: kbd_matrix[18] <= key_pressed;  // B
			'h029: kbd_matrix[19] <= key_pressed;  // space = RUN/STOP

			'h024: kbd_matrix[20] <= key_pressed;  // E
			'h02B: kbd_matrix[21] <= key_pressed;  // F
			'h02A: kbd_matrix[22] <= key_pressed;  // V
			'h00C: kbd_matrix[23] <= key_pressed;  // F4 = SPECIAL/ALARM

			'h01D: kbd_matrix[24] <= key_pressed;  // W
			'h023: kbd_matrix[25] <= key_pressed;  // D
			'h021: kbd_matrix[26] <= key_pressed;  // C
			'h004: kbd_matrix[27] <= key_pressed;  // F3 = NEXT/CLOCK

			'h015: kbd_matrix[28] <= key_pressed;  // Q
			'h01B: kbd_matrix[29] <= key_pressed;  // S
			'h022: kbd_matrix[30] <= key_pressed;  // X
			'h006: kbd_matrix[31] <= key_pressed;  // F2 = PREVIOUS/COLOR

			'h01C: kbd_matrix[32] <= key_pressed;  // A
			'h01A: kbd_matrix[33] <= key_pressed;  // Z
			'h04A: kbd_matrix[34] <= key_pressed;  // / = ?
			'h005: kbd_matrix[35] <= key_pressed;  // F1 = BACK/TEXT
			default: ;
		endcase
	end
end

// Fire buttons share the row lines with the keyboard.
wire [3:0] joy_fire = status[5] ? {3'b000, joystick_0[4]} : 4'b0000;

///////////////////////   CORE   /////////////////////////////////

wire       ce_pix;
wire [7:0] vid_r, vid_g, vid_b;
wire       vid_de, vid_hs, vid_vs, vid_hb, vid_vb;
wire [1:0] audio_code;

videobrain_core core
(
	.clk        (clk_sys),
	.reset_na   (~reset),

	.kbd_matrix (kbd_matrix),
	.joy_fire   (joy_fire),
	.audio_code (audio_code),
	.audio_stb  (),
	.joy_enable (),
	.f8_po_a_n  (),
	.f8_po_b_n  (),

	.brclk_ena  (),
	.ce_pix     (ce_pix),
	.vid_idx    (),
	.vid_r      (vid_r),
	.vid_g      (vid_g),
	.vid_b      (vid_b),
	.vid_de     (vid_de),
	.vid_hs     (vid_hs),
	.vid_vs     (vid_vs),
	.vid_hb     (vid_hb),
	.vid_vb     (vid_vb),

	.fifo_valid (),
	.fifo_level (),

	.hblank     (),
	.vblank     (),
	.burst      (),
	.csync      (),
	.scanline   (),
	.field      (),
	.hpos       (),
	.vpos       (),

	.final_mod  (),
	.background (),
	.x_zoom     (),
	.y_zoom     (),
	.video_en   (),

	.dl_addr    (dl_addr),
	.dl_data    (ioctl_dout),
	.dl_wr      (dl_wr),
	.dl_index   (dl_index),
	.cart_type  ({6'd0, status[7:6]}),

	.pc0        (),
	.pc1        (),
	.dc0        ()
);

///////////////////////   VIDEO   ////////////////////////////////

assign CLK_VIDEO = clk_sys;

wire [2:0] scale = status[4:3];
assign VGA_SL = (scale == 3) ? 2'b10 : (scale == 2) ? 2'b01 : 2'b00;

video_mixer #(.GAMMA(0)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),

	.scandoubler(scale || forced_scandoubler),
	.hq2x(scale == 1),

	.gamma_bus(),

	.R(vid_r),
	.G(vid_g),
	.B(vid_b),

	.HSync(vid_hs),
	.VSync(vid_vs),
	.HBlank(vid_hb),
	.VBlank(vid_vb),

	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(VGA_DE)
);

///////////////////////   AUDIO   ////////////////////////////////

// Two-bit R-2R ladder on port 0 bits 1:0, clocked by port 1 bit 4 (120k and
// 56k on the board). Centred in the unsigned range, then a single-pole low
// pass near 9kHz so the square edges do not alias in the 48kHz path.
wire [15:0] dac_level = 16'h5000 + {audio_code, 13'd0};

reg  signed [24:0] dac_filt = 25'sh0800000;
wire signed [24:0] dac_in   = {1'b0, dac_level, 8'd0};
always @(posedge clk_sys) dac_filt <= dac_filt + ((dac_in - dac_filt) >>> 8);

wire [15:0] dac = dac_filt[23:8];
assign AUDIO_L = dac;
assign AUDIO_R = dac;

assign LED_USER = ioctl_download;

endmodule
