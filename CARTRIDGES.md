# Cartridge status

Every cartridge in the set was run in the headless simulator and the screens
were inspected, not just hashed. Nothing here has been tested on real hardware.

    verilator/obj_dir_headless/Vtop --cart <file> --cart-type <N> \
        --frames 150 --shot 149

`--cart-type` is 0 standard, 1 Timeshare, 2 Money Minder, matching the OSD
option.

## Summary

**All sixteen boot and render their first screen correctly.** Tennis plays.

| Cartridge | Size | Mapper | First screen | Notes |
|---|---|---|---|---|
| Blackjack | 2K | standard | correct | "1 OR 2 PLAYERS?" over black and red card suits on green. Best colour test in the set. |
| Checkers | 4K | standard | correct | RUN/STOP advances to "YOU MOVE FIRST ? Y OR N". |
| Demonstration | 4K | standard | correct | Six lines, each a different colour, seven colours on screen. |
| Financier | 4K | standard | correct | Full function menu on green. |
| Gladiator | 4K | standard | correct | Game-number prompt; advances on RUN/STOP. |
| Lemonade Stand | 4K | standard | correct | Slow to boot: blank at frame 150, full menu by 280. |
| Math Tutor 1 | 4K | standard | correct | "CHOOSE / TUTOR 1 / PROBLEM 2" on olive. |
| Money Minder | 4K | money_minder | correct | "MONEY MANAGER" title. RAM at 3800-3FFF is reachable; deeper functions untested. |
| Music Teacher 1 | 2K | standard | correct | "PLAY/RECORD 1 / LEARN A SONG 2". |
| Pinball | 2K | standard | correct | Menu fine, but a typed game number is never accepted. See below. |
| Tennis | 4K | standard | **plays** | RUN/STOP starts the game: court, net, scoreboard, player sprites. |
| Timeshare | 2K | timeshare | correct | "TIMESHARE" title on cyan, then the screen blanks around frame 130. See below. |
| Vice Versa | 4K | standard | correct | Advances to "YOU PLAY FIRST ? Y OR N". |
| VideoArtist | 2K | standard | correct | Design selection menu. |
| Wordwise 1 | 2K | standard | correct | Multi-colour skill menu. |
| Wordwise 2 | 2K | standard | correct | Four-entry multi-colour menu. |
| APL / Computational Language | - | comp_language | **not loadable** | Dumped as separate .u1-.u11 chip images, and the mapper is not implemented. |

## A note on method

An earlier version of this table called Financier corrupted, Music Teacher 1
partial and Timeshare blank. All three were wrong, and for two different
reasons worth recording.

Timeshare was sampled at frames 150 and 280, both after its title screen had
already gone. Sampling a moving display at two fixed frames is not enough; the
frame log (`--frame-log`) shows when a screen actually changes.

Financier and Music Teacher 1 were judged on a capture taken after holding
SPACE. RUN/STOP is a valid input for Tennis and Checkers but meaningless to a
cartridge waiting for a typed function name, so those captures showed whatever
state an invalid keypress produced, not a rendering fault. Judge a cartridge on
the screen it actually presents.

## Open questions

### Timeshare blanks after its title

The title renders correctly on cyan, then the screen goes blank around frame
130 and stays blank. Timeshare is the communications cartridge and expects the
Expander modem, which does not exist here, so stopping early is plausible. That
has not been confirmed.

### Pinball will not take a typed digit

The menu is correct and Tennis proves keyboard input works, so this is specific
to entering a number. `CMD_KBD` is clear, so keyboard column 8 is being scanned
and that is not the cause. The BIOS keycode is `row * 9 + column`, which is
worth checking against what the cartridge expects.

### Financier after an invalid key

Holding SPACE leaves Financier drawing striped colour bands. VideoBrain
software paints bands by rewriting the background register from the
Y-interrupt handler, so the mechanism is in use. Whether this is a real
rendering fault or simply what the cartridge does when handed a key it did not
ask for is unresolved. The way to settle it is to type a valid function name.

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
