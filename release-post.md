# beads

Mutable Instruments' [Beads](https://pichenettes.github.io/mutable-instruments-documentation/modules/beads/) — the actual DSP, running on [norns](https://monome.org/docs/norns/).

| | |
|---|---|
| ![](https://raw.githubusercontent.com/schrab/beads-norns/main/screenshots/play.png) | ![](https://raw.githubusercontent.com/schrab/beads-norns/main/screenshots/grain.png) |
| ![](https://raw.githubusercontent.com/schrab/beads-norns/main/screenshots/clock.png) | ![](https://raw.githubusercontent.com/schrab/beads-norns/main/screenshots/synth.png) |

This is not an approximation or a re-implementation: the module's firmware
DSP (`beads::Processor` from [pichenettes/eurorack](https://github.com/pichenettes/eurorack))
is vendored into a SuperCollider UGen and does all of the sound — the
32-grain granular cloud, the SIZE>max multitap delay / tape mode, freeze,
reverb, and the four media characters — byte-identical to the hardware
(the same approach as v7b1's [mi-UGens](https://github.com/v7b1/mi-UGens)).
Record into the loop from the inputs, hold freeze to build a loop, and let
the granulator shred it — or seed it from the built-in wavetable synth when
nothing is patched in.

**Some of the details carried over from the module:**

- The four media characters (scorched tape / sunny tape / cold digital /
  digital) run at their true engine rates (24 / 32 / 48 kHz) with the same
  polyphase converters the firmware uses internally, so the loop lengths,
  bandwidth and wobble match the hardware (16 / 10.7 / 8 / 4 s).
- The hardware input stage is ported: auto-gain, the (s/255)⁴ manual gain
  law and per-media soft clipping — driving the inputs saturates the tape
  engines like overdriving the module.
- The four AMOUNT knobs are the module's attenurandomizers, dead zone and
  attenuverter curve included: positive sprays time/size/shape/pitch per
  grain, negative peaks values near the knob.
- Clock sync (CLOCK page) seeds one pulse per norns beat — delay mode locks
  its tempo to bpm × subdivision and GRAIN's density reads as the module's
  ratio ring (1/16 … 1/1, then 1/2, 1/3, 1/4, 1/6, 1/8, 1/10, 1/12, 1/16).
- MIDI note pitch is the PITCH CV jack equivalent: notes transpose the
  granulator, last note holds like a held CV, bend and the pitch-amount
  attenuverter behave as on hardware.
- The no-input wavetable synth mode (Plaits' raw banks through the same
  granular engine) is included as a manual switch, with FEEDBACK doubling
  as the 12-bank wavetable selector and an optional gate output.
- A TAPE-page file player feeds any audio file straight into the
  granulator's input — norns' own TAPE menu plays to the output mix only,
  so this is how a recording gets processed like a tape deck plugged into
  the module.
- The PLAY page is a live view of the granulator: every grain drawn at its
  true position and size against the tape loop, moving, with the splice
  dot and reels phase-locked to the buffer.

## Requirements

- norns or norns shield (developed and tested on a shield-class RPi)
- `build-essential` (g++ + make) on the norns for a one-time plugin build
- optional: a MIDI keyboard for the pitch-CV input

## Install

The SuperCollider plugin needs a one-time on-device build, so this is not
a `;install` one-liner. From an SSH session on the norns:

```sh
git clone https://github.com/schrab/beads-norns ~/dust/code/beads
cd ~/dust/code/beads/ugens
make && make install
sudo systemctl restart norns-jack norns-sclang norns-main
```

Do not forget to restart — the engine is only registered after the
restart. Then select `beads` from SELECT. Upgrades are `git pull` +
`make && make install` in `ugens/` + restart; full instructions (and
removal) are in the [README](https://github.com/schrab/beads-norns).

## Documentation

**Encoders:**

| | |
|---|---|
| `E1` | page |
| `E2` / `E3` / `E4` | the page's three parameters |

**Keys:**

| | |
|---|---|
| `K2` | freeze (toggle) |
| `K3` | seed (momentary) |

Pages: **PLAY** (time, pitch, pitch amount — live grain view), **GRAIN**
(density, size, shape), **RANDOM** (the attenurandomizers), **MIX**
(feedback, reverb, dry/wet), **CLOCK** (sync, subdivision, seed latch),
**SETUP** (media, channels, input gain), **TAPE** (file player: K3 opens
the browser, E4 play/stop, level, once/loop), **MIDI** (note pitch,
reference note, bend range), **SYNTH** (synth mode, bank, gate output).

**Start here:** hold `K3` (or leave the seed latch on — it defaults on)
to open the grain gate, feed something into the inputs, and turn GRAIN's
`E2` (density). Push SIZE (`E3`) toward maximum to slide into the tape /
delay mode, and set TIME to 0 on the PLAY page with freeze (`K2`) to build
a loop. Every control steps exactly one display increment per detent.

Freeze (`K2`) holds the buffer — new grains keep spawning from frozen
material, exactly like the module. Seed (`K3`) in the density deadband is
the manual grain trigger / tap tempo. Everything is exposed as norns
params (psets, MIDI-mappable), and the `beads_*` engine commands are
available to other scripts.

**Differences from the hardware module** (honesty section): no CV jacks —
MIDI notes stand in for PITCH CV and the AMOUNT knobs work without CV; the
wavetable synth mode is a manual switch (the hardware auto-activates it by
sensing unpatched inputs); flash buffer autosave is not ported. Everything
else aims for fidelity — see the README's fidelity notes.

## LLM disclosure

This port was built with substantial LLM assistance (Claude): the fidelity
audit against the vendored firmware sources, the UGen wrapper, and the UI
were drafted by the model, then verified against the actual module code and
the hardware manual, and everything was tested by ear on the device.

## Changelog

<details>
<summary>Versions | last update: 27 Oct 2026</summary>

<p><code>1.1.0</code></p>
<ul>
<li>TAPE page: file player feeding the granulator input (pick a file, it
plays into the engine like a tape deck into the module).</li>
<li>Clock sync now works with the seed latch OFF: every norns beat fires
one seed trigger (the hardware's patched-SEED trigger behavior); latch on
keeps the clocked divider / synced delay tempo.</li>
</ul>
<p><code>1.0.0</code></p>
<ul>
<li>Initial release: full Beads DSP (granular / delay / freeze / reverb),
4 media with per-media rate conversion, hardware input stage and gain law,
attenurandomizers, clock sync, MIDI pitch CV, wavetable synth mode, gate
output, live PLAY visualization.</li>
</ul>
</details>
