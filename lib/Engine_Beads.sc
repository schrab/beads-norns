// Engine_Beads - norns CroneEngine wrapper around BeadsUGen.
//
// DSP: Mutable Instruments Beads (Emilie Gillet, MIT license).
// Wrapper: GPL-3, part of the beads-norns port.
//
// Commands (all floats):
//   time time_amt size size_amt shape shape_amt pitch pitch_amt density
//   feedback drywet reverb gain freeze seed latch media mono sync
//   pitch_cv (active, semitones) synth gate
//   clock (no args - one beat pulse, counter pattern)
//   buffer_load (path) buffer_play (0/1) buffer_loop (0/1) buffer_level (0..2)
// Polls:
//   beads_reserve  - 0..1, fraction of buffer before oldest audio is lost
//   beads_write    - 0..1, write-head position in the recorded region
//   beads_dmode    - 0|1, delay (tape) mode engaged (SIZE at max)
//   beads_bufplay  - 0|1, tape-file player state

Engine_Beads : CroneEngine {

	var synth;
	var reserveBus, writeBus, dmodeBus;
	var clockCount = 0;
	var <reserve, <writePos, <delayMode;
	// tape-file player: plays a loaded file into the engine's input buses
	// (summed with the hardware line-in), so a norns TAPE recording can be
	// fed to the granulator like a tape deck into the module's input
	var bufSynth, buf, bufPlaying = false, bufLevel = 1.0, bufLoop = 1;
	var bufEndRoutine;

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

		// the player writes into context.in_b - the same private buses the
		// \adc routers fill with the hardware line-in - so sources SUM. It
		// must sit BEFORE the engine synth in node order (addToHead) or the
		// engine would read the bus before this block's contribution.
		SynthDef("beads_bufplay2", { arg buf = 0, level = 1.0, loop = 1;
			var play = PlayBuf.ar(2, buf, BufRateScale.kr(buf), loop: loop);
			Out.ar(context.in_b[0].index, play[0] * level);
			Out.ar(context.in_b[1].index, play[1] * level);
		}).add;
		SynthDef("beads_bufplay1", { arg buf = 0, level = 1.0, loop = 1;
			var play = PlayBuf.ar(1, buf, BufRateScale.kr(buf), loop: loop);
			Out.ar(context.in_b[0].index, play * level);
			Out.ar(context.in_b[1].index, play * level);
		}).add;
		context.server.sync;

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
		// wavetable synth mode (manual switch - the hardware's no-input
		// state) and the output-gate mode (mono sum + trigger on right)
		this.addCommand("synth", "f", { arg msg; synth.set(\synth, msg[1]) });
		this.addCommand("gate", "f", { arg msg; synth.set(\gate, msg[1]) });
		// one beat pulse from the script's clock loop (counter pattern)
		this.addCommand("clock", "", {
			clockCount = clockCount + 1;
			synth.set(\clockCount, clockCount);
		});

		// ---- tape-file player ----
		this.addCommand("buffer_load", "s", { arg msg;
			var path = msg[1].asString;
			this.stopBufferPlay;
			Buffer.read(context.server, path, action: { arg newBuf;
				var old;
				if(buf.notNil) { old = buf };
				buf = newBuf;
				if(old.notNil) { old.free };
			});
		});
		this.addCommand("buffer_play", "f", { arg msg;
			if(msg[1] > 0.5) { this.startBufferPlay } { this.stopBufferPlay };
		});
		// loop mode is an init arg of PlayBuf - restart the player on change
		this.addCommand("buffer_loop", "f", { arg msg;
			if(msg[1] > 0.5) { bufLoop = 1 } { bufLoop = 0 };
			if(bufPlaying) { this.startBufferPlay };
		});
		this.addCommand("buffer_level", "f", { arg msg;
			bufLevel = msg[1];
			if(bufPlaying && bufSynth.notNil) { bufSynth.set(\level, bufLevel) };
		});
		this.addPoll("beads_bufplay", { if(bufPlaying) { 1 } { 0 } });

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

	startBufferPlay {
		if(buf.isNil) { ^this };
		this.stopBufferPlay;
		// loop is an init arg: 1 = loop, 0 = stop at end of file
		bufSynth = Synth(
			if(buf.numChannels > 1, "beads_bufplay2", "beads_bufplay1"),
			[\buf, buf.bufnum, \level, bufLevel, \loop, bufLoop],
			context.xg, \addToHead);
		bufPlaying = true;
		if(bufLoop < 0.5) {
			// 'once': schedule the stop at the file's real playback length
			// (its own rate scaled to the server rate by BufRateScale)
			var dur = buf.duration * (buf.sampleRate / context.server.sampleRate);
			bufEndRoutine = Routine {
				dur.wait;
				if(bufPlaying) { this.stopBufferPlay };
			};
			SystemClock.play(bufEndRoutine);
		};
	}

	stopBufferPlay {
		if(bufEndRoutine.notNil) {
			bufEndRoutine.stop;
			bufEndRoutine = nil;
		};
		if(bufSynth.notNil) {
			bufSynth.free;
			bufSynth = nil;
		};
		bufPlaying = false;
	}

	free {
		this.stopBufferPlay;
		if(buf.notNil) { buf.free; buf = nil };
		synth.free;
		reserveBus.free;
		writeBus.free;
		dmodeBus.free;
	}

}
