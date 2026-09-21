# Cartridge status

Every cartridge in the set was run in the headless simulator: a capture at
frame 150, then SPACE (RUN/STOP) held from frame 150 and a second capture at
frame 280. Screens were inspected, not just hashed. Rerun it with

    verilator/obj_dir_headless/Vtop --cart <file> --cart-type <N> \
        --frames 280 --press SPACE@150:25 --shot 279

`--cart-type` is 0 standard, 1 Timeshare, 2 Money Minder, matching the OSD
option. Nothing here has been tested on real hardware.

## Summary

| Cartridge | Size | Mapper | Status | Notes |
|---|---|---|---|---|
| Blackjack | 2K | standard | works | "1 OR 2 PLAYERS?" over black and red card suits on green. Best colour test in the set. |
| Checkers | 4K | standard | works | Advances to "YOU MOVE FIRST ? Y OR N". |
| Demonstration | 4K | standard | works | Six lines, each a different colour. Seven colours on screen. |
| Financier | 4K | standard | **broken** | Striped magenta and blue bands across the top and solid colour blocks. See below. |
| Gladiator | 4K | standard | works | Menu, then advances on RUN/STOP. |
| Lemonade Stand | 4K | standard | works | Slow to boot: blank at frame 150, full menu by 280. |
| Math Tutor 1 | 4K | standard | works | "CHOOSE / TUTOR 1 / PROBLEM 2" on olive. |
| Money Minder | 4K | money_minder | works | Title screen. RAM at 3800-3FFF exercised; deeper functions untested. |
| Music Teacher 1 | 2K | standard | **partial** | Header draws, menu items below do not. Ink falls from 2.9% to 1.0% after the keypress. |
| Pinball | 2K | standard | partial | Menu correct, but a typed game number is never accepted. |
| Tennis | 4K | standard | **plays** | RUN/STOP starts the game: court, net, scoreboard, player sprites. |
| Timeshare | 2K | timeshare | **blank** | Nothing drawn at any point. See below. |
| Vice Versa | 4K | standard | works | Advances to "YOU PLAY FIRST ? Y OR N". |
| VideoArtist | 2K | standard | works | Design selection menu. |
| Wordwise 1 | 2K | standard | works | Multi-colour skill menu. |
| Wordwise 2 | 2K | standard | works | Four-entry multi-colour menu. |
| APL / Computational Language | - | comp_language | **not loadable** | Dumped as separate .u1-.u11 chip images, and the mapper is not implemented. |

Fourteen of sixteen boot and render correctly. One plays.

## Known failures

### Timeshare - blank

Nothing is drawn with either mapper setting, so the Timeshare mapper is not the
cause. At frame 119 the CPU is alive and writing UV201 object registers
(`romc=05`, `DC0=0813`) with `video_en=1`, yet the frame is uniform black while
the background register reads 06. That contradiction is unexplained and is the
thing to chase first.

Timeshare is the communications cartridge and expects the Expander modem
hardware, which does not exist here, so it may legitimately stop early. That
has not been confirmed and should not be assumed.

### Financier - corrupted

Alternating colour bands on consecutive scanlines. VideoBrain software changes
the background register from the Y-interrupt handler to paint horizontal
colour bands, so the mechanism is in use here and is going wrong. Suspects, in
order: the Y-interrupt firing on the wrong line, the background register being
sampled at the wrong point in the line, and the fetcher dropping objects.

### Music Teacher 1 - partial

Draws its header but not the menu items, and loses content between frames 150
and 280. Likely the same class of problem as Financier.

### Pinball - no digit entry

The menu is correct and Tennis proves keyboard input works, so this is specific
to typing a number. `CMD_KBD` is clear, so keyboard column 8 is being scanned
and that is not the cause. The BIOS keycode is `row * 9 + column`, which is
worth checking against what the cartridge expects.

## Not implemented

- **comp_language** (APL): bank register at 1000-100F with a documented bus
  conflict quirk, six ROM banks. MAME `bus/vidbrain/comp_language.cpp`.
- **info_manager**: 6K ROM, 1K RAM. A prototype; no dump here.

## Mapper reference

From MAME `bus/vidbrain/`. `/CS1` is 1000-17FF and `/CS2` is 1800-1FFF.

| Mapper | CS1 | CS2 | 3000-3FFF |
|---|---|---|---|
| standard | ROM | ROM | - |
| timeshare | 2K ROM | 1K RAM, mirrored | - |
| money_minder | 4K ROM | 4K ROM | 1K RAM at 3800, mirrored |
| info_manager | 2K ROM | 1K RAM | ROM |
| comp_language | ROM + RAM above 1C00 | same | banked ROM |
