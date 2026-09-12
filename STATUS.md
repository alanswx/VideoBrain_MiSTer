# VideoBrain FPGA Core

**Status as of this document:** UV202 arbitration layer + F8 bus interface +
`sys_bus` (unified CPU-side memory map) + first `uv201/` module (register
file) drafted. Syntax-checked with GHDL 4.1 against a hand-written stub
`base_pack`/`f8_pack` (the real packages aren't in this file set) - this
caught and fixed two real, tool-independent bugs, see "GHDL pass" below.
**Still no simulation run against the real packages, no testbenches, no
`uv202_top.vhd`, no `videobrain_top.vhd`.**

## GHDL pass (new)

Since nothing had been compiled at all yet, and this session's edits touch
a function (`f8_busif.classify()`) used by both the arbiter and the new
`sys_bus`, a stub `base_pack`/`f8_pack` was hand-written (types/functions
inferred from usage, NOT the real packages) purely to let GHDL parse
everything once. `uv202_pack.vhd`, `uv201_regs.vhd`, `uv202_arbiter.vhd`,
and `sys_bus.vhd` all compiled clean against the stub. `uv202_clkgen.vhd`,
`uv202_timing.vhd`, and `f8_busif.vhd`'s PC0/PC1/DC0 arithmetic threw errors
against the stub (`pc0 + 1`, `pc0(13 downto 0)` slicing) - these are almost
certainly stub inaccuracies (the stub guessed `uv16`/etc. as
`std_logic_vector`, but the real ones are evidently `unsigned` or have
`numeric_std_unsigned`-style operator support), **not verified as real
bugs** - re-run against the real packages before trusting this either way.

Two real, package-independent bugs were found and fixed while doing this:

1. **`f8_busif.classify()` used `RETURN x WHEN c ELSE y;` four times.**
   GHDL 4.1 rejects a conditional expression directly in a `return`
   statement (confirmed with an isolated minimal repro, independent of any
   VideoBrain-specific code) even under `--std=08`, even parenthesized -
   but accepts the identical expression as a *variable* assignment. Fixed
   by assigning through a local `result` variable and returning that. If
   this project's sim flow is GHDL-based (STATUS.md's testbench plan says
   it is: "GHDL + GTKWave"), this would have silently failed to compile
   the very first time `classify()` was pulled into a testbench - worth
   grepping the rest of the tree for the same `RETURN ... WHEN ... ELSE`
   pattern before assuming any other function using it is fine.
2. **`uv201_regs.vhd` (new, this session) originally named its command-
   register output ports `cmd_x_zm`/`cmd_frz`/etc.** VHDL identifiers are
   case-insensitive, so those ports were the *same identifier* as (and
   silently shadowed) the `CMD_X_ZM`/`CMD_FRZ`/... bit-position constants
   pulled in from `uv202_pack` via `USE ... ALL`, breaking the
   `CONSTANT ..._BIT := CMD_X_ZM` aliases at elaboration with a
   type-mismatch error. Renamed the ports (`o_x_zm`, `o_frz`, ...) to avoid
   the collision. Worth keeping in mind for any future module that both
   imports `uv202_pack`'s `CMD_*` constants and wants to expose
   command-bit taps as ports - the naming collision is easy to hit again.

---

## Project goal

MiSTer FPGA core for the VideoBrain Family Computer. Reuses the existing F8
CPU (`f8_cpu.vhd`) from the ChannelF_MiSTer core as-is. New work is the
VideoBrain-specific chipset: UV202 (timing/bus arbiter) and UV201 (video
renderer), plus the glue needed to connect the borrowed F8 core to a
VideoBrain-shaped memory map instead of Channel F's.

**Strategy:** cycle-accurate where the source doc supports it, explicitly
simplified (with non-blocking TODOs) where it doesn't yet. MVP path is:
get register file + a MAME-style non-cycle-accurate renderer producing
pixels first, then retrofit the real FIFO/fetcher/wait-state timing.
UV201 (renderer) work has not started — everything so far is UV202-side.

---

## Reference sources

1. kevtris "Videobrain Unwrapped" v0.05 — primary hardware reference.
   http://blog.kevtris.org/blogfiles/videobrain/videobrain_unwrapped.txt
