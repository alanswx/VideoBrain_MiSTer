# VideoBrain MiSTer status - 2026-09-19

## Current infrastructure

- Exact Channel F `base_pack.vhd`, `f8_pack.vhd`, and `f8_cpu.vhd` are present.
- `f8_busif` tracks PC0/PC1/DC0 and translates external ROMC memory cycles into request/grant bus accesses.
- `uv202_clkgen`, timing, and arbiter form the UV202 infrastructure block.
- `sys_bus` provides the CPU map plus the UV201 buffered-bus view over shared RES2/RAM storage.
- `uv201_regs`, `uv201_fetcher`, and `uv201_fifo` are connected.
- `videobrain_core.vhd` now assembles the structural paths:
  - `f8_cpu -> f8_busif -> sys_bus`
  - `uv201_fetcher -> buffered bus / UV202 arbiter -> uv201_fifo`

This is an infrastructure checkpoint, not a bootable machine target.

## Verified in this pass

- Upstream Channel F blobs:
  - `base_pack.vhd`: `7eb371fdafe99f26a9d0f7111963491944ff35c5`
  - `f8_pack.vhd`: `c5998fd8fed1771e0e026d5da1fc57da25855f4c`
  - `f8_cpu.vhd`: `02ec542bbd6b8008f891f47b13b4fb30da0f9b56`
- ROMC PC/DC read and update behavior was checked against upstream `f8_psu.vhd`.
- ROMC 05 store handling now waits for the held CPU grant and commits data while the CPU is stalled.
- UV201 command bit 6 set selects object list A.
- Fetcher color packing matches UV201/MAME bit order: intensity in bits 4:3, color RP bits 5/6/7 into bits 2/1/0.
- Fetcher height encoding accepts zero before zero-to-64 conversion.
- Fetcher RP/row arithmetic wraps explicitly at 13 bits.
- HBLANK registered edges now line up with output positions 222 rising and 33 falling; FIFO clear uses HBLANK rising.
- Local glue was adjusted for the upstream package's `unsigned` `uv*` types.

The design now analyzes and elaborates under GHDL (VHDL-2008) and runs under
Verilator. Three source errors had to be fixed first:

- `uv202_timing.vhd`: two `CONSTANT` declarations sat after `BEGIN`.
- `uv201_regs.vhd`: `cur_field & "00000" & ...` was an ambiguous `&` overload.
- `f8_busif.vhd`: ROMC 01/0C/0E/11 updated PC0/DC0 from `dw`, the CPU's own
  output, instead of the byte the addressed device placed on the bus. These
  four are the memory-sourced ROMC states; 0A and 12-19 are CPU-sourced and
  were already correct. The BIOS spun forever at 076D because its fill loop
  branched by -1 instead of -3. Confirmed by the corrected target, 076B,
  landing on the `ST` that heads a 64-byte fill of the UV201 Y registers.

## Simulation

`verilator/` holds a graphical (SDL2 + ImGui) and a headless simulator. Both
run the VHDL through `ghdl synth --out=verilog` first, since Verilator does not
read VHDL. See `verilator/README.md`.

`sys_bus` gained an ioctl-style download port (index 0 = RES1, 1 = RES2,
2 = cartridge) and cartridge storage. One write process per array: a single
process selecting between them defeats GHDL's RAM inference and the netlist
grows from 21k to 103k lines.

`videobrain_core` now exposes `brclk_ena`, the UV201 renderer controls
(`final_mod`, `background`, `x_zoom`, `y_zoom`, `video_en`) and the download
port. The renderer itself lives in `verilator/sim.v` and follows MAME
`uv201.cpp` `screen_update()`.

Measured with `verilator/selftest.rom`, a hand-assembled F8 program that draws
one 16x16 object:

- The pixel path is correct end to end: CPU, bus, UV201 registers, fetcher,
  buffered-bus DMA, FIFO, renderer, palette.
- An object programmed at x=40 draws at x=49. The fetcher starts on
  `hblank_falling`, which is already the first active pixel, and needs 9 BRCLK
  to reach its first FIFO push. Real hardware fills the FIFO during HBLANK.
  This is the fetch-cadence item below, now quantified.
- The BIOS parks every object (Y = 0x1FF, DX = DY = 0) and then waits.

