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
- The BIOS parks every object (Y = 0x1FF, DX = DY = 0) and then waits. It can
  never proceed: no interrupt source is instantiated.

## Deliberately incomplete

- RES1/RES2 ROM contents and cartridge loading/mapper behavior.
- Final UV201 renderer and pixel/color path.
- Exact UV201 fetch cadence, FIFO spill behavior, Y zoom, and hardware mutation/writeback of RP/DY state.
- F3853/SMI interrupt path, including UV201 Y interrupt and external interrupt capture.
- Final VideoBrain port-I/O integration.
- Exact equalization/vsync half-line seam validation.
- MiSTer framework integration and RBF build.

## Next validation order

1. Start the fetcher during HBLANK rather than on `hblank_falling`, so the FIFO
   leads the beam. `selftest.rom` measures the error directly.
2. Add focused simulation for `f8_busif`: ROMC 00/01/02/03/05/0C/0E/11 with
   delayed grants. Reads latch `ext_rdata` at phase 2 regardless of
   `ext_grant`, which is only safe for the zero-wait RES1 path.
3. Instantiate `uv201_yint` and an interrupt path to the CPU, or the BIOS
   cannot get past its wait loop.
4. Define UV201 RP/DY writeback semantics and exact fetch cadence before adding the renderer.
5. Add ROM/cartridge storage and VideoBrain I/O/F3853 paths.
6. Integrate the MiSTer wrapper only after the machine-level interfaces are stable.
