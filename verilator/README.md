# Verilator harness

Verilator reads Verilog only, so every build first runs the VHDL through
`ghdl synth --out=verilog`. Module, instance and RAM names survive that step;
intermediate combinational nodes become `nNNNN`.

    make            # graphical sim (SDL2 + ImGui)  -> ./obj_dir/Vtop
    make headless   # batch sim (no SDL)            -> ./obj_dir_headless/Vtop
    make netlist    # just the Verilog netlist      -> gen/videobrain.v
    make lint

Requires ghdl (VHDL-2008), verilator, zlib, and sdl2 for the graphical target.
Run from this directory; the default ROM paths are relative to it.

    ./obj_dir/Vtop --run
    ./obj_dir_headless/Vtop --cart "../software/Gladiator ....bin" --frames 300 --shot-last
    ./obj_dir_headless/Vtop --help

`videobrain_core` has no pixel path of its own: it exposes the UV201 FIFO and
takes `fifo_pop` as an input, so the renderer lives in `sim.v` and follows MAME
`uv201.cpp` `screen_update()`. Moving it into RTL is a core change, not a
harness one.

## selftest.rom

A hand-assembled F8 program that sets up one 16x16 object and halts, so the
CPU, bus, UV201 registers, fetcher, FIFO and renderer can be exercised without
the BIOS. Regenerate it with the snippet in git history if the layout changes.

    ./obj_dir_headless/Vtop --res1 selftest.rom --frames 8 --shot-last --ascii

It draws at x=49 rather than the programmed x=40: the fetcher starts on
`hblank_falling`, which is the first active pixel, and takes 9 BRCLK to reach
its first FIFO push. See STATUS.md.

## Converting VHDL to Verilog one file at a time

The netlist is the reference. Write `rtl_v/<entity>.v`, add the entity name to
`CONVERTED` in the Makefile, and rebuild: that module is stripped from the
netlist and yours is compiled in its place. The VHDL stays in `VHD_SRC` so the
rest of the hierarchy still elaborates.

Check equivalence by frame hash, before and after:

    ./obj_dir_headless/Vtop --res1 selftest.rom --frames 8 --frame-log
    ./obj_dir_headless/Vtop --frames 60 --frame-log

Convert leaves first (`buffered_bus`, `uv201_fifo`, `uv202_clkgen`), the CPU
last: `f8_cpu.vhd` and its packages are the upstream Channel F blobs whose
hashes STATUS.md records, and there is no Verilog F8 anywhere to check against.
