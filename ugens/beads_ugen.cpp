/*
  BeadsUGen - SuperCollider UGen wrapping the DSP of the Mutable Instruments
  'Beads' eurorack module (granular delay/looper).

  Original Beads code by Emilie Gillet (c) 2017, MIT license
  https://github.com/pichenettes/eurorack

  UGen wrapper by schrab for the norns port, following the pattern of
  v7b1's mi-UGens (GPL-3). This file is GPL-3.

  Signal path (all inside beads::Processor):
    input -> [delay line write (feedback limited)] -> granular player
    (32 grains) OR 8-tap multitap delay (SIZE > 0.99) -> dry/wet -> wow &
    flutter (tape media) -> reverb -> limiter -> output

  Rates: beads runs its media engines at fixed internal rates derived from a
  48 kHz codec. norns always runs scsynth at 48 kHz - do not use at other
  host rates.
*/

#include "SC_PlugIn.h"

#include "beads/dsp/processor.h"
#include "beads/resources.h"

static InterfaceTable *ft;

// control-rate args (indices 0..kNumKrArgs-1); audio inputs follow at
// kNumKrArgs (L) and kNumKrArgs+1 (R)
static const int kNumKrArgs = 18;
static const int kMaxChunk = 128;

// buffer duration in stereo-line items per media (bytes / item bytes);
// the mono line doubles the item count at half the item size
static const int kLineMaxDelay[4] = { 384000, 256000, 256000, 192000 };

enum PotParams {
  POT_TIME,
  POT_TIME_AMT,
  POT_SIZE,
  POT_SIZE_AMT,
  POT_SHAPE,
  POT_SHAPE_AMT,
  POT_PITCH,
  POT_PITCH_AMT,
  POT_DENSITY,
  POT_FEEDBACK,
  POT_DRYWET,
  POT_REVERB,
  POT_GAIN,
  POT_LAST
};

struct BeadsUGen : public Unit {

  beads::Processor *processor;

  // 3 banks x 256 KB, shared by all four media engines (beads.cc layout)
  uint8_t   *delay_buffer;
  uint8_t   *buffer_banks[3];
  uint16_t  *reverb_buffer;

  // smoothed block-rate parameters
  float     cur_[POT_LAST];

  // switch state
  bool      freeze_;
  bool      seed_held_;
  bool      latch_;
  bool      mono_;
  int       media_;
  int       transition_;          // 250 ms mute after media/mono change
  stmlib::GateFlags previous_seed_flag_;

  // mirror of the granular<->delay hysteresis, for the UI only
  float     delay_mode_transition_;
  bool      delay_mode_;

  // per-chunk scratch
  beads::FloatFrame in_[kMaxChunk];
  beads::FloatFrame out_[kMaxChunk];
  bool       freeze_buf_[kMaxChunk];
  stmlib::GateFlags seed_buf_[kMaxChunk];
};

static void BeadsUGen_Ctor(BeadsUGen *unit);
static void BeadsUGen_Dtor(BeadsUGen *unit);
static void BeadsUGen_next(BeadsUGen *unit, int inNumSamples);

static void BeadsUGen_Ctor(BeadsUGen *unit) {

  if (SAMPLERATE != 48000.f) {
    Print("Beads WARNING: scsynth sample rate is %g Hz; the engines assume 48 kHz\n",
          SAMPLERATE);
  }

  const size_t kDelayBufferSize = 768 * 1000;
  const size_t kReverbBufferSize = 32768;

  unit->delay_buffer = (uint8_t*)RTAlloc(unit->mWorld, kDelayBufferSize);
  unit->reverb_buffer = (uint16_t*)RTAlloc(unit->mWorld,
                                           kReverbBufferSize * sizeof(uint16_t));
  if (unit->delay_buffer == NULL || unit->reverb_buffer == NULL) {
    Print("Beads ERROR: memory allocation failed\n");
    SETCALC(*ClearUnitOutputs);
    return;
  }
  for (int i = 0; i < 3; ++i) {
    unit->buffer_banks[i] = unit->delay_buffer + i * 262144;
  }

  unit->processor = new beads::Processor();
  unit->processor->Init(unit->buffer_banks, unit->reverb_buffer);

  unit->cur_[POT_TIME] = 0.5f;
  unit->cur_[POT_TIME_AMT] = 0.0f;
  unit->cur_[POT_SIZE] = 0.3f;
  unit->cur_[POT_SIZE_AMT] = 0.0f;
  unit->cur_[POT_SHAPE] = 0.5f;
  unit->cur_[POT_SHAPE_AMT] = 0.0f;
  unit->cur_[POT_PITCH] = 0.0f;
  unit->cur_[POT_PITCH_AMT] = 0.0f;
  unit->cur_[POT_DENSITY] = 0.3f;
  unit->cur_[POT_FEEDBACK] = 0.0f;
  unit->cur_[POT_DRYWET] = 1.0f;
  unit->cur_[POT_REVERB] = 0.0f;
  unit->cur_[POT_GAIN] = 1.0f;

  unit->freeze_ = false;
  unit->seed_held_ = false;
  unit->latch_ = false;
  unit->mono_ = false;
  unit->media_ = beads::Processor::MEDIA_DIGITAL;   // Processor::Init configured this
  unit->transition_ = 0;
  unit->previous_seed_flag_ = stmlib::GATE_FLAG_LOW;
  unit->delay_mode_transition_ = 0.0f;
  unit->delay_mode_ = false;

  SETCALC(BeadsUGen_next);
  ClearUnitOutputs(unit, 1);
}