2. MAME driver — register-map/palette cross-check only, NOT a timing
   reference (MAME's UV201 model is frame-based, not cycle-accurate; its
   own TODO list admits wait states aren't modeled).
   `src/mame/vidbrain/{vidbrain.cpp, uv201.cpp, uv201.h}`
3. ChannelF_MiSTer — source of the F8 CPU core we're reusing, and the
   template for the ROMC bus-interface pattern our `f8_busif` is based on.
   `rtl/chf/{f8_cpu.vhd, f8_psu.vhd, channel_f.vhd}`

---

## File tree — what exists now

```
rtl/
├── sys_bus.vhd            -- NEW. Unified CPU-side memory map (RES1/RES2/
│                              RAM/UV201-regs/cart-stub). See its own file.
├── uv202/
│   ├── uv202_pack.vhd     -- UPDATED. Added ACC_RES2 + shared cpu_addr_fold().
│   ├── uv202_clkgen.vhd   -- DONE. MCLK->BRCLK divide, CPU enable, brclk_phase.
│   ├── uv202_timing.vhd   -- DONE except one flagged TODO (see below).
│   ├── uv202_arbiter.vhd  -- MVP. Fixed-duration wait-stating, works structurally.
│   └── f8_busif.vhd       -- UPDATED (bugfix, see GHDL pass). Still UNSIMULATED
│                              against real packages. Highest-risk file so far.
└── uv201/
    └── uv201_regs.vhd     -- NEW. Register file only (object RAM 0x00-0x8F +
                               control/status 0xF0-0xFB). No fetcher/FIFO/
                               renderer yet - see "Order of work" below.
```

No `uv202_top.vhd`. No `videobrain_top.vhd`. No testbenches have been
written or run against the real packages — the GHDL pass above is a syntax
check against a stub, not a functional simulation.

---

## Order of work (why sys_bus + uv201_regs, and not the fetcher/renderer, this session)

Before this session, every module that existed talked about bus accesses
(`ext_req`/`cpu_grant`/`ACC_UV201_RD`/etc.) but nothing actually *was* a
byte of RAM, ROM, or a UV201 register - so none of it was testable even in
isolation beyond "does the FSM's state machine shape look right." That was
the actual blocker, not lack of rendering: you can't write a meaningful
`f8_busif` or `uv202_arbiter` testbench without something real on the other
end of `ext_rdata`.

So the two things added this session were picked to unblock testing of
everything already written, in this order:

1. **`uv201_regs.vhd` first** - it has no dependency on anything not
   already done (`uv202_pack` for register offsets/command bits), and
   `sys_bus` needs it to exist before `sys_bus` can route UV201 accesses
   anywhere real.
2. **`sys_bus.vhd` second** - depends on `uv201_regs` (just built) and
   `uv202_pack`'s address constants/`cpu_addr_fold` (already existed).
   This is the piece that finally lets `f8_busif` + `uv202_arbiter` +
   `uv201_regs` be wired into one thing and simulated end-to-end.

Deliberately NOT done this session, and why, so the reasoning doesn't have
to be re-derived later:

- **`uv201_fetcher.vhd`/`uv201_render.vhd` (the actual pixel pipeline)** -
  these need `uv201_regs`'s object RAM (done) AND `uv202_timing`'s
  hpos/vpos/hblank taps (already existed) AND a buffered-bus memory view
  that doesn't exist yet (`sys_bus` is CPU-side only, see its file header).
  Building the fetcher before the buffered bus exists would mean building
  it against a guessed interface and re-deriving it later. Next in line
  once a buffered-bus view is sketched.
- **`uv202_top.vhd`** - straightforward now that `sys_bus` exists (wire
  clkgen + timing + arbiter + sys_bus + f8_busif together), but doing it
  before a testbench exists to exercise it risks discovering interface
  mistakes at integration time instead of unit time. The `tb_f8_busif`
  plan from the prior session (see "Next step" below) is still the more
  useful next action - it now has something real (`sys_bus`) to point its
  mock/real `ext_rdata` at instead of only a canned pattern.
- **F3853-equivalent SMI / interrupts** - blocked on the `f8_cpu.vhd`
  interrupt-input gap (`f8_busif.vhd` gap #1, still open, unchanged this
  session).

## Per-file state

### `uv202_pack.vhd` — solid
Clock constants, per-scanline BRCLK timing constants, CPU-bus and
buffered-bus address maps, UV201 register offsets (cross-checked against
MAME's `uv201.cpp`), command register bit positions, `bus_access_t` enum,
base wait-state constants. **Updated this session:** added `ACC_RES2` to
`bus_access_t` and a shared `cpu_addr_fold()` function (both `f8_busif` and
`sys_bus` now call the same fold instead of each rolling their own copy).
Low risk, foundational, nothing pending.

### `uv202_clkgen.vhd` — solid
MCLK→BRCLK÷4 divide, free-running ~2MHz CPU enable (deliberately NOT
phase-locked to BRCLK — matches real hardware's separate-oscillator
design, not the UV202's own buggy ÷7 output which we're not reproducing),
free-running 2-bit `brclk_phase` tap for the UV201 modulo-4 register-read
stretch (not yet consumed anywhere — reserved for `uv202_arbiter`
accuracy upgrade, see below). Open question asked, unanswered: what is
the actual target `CLK_DIV_MCLK` for the MiSTer PLL setup? Currently
generic/passthrough-default; fine to leave that way until it matters.

### `uv202_timing.vhd` — solid structure, unresolved primary-source timing ambiguity
Scanline/field counters, HBLANK/VBLANK/BURST/CSYNC/FIELD generation,
`hpos`/`vpos`/`hblank_falling`/`hblank_rising` taps for downstream
modules. **TODO (not verified):** the source document is internally
inconsistent about field length. Its frame table gives 263/262 scanlines,
while the listed odd/even vertical-sequence components sum to 252.5 lines,
and the prose immediately afterward says 252.2 lines. The current
`NORMAL_LINES_ODD=244`/`NORMAL_LINES_EVEN=243` choice was made to satisfy
the 263/262 field totals, not because the document resolves the discrepancy.
This may require a fresh hardware capture rather than further textual
re-derivation. Still non-blocking for CPU/UV201 register/DMA bring-up, which
only needs HBLANK/VBLANK/hpos/vpos rather than final composite pulse shape.

### `uv202_arbiter.vhd` — MVP, structurally complete
Implements the doc's access classification, wait insertion, and DMA
request/grant, using **fixed** wait durations rather than the doc's fully
cycle-exact model (modulo-4 stretch, DMA-collision penalty doubling, the
48-BRCLK fetcher breakover point). This is a deliberate, explicitly-
flagged simplification: the interface (`cpu_grant`/`cpu_wack`/
`cpu_stall`/`dmareq0`/`dmareq1`) is designed to not need to change when
the internals get more accurate later — only the one `body_len_for()`
function does. **As currently written, the FSM takes 5 BRCLK end-to-end for
RAM/cart and DMA accesses and 7 BRCLK for UV201 register accesses:** one
`ST_SETUP` cycle + 3/5 `ST_BODY` cycles + one `ST_DONE` grant cycle. This is
one BRCLK longer than the 4/6-BRCLK low-end targets previously quoted here;
comments now reflect the RTL rather than hiding that discrepancy. Whether to
fold `ST_DONE` into the final body cycle remains an explicit timing decision
for the arbiter testbench. CPU-priority-over-DMA and DMA0/DMA1 round-robin are
implemented for real (not simplified), since those are simple stated
rules in the doc. Where a choice had to be made between simple/slower vs.
exact/complex, the arbiter always takes the slower option (e.g. always
pays the 1-BRCLK setup penalty even in cases the doc says real hardware
skips it) — deliberately a "never faster than real hardware" bias.

### `f8_busif.vhd` — drafted, UNSIMULATED, highest risk in the tree
PC0/PC1/DC0 tracking ported from `f8_psu.vhd`'s ROMC case statement
(same states, same register semantics), with the local-ROM/IO-port/
interrupt-priority-chain logic stripped out and replaced by
`ext_addr`/`ext_rd`/`ext_wr`/`ext_wdata`/`ext_rdata` talking to a not-yet-
written `sys_bus`, plus `ext_req`/`ext_class`/`ext_grant` talking to
`uv202_arbiter`.

Two concrete implementation defects found during source review have now been
fixed before testbench work:

- The ROMC `00101` RAM-write pre-request path incorrectly drove the top-level
  `ext_wdata` port directly while the architecture also continuously drove it
  from `ext_wdata_l`. It now drives `ext_wdata_l` consistently, eliminating
  the multiple-driver conflict.
- `classify()` recursively called itself to fold the `2800-3FFF` mirror. The
  mirror is now folded once into a local effective address and classified
  iteratively, avoiding a likely Quartus synthesis problem.

**Remaining explicitly flagged gaps, both non-blocking for now:**

1. **No interrupt path exists.** `f8_cpu.vhd` as pulled from
   ChannelF_MiSTer has no interrupt input at all — its `romc` output
   depends only on `bcc`/`test`/`opcode`, never on an external
   int-pending signal. VideoBrain uses Y-interrupts routinely (UV201
   `ext_int` → F3853 SMI → CPU). Either `f8_cpu.vhd` needs a small
   upstream patch (an int-pending input forcing ROMC 01111/10011 entry),
   or another mechanism needs to be found. Not implemented anywhere yet.
   Does not block register/DMA bring-up work, which needs no interrupts
   to validate.
2. **Wait-handshake phase alignment is unverified.** The phase=1
   read-request / phase=2 data-valid and phase=4 write-request / phase=6
   write-commit timing was inferred from `f8_psu`'s existing convention, not
   independently re-derived or simulated. This is the single most
   important thing to verify before trusting this module with real ROM
   code — see Next Steps.
3. **Not every external-read ROMC state currently raises `ext_req`.** Only
   `00000` (IFETCH) asserts the read-side request. `00001`, `00010`, `00011`,
   `01100`, `01110`, and `10001` all consume `ext_rdata`/assert `ext_rd` but
   never classify the address or request the arbiter first. For accesses in
   RAM/cart/UV201 space that appears to bypass required wait insertion. This
   was found during the present source pass and is intentionally left for the
   unit testbench because adding request phases now would require guessing at
   the very phase alignment the testbench is meant to establish.

**RESOLVED this session (was: RES1/RES2 `ACC_NONE` ambiguity, open decision
#1):** `classify()` now returns `ACC_NONE` only for RES1 (genuinely
0-wait, doesn't route through the arbiter) and a new `ACC_RES2` for RES2
(2000-27FF), which takes the same 3-cycle body as RAM/cart via the
arbiter's existing `OTHERS` case - no arbiter change needed, just the new
enum value. Both `classify()` and `sys_bus`'s device routing now share one
`cpu_addr_fold()` (in `uv202_pack`) for the 2800-3FFF mirror instead of
each having their own copy that could drift apart.

**Also fixed this session:** `classify()`'s `RETURN x WHEN c ELSE y;`
pattern (used 4 times) doesn't compile under GHDL 4.1 even with
`--std=08` - confirmed with an isolated repro unrelated to this codebase.
Rewritten to assign through a local variable and `RETURN` that instead;
identical semantics, GHDL-safe. See "GHDL pass" at the top of this
document - this is a real, tool-specific finding, not a style choice.

### `uv201_regs.vhd` — NEW, MVP-complete for register storage, untested against real packages
Object RAM (0x00-0x8F) + control/status registers (0xF0-0xFB), field-by-
field cross-checked against MAME's `uv201.cpp` `read()`/`write()` (offsets,
bit packing, and the read-only-vs-write-only split all match). Does NOT
include the fetcher/FIFO/renderer (deliberately - see "Order of work"
above) or the Y-interrupt timer (register storage only; a future
`uv201_yint.vhd` consumes `y_int`/`o_yint_ho` without this entity's
interface changing). Freeze-capture (X-Freeze/Y-Freeze registers) is wired
to `capture_stb`/`capture_x` inputs that nothing drives yet - the real
driver is the joystick NE555/SMI `ext_int` path, which doesn't exist in
this core yet either; exposed now so the interface doesn't need to change
when that's built. Compiled clean under GHDL against the stub packages.

### `sys_bus.vhd` — NEW, MVP-complete for CPU-side routing, untested against real packages
Combinational read mux + write demux over RES1 ROM (zero contents, no
loader yet), RES2 ROM (same), 1K system RAM (registered write,
combinational read), the new `uv201_regs` instance, and a cartridge stub
(open-bus reads, dropped writes). CPU-side only - does NOT model the
buffered bus the UV201 DMA fetcher will need (see "Order of work" above).
RAM's combinational-read assumption and its interaction with the arbiter's
still-undecided `ST_DONE` timing (open decision #4 below) are flagged
together in the file header - worth resolving as one decision, not two.
Compiled clean under GHDL against the stub packages.

---

## Open decisions queued for next session

1. ~~RES1 vs RES2 `ACC_NONE` ambiguity in `f8_busif.classify()`~~ —
   **RESOLVED this session**, see `f8_busif.vhd` section above.
2. **`CLK_DIV_MCLK` target value** for `uv202_clkgen` — depends on the
   actual MiSTer PLL configuration once we get to top-level/framework
   integration. Not urgent.
3. **Interrupt mechanism** — needs either an `f8_cpu.vhd` patch or an
   alternate design. Not urgent for current bring-up phase but will
   block real software (most VideoBrain carts likely use Y-interrupts).
4. **Arbiter `ST_DONE` timing** — current RTL grants on a separate final
   BRCLK, making RAM/cart/DMA accesses 5 BRCLK and UV201 accesses 7 BRCLK.
   Decide from simulation/hardware timing whether to keep that conservative
   extra cycle or issue the grant on the final `ST_BODY` cycle to reach the
   nominal 4/6-BRCLK low-end targets.

## Next step in progress (per last exchange)

**Prerequisite before any of the below can actually run:** this session's
GHDL pass used a hand-written stub `base_pack`/`f8_pack` (types/functions
guessed from usage) purely to syntax-check parsing. The real packages need
to be dropped into `rtl/` (or wherever they live in the actual repo) and
everything re-analyzed for real before trusting any of this beyond "the
grammar is valid VHDL-2008." `uv202_clkgen`/`uv202_timing`/`f8_busif`'s
PC0/PC1/DC0 arithmetic threw stub-mismatch errors this session (almost
certainly because the stub guessed `uv16` as `std_logic_vector` instead of
`unsigned`) - re-check those specifically once the real packages are in.

Designing `sim/tb_f8_busif/` — a unit-level testbench for `f8_busif.vhd`
in isolation:
- **Does NOT instantiate `f8_cpu`.** Drives canned `(romc, phase)`
  sequences directly as stimulus, to test one ROMC state transition at a
  time rather than debugging through a full CPU+microcode stack.
- **`sys_bus.vhd` now exists for real** (this session) - the testbench can
  either instantiate it directly (exercises real RES1/RAM/UV201-reg
  routing, though RES1/RES2 contents are still all-zero, no loader yet) or
  keep the originally-planned mock (`ext_rdata` = address XOR constant) for
  pure `f8_busif` timing isolation. Worth doing both: mock first for
  `f8_busif`'s own phase-alignment questions (gap #2), real `sys_bus`
  second as the first actual integration test of the two together.
- Mock `uv202_arbiter`: parameterizable grant delay (test with 0-cycle
  and with the current arbiter's 5/7-cycle end-to-end delays).
- Self-checks via VHDL assertions: shadow PC0/DC0 tracked independently
  in the testbench and compared against `pc0o`/`dc0o`; `ext_addr`/`dr`/`dv`
  timing checked against expected phase windows.
- Planned test list (7 cases) drafted in prior session: RES1 IFETCH (now
  unblocked - RES1/RES2 are distinct classes), RAM IFETCH, immediate
  operand fetch from cart, DC0-indexed read w/ increment, DC0-indexed
  write, UV201 register read/write, back-to-back access timing with
  varying grant delay. Add an 8th case now that `ACC_RES2` exists: a RES2
  IFETCH, to confirm it actually takes the arbiter's wait path instead of
  silently getting RES1 timing.
- Tooling: GHDL + GTKWave, no UVM-style framework — hand-rolled
  self-checking VHDL testbench, one per risky module (matches the
  per-chip file-splitting philosophy used for the RTL itself). GHDL is
  confirmed installed/working in this session's sandbox (`ghdl-mcode
  4.1.0`), so the tooling assumption is now verified, not just assumed.
- A second, integration-level testbench (`f8_cpu` + a hand-assembled
  mock-ROM F8 program + `f8_busif` + `sys_bus`) is planned as a follow-on
  after the unit-level one passes, not before.

Nothing has been written into `sim/` yet — this is the state to resume
from.
