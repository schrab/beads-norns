# beads

[Mutable Instruments Beads](https://pichenettes.github.io/mutable-instruments-documentation/modules/beads/)
for [norns](https://monome.org/docs/norns/) — the module's actual DSP, wrapped
as a SuperCollider UGen.

Not an approximation: `ugens/beads_ugen.cpp` wraps `beads::Processor` from
[pichenettes/eurorack](https://github.com/pichenettes/eurorack) (granular
cloud with 32 grains, the SIZE > 0.99 multitap delay/tape mode, freeze,
reverb, the four media character modes), the same wrapping technique as
v7b1's [mi-UGens](https://github.com/v7b1/mi-UGens) used by
[mi-eng](https://github.com/okyeron/mi-eng). The vendored DSP under
`ugens/eurorack-beads/` is byte-identical to upstream (verified file-by-file
against eurorack `f4cfa76` / stmlib `e3bd7c9`); all adaptation to norns lives
in the wrapper.

## Layout

```
beads.lua               norns script (6 pages, no alt layers)
lib/Engine_Beads.sc     CroneEngine wrapper (commands + polls)
lib/beads_engine.lua    param registration
ugens/beads_ugen.cpp    SC UGen: rate adapters + GainControl + beads::Processor
ugens/eurorack-beads/   vendored beads dsp + stmlib subset (MIT, pristine)
ugens/sc-plugin-headers/ vendored SC plugin headers (3.13.0)
deploy.sh               sync to the device, build + install the plugin
```

## Install (on the norns itself — native build, needs g++ + make)

```sh
# copy this folder to ~/dust/code/beads on the norns, then:
cd ~/dust/code/beads/ugens
make && make install
sudo systemctl restart norns-jack norns-sclang norns-main
```

Select `beads` from SELECT. The UGen assumes scsynth at 48 kHz (norns default).

Note: sclang compiles every `.sc` under `~/dust`, so `ugens/BeadsUGen.sc` must
NOT be copied there — `make install` puts it in
`~/.local/share/SuperCollider/Extensions/BeadsUGens/` where it belongs
(the Makefile tolerates it being absent from the build tree).

## Deploy (from the dev machine)

`./deploy.sh [host]` (default host `fates`) tars the tree to
`~/dust/code/beads`, rebuilds `BeadsUGen.so` on-device, and installs it (the
`.so` into `/usr/local/lib/SuperCollider/plugins/` via sudo, the class file
into `~/.local/share/SuperCollider/Extensions/BeadsUGens/`). Then restart the
three units explicitly — `systemctl restart norns-jack norns-sclang
norns-main` (restarting `norns.target` alone does NOT restart bound
services). Set `clean_shutdown = true` in `~/dust/data/system.state` before
restarting if the script should resume at boot. Lua-only changes still need
the restart (or re-selecting the script), but no rebuild.

## Controls

| input | action |
|---|---|
| E1 | page |
| E2 / E3 / E4 | the page's three parameters (E4 = Fates 4th knob) |
| K2 | freeze (toggle) |
| K3 | seed (momentary; in the density deadband = manual grain / tap tempo) |

K1 is left untouched — it is the norns system menu key.

**PLAY page is a live view of the granulator** (the record head stays
fixed — tape frame): every grain is drawn as a sub-arc of the loop at its
true read position, and they move. Positions and motion follow the DSP's
per-grain laws: each spawn re-rolls time/size/pitch/shape through the same
per-trigger randomization as the module's attenurandomizers, the read
point drifts through the loop at `(playback_ratio − 1)` loop-fractions per
second (pitch 0 = fixed reading point, pitch up slides toward older tape),
arc length maps the grain's own duration (log-mapped 8 ms–4 s), brightness
follows the grain's envelope (shape), dim = reverse, and grains die at the
end of their life. The exact expected concurrent count (rate × duration,
e.g. "16 grains") is printed inside the loop. Two 6-spoke reels sit in the
end caps and rotate with the tape — rim speed equals tape surface speed,
so they turn once per loop at the reel's radius. Grains only appear when
the gate is open (latch on, or K3 held), the density deadband taps spawn a
grain per press, and media changes clear the view (the buffer resets). In
delay mode (SIZE max) the display shows the static read position with
regen echoes.

Pages: **PLAY** (time, pitch, pitch amount — tape-loop view), **GRAIN**
(density, size, shape — grain envelope preview), **RANDOM** (the
attenurandomizers: time/size/shape amounts, bipolar bars), **MIX**
(feedback, reverb, dry/wet), **CLOCK** (sync to norns BPM, subdivision,
seed latch), **SETUP** (media, channels, input gain), **MIDI** (note
pitch, reference note, bend range).

Every control steps exactly one display increment per encoder detent
(pitch 0.1 st, input gain 1 setting, amounts 0.02, the 0–1 params 0.005).

**MIDI note pitch** (MIDI page) stands in for the hardware PITCH CV jack:
with it on, notes transpose the granulator by `note − reference` semitones
(last-note priority; the last note holds on release, like a CV keyboard
holding its voltage; pitch bend adds its range on top). PLAY's **pitch
amount** is the CV depth — exactly the module's PITCH AMOUNT attenuverter:
0 = CV ignored, positive = depth, negative = CV-driven randomization
(enabling note pitch auto-raises a zero amount to 1). Any MIDI device
assigned in SYSTEM > DEVICES > MIDI is picked up; the header shows NOTE
while a note is held.

The AMOUNT knobs mirror the module's attenurandomizers and pass through the
hardware attenuverter law (center dead zone, expanding curve): positive
sprays the parameter toward random per grain (pitch: ±24 st), negative peaks
values near the knob, zero (±0.06) = off. Pitch amount sits on PLAY next to
pitch.

**Clock sync** (CLOCK page, needs the seed latch on, like the hardware's
clocked SEED jack): the script sends one seed pulse per norns-system beat.
Delay mode (SIZE to max) locks its tempo to bpm × subdivision
(1/16…1…×16 — the subdivision walks the same DSP ratio table the density
knob uses when clocked, so GRAIN's density and CLOCK's subdiv stay
consistent). Granular mode becomes a clocked divider/probability.

All controls are norns params → psets, MIDI mapping (PARAMS > EDIT), and the
`beads_*` engine commands are available to other scripts.

## Fidelity notes

- **Sample rates.** On hardware the codec is re-clocked per media and the
  engines run at 24 kHz (scorched tape), 32 kHz (cold digital) and 48 kHz
  (digital; sunny tape self-decimates 2:1 behind 48 kHz frames). norns'
  scsynth runs at a fixed 48 kHz, so scorched/cold are resampled with the
  same stmlib polyphase converters the firmware uses internally (2:1, and
  3:2 as up-2/down-3), clocked in aligned superblocks (64/192 host samples)
  so the integer ratios chain exactly. This costs ~1.5 ms of extra latency
  on those two media only; loop lengths match the hardware exactly
  (16 / 10.7 / 8 / 4 s).
- **Input stage.** The hardware's `GainControl` stage is ported: input
  gain 0 = auto-gain (the GAIN knob fully CCW), 1–255 = the hardware
  manual law (s/255)⁴ over 1–40×, with the per-media soft clipping
  (scorched tape always soft-clips, sunny tape dynamically). Turning the
  gain up drives the tape engines exactly like overdriving the module's
  inputs.
- **Seed latch defaults ON** at script start (the module boots unlatched;
  unlatched + density in the deadband is silent, which reads as "broken"
  on norns). Everything else about latch/clock semantics follows the
  firmware: LOCKED + external clock = clocked divider / synced delay
  tempo; with nothing patched the firmware passes a NULL seed input and
  the button state alone drives gating and tap tempo.
- **Parameter granularity.** All controlspecs pass an explicit `quantum`
  (see Dev notes) so encoder detents match the display, and the AMOUNT
  params apply the hardware attenuverter curve.

## Differences from the hardware module

- No CV jacks; MIDI notes (MIDI page) are the PITCH CV equivalent and the
  AMOUNT knobs work without CV (internal randomization, like an unpatched
  module).
- Pitch is a continuous ±24 st param (the panel's virtual detents aren't
  emulated).
- The wavetable "no input" synth mode, flash buffer autosave, output-gate
  mode and assignable-CV routing are not ported.
- MEDIA / channel changes are ignored while frozen (the firmware instead
  saves/restores the buffer around the codec restart; the net audible
  result — buffer preserved across a frozen media change — matches).

## Dev notes (traps hit while building this)

- **controlspec args 4 and 7 are different things.** 4th = `step` (snap
  grid of stored values), 7th = `quantum` = per-detent increment in
  NORMALIZED 0..1 units — `Control:delta` adds `d * quantum` to the raw
  0..1 value (`params/control.lua`). Unset, quantum defaults to 0.01: on a
  ±24 range that is 0.48 st per detent, and values like +2.0 become
  unreachable. Rule: `quantum = step / (max - min)`.
- **Param-id collisions with mods CLOBBER silently** (last add wins): a
  mod hook adds its own `reverb` param after script init, so the reverb
  control id here is `rvb`. If you ever rename an id, rename EVERY
  consumer — the encoder maps in `beads.lua` included.
- **UGen registration name**: `DefineDtorUnit(X)` registers under the
  STRUCT name; it must equal the sclang class name (`BeadsUGen.ar`), or
  every synthdef is rejected server-side ("UGen not installed") while the
  engine still "loads".
- **Plugin install locations (norns scsynth 3.13)**: `.so` →
  `/usr/local/lib/SuperCollider/plugins/` (the dir scsynth scans;
  Extensions-dir `.so`s are NOT loaded). Class `.sc` →
  `~/.local/share/SuperCollider/Extensions/BeadsUGens/`. Never a `.sc`
  under `~/dust` (duplicate class compile → SUPERCOLLIDER FAIL).
- **Build needs `-DTEST`** (stmlib portable impls of `Clip16`/`Sqrt`,
  section attributes) plus `stmlib/utils/random.cc` and
  `stmlib/dsp/units.cc` linked — without them the `.so` resolves symbols
  only via dlopen interposition from mi-UGens `.so`s (a lottery).
  Verify: `nm BeadsUGen.so --undefined-only` → empty.
- **Qualify `beads::FloatFrame`** in the UGen C++ — unqualified, an SC
  header typedef shadows it and the build fails (or worse).
- **Seed input must be NULL when unsynced**: `TriggerGenerator::Render`
  treats non-NULL seed input + LOCKED as an EXTERNAL CLOCK (density
  becomes division/probability). The firmware with an unpatched SEED jack
  passes NULL; the button state alone carries gating/tap tempo.
- The SRC adapters run the scorched/cold engines in aligned superblocks
  via per-channel sample rings (`BeadsUGen_Superblock` in
  `beads_ugen.cpp`); clock pulses are queued as absolute host-sample
  indices and mapped to engine frames. If you touch block sizes, keep
  `kRingSize ≥ max superblock + block` and the superblocks exact
  multiples of the rate ratio.
- **Script resume needs `clean_shutdown = true`** in
  `~/dust/data/system.state` — a `systemctl restart` is never "clean",
  so set it before restarting or the box boots to NO SCRIPT.
- On this Fates box, check `vcgencmd get_throttled` FIRST on any
  weirdness (bits 0/2 = PSU under-voltage, bit 3 = thermal → scsynth
  clean-exits → engine loads hang forever).

## Credits & licenses

- Beads DSP + stmlib: © Emilie Gillet, MIT license. Vendored at eurorack
  `f4cfa76` (stmlib submodule pin `e3bd7c9`) under `ugens/eurorack-beads/`.
- UGen wrapper follows v7b1/mi-UGens (© Volker Böhm, GPL-3).
- Everything else in this repo: GPL-3.