The machine boots. The BIOS reaches its title screen (VIDEO BRAIN TM /
CHOOSE KEY / ENTER CARTRIDGE) and cartridges reach their own menus:
Gladiator, Tennis, Pinball and Blackjack all display correctly. Pressing
RUN/STOP on Tennis starts the game, which renders a recognisable court,
net, scoreboard and player sprites.

Three defects had to be fixed to get there, each found in simulation:

- ROMC 1D (XDC) was the only ROMC state the microcode issues that f8_busif
  did not implement, and there was no DC1 to swap with. The BIOS spun in the
  copy loop at 027B-0281 forever.
- The interrupt path did not exist at any level. See the commits for
  f8_cpu, f8_busif and the new f3853.vhd.
- The fetcher started on hblank_falling, which is already the first active
  pixel, so every object drew nine pixels right of its programmed X.

Tennis renders correctly: solid net, three clean player sprites, intact
score row. Blackjack draws black and red card suits on green, which
exercises the per-object colour path and the 32-entry palette.

The corruption that was there earlier was fetch starvation. The fetcher
read all seven registers of every object before testing whether it was on
the scanline, which is 112 of the 222 available BRCLK per line before any
bitmap DMA; eight lines per frame never finished and 137 FIFO entries were
discarded by the HBLANK clear. Rejecting on the start row after three
reads fixed it.

docs/ holds the collected hardware documentation: both Umtech patents, the
Bomarc schematics, Sean Riddle's board netlist, and the 1,671-message
Channel-F/VideoBrain group archive. kevtris's 2013 logic-analyzer sessions
in that archive are the only measurements of real silicon and outrank both
the patents and MAME where they disagree - height is six bits with 0
meaning 64 and bits 6/7 ignored, and width 0 means 32 bytes.

## Not yet done

Blocking a hardware test:

- The design has never been through Quartus. Unknown: whether it accepts the
  VHDL-2008 as GHDL does, whether the 14.318181 MHz domain closes timing, and
  whether the PLL lands exactly (M=63/N=2/C=110 is reachable from 50 MHz, but
  Quartus picks the counters).

Modelled wrongly or not at all, in rough order of how likely software is to
notice:

- Hardware increments each segment's pointer and decrements its height as it
  draws, so the CPU must rewrite them every frame. The RTL keeps them static.
  The BIOS rewrites them anyway, so nothing has broken yet.
- Bitmap DMA is one byte per request. Hardware fetches in two-byte chunks as
  soon as the FIFO has slots.
- The FIFO's 10-to-8 spill hysteresis has never been checked against hardware.
- xcopy's interaction with X and Y zoom is not implemented.
- `f8_busif` latches `ext_rdata` at phase 2 regardless of `ext_grant`, which is
  only safe for the zero-wait RES1 path.
- The F3853 timer is clocked from BRCLK; hardware clocks the SMI at 2 MHz.
  Only the external interrupt has been exercised.
- The equalization and vsync half-line seam is a whole-line approximation.

Missing subsystems:

- Analogue paddles. An NE555 retriggered at HBLANK pulses EXT INT and the pot
  position is read back out of the freeze registers, which needs CMD_FRZ.
- Audio is the raw 2-bit DAC code with no filtering, and `audio_stb` is unused.
- Cartridge mappers: Timeshare has 1K RAM at 1800-1BFF, Money Minder 2K at
  3800-3FFF. Only plain ROM carts work.
- The 3000-3FFF expansion window.

Known bugs:

- Pinball will not accept a typed game number, though Tennis takes RUN/STOP.
  CMD_KBD is clear, so column 8 is being scanned; the cause is elsewhere.
- A stray object renders at the bottom right of the BIOS and Gladiator screens.

## Next validation order

1. Build in Quartus and fix whatever it rejects. Nothing else can be trusted
   on hardware until this happens.
2. Segment pointer and height writeback, and two-byte DMA chunks. Both are in
   uv201_fetcher and both are documented in the group archive.
3. Chase the Pinball digit entry and the stray bottom-right object.
4. Convert the VHDL to Verilog a file at a time, leaves first and the CPU
   last, checking each against the frame hashes of selftest.rom,
   selftest_int.rom and the booting titles.
5. Paddles, audio filtering, cartridge mappers.
