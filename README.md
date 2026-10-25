# beads

[Mutable Instruments Beads](https://pichenettes.github.io/mutable-instruments-documentation/modules/beads/)
for [norns](https://monome.org/docs/norns/) — the module's actual DSP, wrapped
as a SuperCollider UGen.

Not an approximation: `ugens/beads_ugen.cpp` wraps `beads::Processor` from
[pichenettes/eurorack](https://github.com/pichenettes/eurorack) (granular
cloud with 32 grains, the SIZE > 0.99 multitap delay/tape mode, freeze,
reverb, the four media character modes), the same wrapping technique as
v7b1's [mi-UGens](https://github.com/v7b1/mi-UGens) used by
[mi-eng](https://github.com/okyeron/mi-eng).

## Layout

```
beads.lua               norns script (4 pages, awake/dunes-style UI)
lib/Engine_Beads.sc     CroneEngine wrapper (commands + polls)
lib/beads_engine.lua    param registration
ugens/beads_ugen.cpp    SC UGen wrapping beads::Processor
ugens/eurorack-beads/   vendored beads dsp + stmlib subset (MIT)
ugens/sc-plugin-headers/ vendored SC plugin headers (3.13.0)
```

## Install (on the norns itself — native build, needs g++ + make)

```sh
# copy this folder to ~/dust/code/beads on the norns, then:
cd ~/dust/code/beads/ugens
make && make install
sudo systemctl restart norns.target
```

Select `beads` from SELECT. The UGen assumes scsynth at 48 kHz (norns default).

Note: sclang compiles every `.sc` under `~/dust`, so `ugens/BeadsUGen.sc` must
NOT be copied there — `make install` puts it in
`~/.local/share/SuperCollider/Extensions/BeadsUGens/` where it belongs
(the Makefile tolerates it being absent from the build tree).

## Controls

| input | action |
|---|---|
| E1 | page |
| E2 / E3 / E4 | the page's three parameters (E4 = Fates 4th knob) |
| K2 | freeze (toggle) |
| K3 | seed (momentary; in the density deadband = manual grain / tap tempo) |

K1 is left untouched — it is the norns system menu key.

Pages: **PLAY** (time, pitch, pitch amount — tape-loop view), **GRAIN**
(density, size, shape — grain envelope preview), **RANDOM** (the
attenurandomizers: time/size/shape amounts, bipolar bars), **MIX**
(feedback, reverb, dry/wet), **CLOCK** (sync to norns BPM, subdivision,
seed latch), **SETUP** (media, channels, input gain).

The AMOUNT knobs mirror the module's attenurandomizers: positive sprays the
parameter toward random per grain (pitch: ±24 st), negative peaks values
near the knob, zero = off. Pitch amount sits on PLAY next to pitch.

**Clock sync** (CLOCK page, needs the seed latch on, like the hardware's
clocked SEED jack): the script sends one seed pulse per norns-system beat.
Delay mode (SIZE to max) locks its tempo to bpm × subdivision
(1/16…1…×16 — the subdivision walks the same DSP ratio table the density
knob uses when clocked, so GRAIN's density and CLOCK's subdiv stay
consistent). Granular mode becomes a clocked divider/probability.

All controls are norns params → psets, MIDI mapping (PARAMS > EDIT), and the
`beads_*` engine commands are available to other scripts.

## Differences from the hardware module

- No CV inputs; the AMOUNT knobs work without CV (internal randomization,
  like an unpatched module). The AMOUNT knobs pass through the hardware's
  attenuverter law (center dead zone, expanding curve), so small amounts do
  nothing exactly like on the module.
- Pitch is a continuous ±24 st param (the panel's virtual detents aren't
  emulated).
- The wavetable "no input" synth mode, flash buffer autosave, output-gate
  mode and assignable-CV routing are not ported.
- MEDIA / channel changes are ignored while frozen (same as firmware).

## Fidelity notes

- **Sample rates.** On hardware the codec is re-clocked per media and the
  engines run at 24 kHz (scorched tape), 32 kHz (cold digital) and 48 kHz
  (digital; sunny tape self-decimates 2:1 behind 48 kHz frames). norns'
  scsynth runs at a fixed 48 kHz, so scorched/cold are resampled with the
  same stmlib polyphase converters the firmware uses internally (2:1, and
  3:2 as up-2/down-3), clocked in aligned superblocks. This costs ~1.5 ms
  of extra latency on those two media only; loop lengths now match the
  hardware exactly (16 / 10.7 / 8 / 4 s).
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
  tempo.

## Credits & licenses

- Beads DSP + stmlib: © Emilie Gillet, MIT license. Vendored at eurorack
  `f4cfa76` (stmlib submodule pin `e3bd7c9`) under `ugens/eurorack-beads/`.
- UGen wrapper follows v7b1/mi-UGens (© Volker Böhm, GPL-3).
- Everything else in this repo: GPL-3.