static void BeadsUGen_Dtor(BeadsUGen *unit) {
  if (unit->processor) delete unit->processor;
  if (unit->delay_buffer) RTFree(unit->mWorld, unit->delay_buffer);
  if (unit->reverb_buffer) RTFree(unit->mWorld, unit->reverb_buffer);
}


static inline float BeadsUGen_smooth(float current, float target) {
  return current + 0.2f * (target - current);
}


static void BeadsUGen_next(BeadsUGen *unit, int inNumSamples) {

  // ----- read control args (switches unsmoothed, pots one-poled) -----
  float *cur = unit->cur_;
  cur[POT_TIME]      = BeadsUGen_smooth(cur[POT_TIME],      IN0(0));
  cur[POT_TIME_AMT]  = BeadsUGen_smooth(cur[POT_TIME_AMT],  IN0(1));
  cur[POT_SIZE]      = BeadsUGen_smooth(cur[POT_SIZE],      IN0(2));
  cur[POT_SIZE_AMT]  = BeadsUGen_smooth(cur[POT_SIZE_AMT],  IN0(3));
  cur[POT_SHAPE]     = BeadsUGen_smooth(cur[POT_SHAPE],     IN0(4));
  cur[POT_SHAPE_AMT] = BeadsUGen_smooth(cur[POT_SHAPE_AMT], IN0(5));
  cur[POT_PITCH]     = BeadsUGen_smooth(cur[POT_PITCH],     IN0(6));
  cur[POT_PITCH_AMT] = BeadsUGen_smooth(cur[POT_PITCH_AMT], IN0(7));
  cur[POT_DENSITY]   = BeadsUGen_smooth(cur[POT_DENSITY],   IN0(8));
  cur[POT_FEEDBACK]  = BeadsUGen_smooth(cur[POT_FEEDBACK],  IN0(9));
  cur[POT_DRYWET]    = BeadsUGen_smooth(cur[POT_DRYWET],    IN0(10));
  cur[POT_REVERB]    = BeadsUGen_smooth(cur[POT_REVERB],    IN0(11));
  cur[POT_GAIN]      = BeadsUGen_smooth(cur[POT_GAIN],      IN0(12));

  CONSTRAIN(cur[POT_TIME], 0.f, 1.f);
  CONSTRAIN(cur[POT_TIME_AMT], -1.f, 1.f);
  CONSTRAIN(cur[POT_SIZE], 0.f, 1.f);
  CONSTRAIN(cur[POT_SIZE_AMT], -1.f, 1.f);
  CONSTRAIN(cur[POT_SHAPE], 0.f, 1.f);
  CONSTRAIN(cur[POT_SHAPE_AMT], -1.f, 1.f);
  CONSTRAIN(cur[POT_PITCH], -36.f, 36.f);
  CONSTRAIN(cur[POT_PITCH_AMT], -1.f, 1.f);
  CONSTRAIN(cur[POT_DENSITY], 0.f, 1.f);
  CONSTRAIN(cur[POT_FEEDBACK], 0.f, 1.f);
  CONSTRAIN(cur[POT_DRYWET], 0.f, 1.f);
  CONSTRAIN(cur[POT_REVERB], 0.f, 1.f);
  CONSTRAIN(cur[POT_GAIN], 0.125f, 8.f);

  const bool freeze_now = IN0(13) > 0.5f;
  const bool seed_now = IN0(14) > 0.5f;
  const bool latch_now = IN0(15) > 0.5f;
  int media_now = (int)IN0(16);
  CONSTRAIN(media_now, 0, 3);
  const bool mono_now = IN0(17) > 0.5f;

  // media/mono changes are ignored while frozen (firmware behavior)
  if (!unit->freeze_ && !freeze_now &&
      (media_now != unit->media_ || mono_now != unit->mono_)) {
    unit->media_ = media_now;
    unit->mono_ = mono_now;
    unit->processor->Configure(
        static_cast<beads::Processor::Media>(media_now), mono_now);
    // equivalent of the 250 ms codec-restart mute
    unit->transition_ = int(0.25f * SAMPLERATE);
  }
  unit->freeze_ = freeze_now;
  unit->latch_ = latch_now;

  // ----- pack parameters (no CV on norns: the attenurandomizer only) -----
  beads::Parameters p;
  p.time.base = cur[POT_TIME];
  p.time.attenuverter = cur[POT_TIME_AMT];
  p.time.has_cv = false;
  p.time.cv = 0.0f;

  p.size.base = cur[POT_SIZE];
  p.size.attenuverter = cur[POT_SIZE_AMT];
  p.size.has_cv = false;
  p.size.cv = 0.0f;

  p.shape.base = cur[POT_SHAPE];
  p.shape.attenuverter = cur[POT_SHAPE_AMT];
  p.shape.has_cv = false;
  p.shape.cv = 0.0f;

  p.pitch.base = cur[POT_PITCH];     // semitones, +-24 from the panel
  p.pitch.attenuverter = cur[POT_PITCH_AMT];
  p.pitch.has_cv = false;
  p.pitch.cv = 0.0f;

  p.monophonic_mode = false;

  beads::ModulatedParameter d;
  d.base = cur[POT_DENSITY];
  d.cv = 0.0f;

  beads::Processor::MixParameters m;
  m.feedback = cur[POT_FEEDBACK];
  m.dry_wet = cur[POT_DRYWET];
  m.reverb_amount = cur[POT_REVERB];
  m.output_gate = false;

  const beads::SeedButtonState seed_state = latch_now
      ? beads::SEED_BUTTON_STATE_LOCKED
      : (seed_now ? beads::SEED_BUTTON_STATE_ON : beads::SEED_BUTTON_STATE_OFF);

  const float gain = cur[POT_GAIN];

  float *outL = OUT(0);
  float *outR = OUT(1);

  // ----- process in chunks -----
  int pos = 0;
  while (pos < inNumSamples) {
    const int n = (inNumSamples - pos) < kMaxChunk
        ? (inNumSamples - pos) : kMaxChunk;

    // freeze array (constant per block - no CV)
    for (int i = 0; i < n; ++i) {
      unit->freeze_buf_[i] = freeze_now;
    }

    // seed gate flags from the held state
    for (int i = 0; i < n; ++i) {
      unit->previous_seed_flag_ = unit->seed_buf_[i] =
          stmlib::ExtractGateFlags(unit->previous_seed_flag_, seed_now);
    }

    if (unit->transition_ > 0) {
      for (int i = 0; i < n; ++i) {
        unit->in_[i].l = unit->in_[i].r = 0.0f;
        unit->out_[i].l = unit->out_[i].r = 0.0f;
      }
      unit->transition_ -= n;
    } else {
      for (int i = 0; i < n; ++i) {
        unit->in_[i].l = IN(kNumKrArgs)[i + pos] * gain;
        unit->in_[i].r = IN(kNumKrArgs + 1)[i + pos] * gain;
      }

      unit->processor->Process(
          seed_state,
          unit->seed_buf_,
          unit->freeze_buf_,
          d, p, m,
          unit->in_,
          unit->out_,
          n);

      for (int i = 0; i < n; ++i) {
        float l = unit->out_[i].l;
        float r = unit->out_[i].r;
        CONSTRAIN(l, -1.0f, 0.999999f);
        CONSTRAIN(r, -1.0f, 0.999999f);
        unit->out_[i].l = l;
        unit->out_[i].r = r;
      }
    }

    for (int i = 0; i < n; ++i) {
      outL[i + pos] = unit->out_[i].l;
      outR[i + pos] = unit->out_[i].r;
    }

    // mirror of the granular<->delay mode hysteresis (UI only)
    const float threshold = unit->delay_mode_ ? 0.98f : 0.99f;
    const float direction = cur[POT_SIZE] > threshold ? 1.0f : -1.0f;
    unit->delay_mode_transition_ += direction * float(n) / SAMPLERATE;
    CONSTRAIN(unit->delay_mode_transition_, -1.5f, 1.5f);
    unit->delay_mode_ = unit->delay_mode_transition_ > 0.0f;

    pos += n;
  }

  // ----- block-constant UI outputs -----
  const float reserve = unit->processor->overwrite_reserve();
  const int *write_ptr = unit->processor->mutable_delay_write_ptr();
  const int line_length =
      kLineMaxDelay[unit->media_] * (unit->mono_ ? 2 : 1);
  float write_phase = 0.0f;
  if (line_length > 0) {
    int wp = *write_ptr;
    if (wp < 0) wp = 0;
    if (wp >= line_length) wp = line_length - 1;
    write_phase = float(line_length - wp) / float(line_length);
  }

  float *outReserve = OUT(2);
  float *outWritePos = OUT(3);
  float *outDelayMode = OUT(4);
  for (int i = 0; i < inNumSamples; ++i) {
    outReserve[i] = reserve;
    outWritePos[i] = write_phase;
    outDelayMode[i] = unit->delay_mode_ ? 1.0f : 0.0f;
  }
}


PluginLoad(BeadsUGen) {
  ft = inTable;
  // the struct name IS the registered ugen name - it must match the
  // sclang class name (BeadsUGen.ar) exactly or the server rejects every
  // synthdef with "UGen not installed"
  DefineDtorUnit(BeadsUGen);
}
