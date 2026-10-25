// BeadsUGen sclang interface.
// DSP: Mutable Instruments Beads (Emilie Gillet, MIT).
// Wrapper: GPL-3, part of the beads-norns port.

BeadsUGen : MultiOutUGen {

	// outputs: [0]=outL [1]=outR [2]=overwrite reserve [3]=write pos phase
	//          [4]=delay-mode flag (1 when SIZE > 0.99 engaged the tape mode)

	*ar { arg inL=0.0, inR=0.0, time=0.5, timeAmt=0.0, size=0.3, sizeAmt=0.0,
		shape=0.5, shapeAmt=0.0, pitch=0.0, pitchAmt=0.0, density=0.3,
		feedback=0.0, drywet=1.0, reverb=0.0, gain=1.0, freeze=0, seed=0,
		latch=0, media=3, mono=0, sync=0, clockCount=0, pitchCvOn=0, pitchCv=0.0,
		synth=0, gate=0;
		^this.multiNewList(['audio',
			time, timeAmt, size, sizeAmt, shape, shapeAmt,
			pitch, pitchAmt, density, feedback, drywet, reverb,
			gain, freeze, seed, latch, media, mono, sync, clockCount,
			pitchCvOn, pitchCv,
			synth, gate,
			inL, inR])
	}

	checkInputs {
		if (inputs.at(24).rate != 'audio', {
			^("BeadsUGen: input L is not audio rate:" + inputs.at(24).rate)
		});
		if (inputs.at(25).rate != 'audio', {
			^("BeadsUGen: input R is not audio rate:" + inputs.at(25).rate)
		});
		^this.checkValidInputs;
	}

	init { arg ... args;
		inputs = args;
		^this.initOutputs(5, rate);
	}

}
