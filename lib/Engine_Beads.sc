// Engine_Beads - norns CroneEngine wrapper around BeadsUGen.
//
// DSP: Mutable Instruments Beads (Emilie Gillet, MIT license).
// Wrapper: GPL-3, part of the beads-norns port.
//
// Commands (all floats):
//   time time_amt size size_amt shape shape_amt pitch pitch_amt density
//   feedback drywet reverb gain freeze seed latch media mono sync
//   pitch_cv (active, semitones)
//   clock (no args - one beat pulse, counter pattern)
// Polls:
//   beads_reserve  - 0..1, fraction of buffer before oldest audio is lost
//   beads_write    - 0..1, write-head position in the recorded region
//   beads_dmode    - 0|1, delay (tape) mode engaged (SIZE at max)

Engine_Beads : CroneEngine {

	var synth;
	var reserveBus, writeBus, dmodeBus;
	var clockCount = 0;
	var <reserve, <writePos, <delayMode;

	alloc {
		var def, sr;

		// single-channel buses: getSynchronous returns a Float per bus and
		// they must exist before the SynthDef closure reads .index at
		// build time
		reserveBus = Bus.control(context.server, 1);
		writeBus = Bus.control(context.server, 1);
		dmodeBus = Bus.control(context.server, 1);

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
				sync: \sync.kr(0),
				clockCount: \clockCount.kr(0),
				inL: inL,
				inR: inR
			);
			Out.ar(context.out_b.index, sig[0..1]);
			// status lane: reserve / write position / delay mode
			Out.kr(reserveBus.index, A2K.kr(sig[2]));
			Out.kr(writeBus.index, A2K.kr(sig[3]));
			Out.kr(dmodeBus.index, A2K.kr(sig[4]));
		});

		def.add;
		context.server.sync;

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
		this.addCommand("sync", "f", { arg msg; synth.set(\sync, msg[1]) });
		// MIDI note pitch, the hardware PITCH-CV jack equivalent:
		// msg[1] = active (jack patched), msg[2] = cv in semitones
		this.addCommand("pitch_cv", "ff", { arg msg;
			synth.set(\pitchCvOn, msg[1]);
			synth.set(\pitchCv, msg[2]);
		});
		// one beat pulse from the script's clock loop (counter pattern)
		this.addCommand("clock", "", {
			clockCount = clockCount + 1;
			synth.set(\clockCount, clockCount);
		});

		// getSynchronous can return nil while the server is busy; guard it
		this.addPoll("beads_reserve", {
			var v = reserveBus.getSynchronous;
			if(v.notNil) { v } { 0 };
		});
		this.addPoll("beads_write", {
			var v = writeBus.getSynchronous;
			if(v.notNil) { v } { 0 };
		});
		this.addPoll("beads_dmode", {
			var v = dmodeBus.getSynchronous;
			if(v.notNil) { v } { 0 };
		});
	}

	free {
		synth.free;
		reserveBus.free;
		writeBus.free;
		dmodeBus.free;
	}

}
