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

No HDL compiler/simulator is installed in the current environment, so this pass is static review only.

## Deliberately incomplete

- RES1/RES2 ROM contents and cartridge loading/mapper behavior.
- Final UV201 renderer and pixel/color path.
- Exact UV201 fetch cadence, FIFO spill behavior, Y zoom, and hardware mutation/writeback of RP/DY state.
- F3853/SMI interrupt path, including UV201 Y interrupt and external interrupt capture.
- Final VideoBrain port-I/O integration.
- Exact equalization/vsync half-line seam validation.
- MiSTer framework integration and RBF build.

## Next validation order

1. Compile the structural RTL with a VHDL-2008-capable tool and fix type/elaboration errors only.
2. Add focused simulation for `f8_busif`: ROMC 00/01/02/03/05/0C/0E/11 with delayed grants.
3. Simulate HBLANK edges, FIFO clear, and the fetcher's line-start request sequence.
4. Define UV201 RP/DY writeback semantics and exact fetch cadence before adding the renderer.
5. Add ROM/cartridge storage and VideoBrain I/O/F3853 paths.
6. Integrate the MiSTer wrapper only after the machine-level interfaces are stable.
