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
| E2 / E3 | the two values of the page (labels on screen) |
| K1 hold | amount layer — the AMOUNT knobs of the module |
| K2 | freeze (toggle) |
| K3 | seed (momentary; in the density deadband = manual grain / tap tempo) |
| K1 + K3 | seed latch (locked = free-running grains) |

Pages: **PLAY** (time, pitch — tape view with write head + grain position),
**GRAIN** (density, size — grain envelope preview), **MIX** (feedback, dry/wet,
reverb), **SETUP** (media, input gain, channels).

All controls are norns params → psets, MIDI mapping (PARAMS > EDIT), and the
`beads_*` engine commands are available to other scripts.

## Differences from the hardware module

- No CV inputs; the AMOUNT knobs work without CV (internal randomization,
  like an unpatched module).
- Pitch is a continuous ±24 st param (the panel's virtual detents aren't
  emulated).
- The wavetable "no input" synth mode, flash buffer autosave, output-gate
  mode and assignable-CV routing are not ported.
- MEDIA / channel changes are ignored while frozen (same as firmware).

## Credits & licenses

- Beads DSP + stmlib: © Emilie Gillet, MIT license. Vendored at eurorack
  `f4cfa76` / stmlib `d18def8` under `ugens/eurorack-beads/`.
- UGen wrapper follows v7b1/mi-UGens (© Volker Böhm, GPL-3).
- Everything else in this repo: GPL-3.
