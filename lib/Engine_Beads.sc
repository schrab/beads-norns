// Engine_Beads - norns CroneEngine wrapper around BeadsUGen.
//
// DSP: Mutable Instruments Beads (Emilie Gillet, MIT license).
// Wrapper: GPL-3, part of the beads-norns port.
//
// Commands (all floats):
//   time time_amt size size_amt shape shape_amt pitch pitch_amt density
//   feedback drywet reverb gain freeze seed latch media mono
// Polls:
//   beads_reserve  - 0..1, fraction of buffer before oldest audio is lost
//   beads_write    - 0..1, write-head position in the recorded region
//   beads_dmode    - 0|1, delay (tape) mode engaged (SIZE at max)

Engine_Beads : CroneEngine {

	var synth;
	var statusBus;
	var <reserve, <writePos, <delayMode;

	alloc {
		var def, sr;

		def = SynthDef("beads_engine", {
			var inL = In.ar(context.in_b[0].index, 1);
			var inR = In.ar(context.in_b[1].index, 1);
			var sig = BeadsUGen.ar(
				time: \time.kr(0.5),
				timeAmt: \timeAmt.kr(0),
				size: \size.kr(0.3),
				sizeAmt: \sizeAmt.kr(0),
				shape: \shape.kr(0.5),
				shapeAmt: \shapeAmt.kr(0),
				pitch: \pitch.kr(0),
				pitchAmt: \pitchAmt.kr(0),
				density: \density.kr(0.3),
				feedback: \feedback.kr(0),
				drywet: \drywet.kr(1),
				reverb: \reverb.kr(0),
				gain: \gain.kr(1),
				freeze: \freeze.kr(0),
				seed: \seed.kr(0),
				latch: \latch.kr(0),
				media: \media.kr(3),
				mono: \mono.kr(0),
				inL: inL,
				inR: inR
			);
			Out.ar(context.out_b.index, sig[0..1]);
			// status lane: reserve / write position / delay mode
			Out.kr(statusBus.index + [0, 1, 2], A2K.kr(sig[2..4]));
		});

		def.add;
		context.server.sync;

		statusBus = Bus.control(context.server, 3);

		synth = Synth.new("beads_engine", [], context.xg);

		this.addCommand("time", "f", { arg msg; synth.set(\time, msg[1]) });
		this.addCommand("time_amt", "f", { arg msg; synth.set(\timeAmt, msg[1]) });
		this.addCommand("size", "f", { arg msg; synth.set(\size, msg[1]) });
		this.addCommand("size_amt", "f", { arg msg; synth.set(\sizeAmt, msg[1]) });
		this.addCommand("shape", "f", { arg msg; synth.set(\shape, msg[1]) });
		this.addCommand("shape_amt", "f", { arg msg; synth.set(\shapeAmt, msg[1]) });
		this.addCommand("pitch", "f", { arg msg; synth.set(\pitch, msg[1]) });
		this.addCommand("pitch_amt", "f", { arg msg; synth.set(\pitchAmt, msg[1]) });
		this.addCommand("density", "f", { arg msg; synth.set(\density, msg[1]) });
		this.addCommand("feedback", "f", { arg msg; synth.set(\feedback, msg[1]) });
		this.addCommand("drywet", "f", { arg msg; synth.set(\drywet, msg[1]) });
		this.addCommand("reverb", "f", { arg msg; synth.set(\reverb, msg[1]) });
		this.addCommand("gain", "f", { arg msg; synth.set(\gain, msg[1]) });
		this.addCommand("freeze", "f", { arg msg; synth.set(\freeze, msg[1]) });
		this.addCommand("seed", "f", { arg msg; synth.set(\seed, msg[1]) });
		this.addCommand("latch", "f", { arg msg; synth.set(\latch, msg[1]) });
		this.addCommand("media", "f", { arg msg; synth.set(\media, msg[1]) });
		this.addCommand("mono", "f", { arg msg; synth.set(\mono, msg[1]) });

		this.addPoll("beads_reserve", { statusBus.getSynchronous[0] });
		this.addPoll("beads_write", { statusBus.getSynchronous[1] });
		this.addPoll("beads_dmode", { statusBus.getSynchronous[2] });
	}

	free {
		synth.free;
		statusBus.free;
	}

}
