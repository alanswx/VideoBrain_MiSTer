# VideoBrain Family Computer for MiSTer

An FPGA implementation of the 1977 VideoBrain Family Computer: Fairchild F8
(3850 CPU, 3853 SMI) with the Umtech UV201 video chip and UV202 clock/bus chip.

## Status

The BIOS boots to its title screen and cartridges run. Not yet tested on real
hardware; see STATUS.md for what is and is not implemented.

## Installing

Put `VideoBrain.rbf` in a folder on the SD card, alongside:

    boot.rom     4096 bytes: RES1 then RES2, 2048 each

Build it from the two BIOS dumps:

    tools/make_boot_rom.sh uvres1.bin uvres2.bin boot.rom

Main_MiSTer uploads `boot.rom` automatically at core start. Load cartridges
from the OSD.

## Keyboard

Nine columns by four rows. Digits are shifted letters, and SHIFT is a lock:
tap it, do not hold it.

    1=Z 2=X 3=C 4=S 5=D 6=F 7=W 8=E 9=R 0=/

    SPACE       RUN/STOP
    BACKSPACE   ERASE/RESTART
    F1          BACK/TEXT
    F2          PREVIOUS/COLOR
    F3          NEXT/CLOCK
    F4          SPECIAL/ALARM

## Building

Quartus 17.0.2 Standard. Open `VideoBrain.qpf`.

`verilator/` holds a graphical and a headless simulator that share the core's
RTL renderer; see `verilator/README.md`. `docs/` (not in git) collects the
hardware documentation the implementation was derived from.

## Sources

The Umtech patents US 4,232,374 and US 4,177,462, Sean Riddle's board netlist
and schematics, MAME's `vidbrain.cpp`/`uv201.cpp`/`f3853.cpp`, and kevtris's
2013 logic-analyzer measurements in the Channel-F/VideoBrain group archive.
Where these disagree, the measurements win.
