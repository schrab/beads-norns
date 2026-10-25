/*
  BeadsUGen - SuperCollider UGen wrapping the DSP of the Mutable Instruments
  'Beads' eurorack module (granular delay/looper).

  Original Beads code by Emilie Gillet (c) 2017, MIT license
  https://github.com/pichenettes/eurorack

  UGen wrapper by schrab for the norns port, following the pattern of
  v7b1's mi-UGens (GPL-3). This file is GPL-3.

  Signal path (all inside beads::Processor):
    input -> gain control (AGC + per-media soft clipping, the GainControl
    stage of the hardware codec path) -> [per-media rate adapter] -> delay
    line write (feedback limited) -> granular player (32 grains) OR 8-tap
    multitap delay (SIZE > 0.99) -> dry/wet -> wow & flutter (tape media)
    -> reverb -> limiter -> output

  Rates: on hardware the codec is re-clocked per media and the engines run
  at 24 kHz (scorched tape), 24 kHz internal behind 48 kHz frames (sunny
  tape, self-decimating), 32 kHz (cold digital) and 48 kHz (digital) - see
  Processor::sample_rate(). This wrapper always receives scsynth's 48 kHz
  (norns fixed rate) and adapts scorched/cold with the vendored stmlib
  polyphase SampleRateConverter: 2:1 down/up for scorched tape, 3:2 as
  up-2/down-3 for cold digital. Engines are clocked in aligned superblocks
  (64 host samples for scorched, 192 for cold digital) so the integer-ratio
  converters chain exactly; this adds ~1.5 ms of converter latency on those
  two media only. Do not use at host rates other than 48 kHz.
*/

#include <algorithm>
#include <cmath>

#include "SC_PlugIn.h"

#include "stmlib/dsp/dsp.h"
#include "stmlib/dsp/parameter_interpolator.h"
#include "beads/dsp/processor.h"
#include "beads/resources.h"

static InterfaceTable *ft;

using namespace std;

// control-rate args (indices 0..kNumKrArgs-1); audio inputs follow at
// kNumKrArgs (L) and kNumKrArgs+1 (R)
static const int kNumKrArgs = 20;
static const int kMaxChunk = 128;
static const int kRingSize = 256;      // >= superblock max (192) + block (64)
static const int kSuperDirty = 64;     // host samples / scorched superblock
static const int kSuperVintage = 192;  // host samples / cold-digital superblock
static const int kFramesDirty = kSuperDirty / 2;          // 32 @ 24 kHz
static const int kFramesVintage = kSuperVintage * 2 / 3;  // 128 @ 32 kHz

// DelayLine carves 3 banks x 262144 bytes (delay_line.h template defaults)
// and the hardware wires the same three regions (512K + 256K, beads.cc).
// That is 786432 bytes - NOT the nominal 768 * 1000 of
// kDelayBufferSizeBits, which is only the size used to derive the
// per-media sample capacities.
static const size_t kBankSize = 262144;
static const size_t kNumBanks = 3;

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

// Faithful port of beads::GainControl (gain_control.cc) minus the codec and
// jack-normalization plumbing: AGC when the gain setting is 0 (hardware GAIN
// knob fully counter-clockwise), manual law (setting/255)^4 scaled 1..40,
// and the per-media soft-clipping crossfade (ON for scorched tape, DYNAMIC
// for sunny tape, OFF otherwise - beads.cc ConfigureAndStartCodec).
class BeadsGainControl {
 public:
  enum SoftClippingMode {
    SOFT_CLIPPING_MODE_OFF,
    SOFT_CLIPPING_MODE_ON,
    SOFT_CLIPPING_MODE_DYNAMIC
  };

  void Init(float sample_rate, SoftClippingMode mode, bool reset) {
    if (reset) {
      stable_agc_peak_ = agc_peak_ = peak_ = 0.5f;
      gain_ = 1.0f;
      manual_gain_ = 1.0f;
      soft_clipping_amount_ = 0.0f;
    }
    soft_clipping_mode_ = mode;

    ignore_time_ = static_cast<size_t>(sample_rate * 1.0f);
    bool no_readjust = !reset && time_ && time_ >= active_time_;
    active_time_ = static_cast<size_t>(sample_rate * (1.0f + 5.0f));
    time_ = no_readjust ? active_time_ : 0;
    one_hertz_ = 1.0f / sample_rate;
  }

  void Process(
      uint8_t gain_setting,
      const float* in_l,
      const float* in_r,
      FloatFrame* out,
      size_t size) {
    const float hz = static_cast<float>(size) * one_hertz_;
    if (time_ < ignore_time_) {
      agc_peak_ = 0.5f;
    } else if (time_ < active_time_) {
      SLOPE(agc_peak_, peak_, 10.0f * hz, 2.0f * hz);
      stable_agc_peak_ = agc_peak_;
    } else {
      SLOPE(agc_peak_, peak_, 5.0f * hz,
            (peak_ > stable_agc_peak_ ? 0.5f : 0.01f) * hz);
    }

    if (time_ > ignore_time_ || peak_ > 0.001f) {
      time_ += size;
    }
    if (time_ >= active_time_) {
      time_ = active_time_;
    }

    const bool auto_gain = gain_setting == 0;

    float manual_gain = static_cast<float>(gain_setting) / 255.0f;
    manual_gain *= manual_gain;
    manual_gain *= manual_gain;
    manual_gain = 1.0f + (40.0f - 1.0f) * manual_gain;
    // The hardware smooths the setting once per 12-sample codec block
    // (4 kHz block rate); keep the same ~25 ms slope at 64-sample blocks.
    ONE_POLE(manual_gain_, manual_gain, 0.05333f);

    const float optimal_gain = min(0.9f / min(agc_peak_, 0.9f), 40.0f);
    const float gain = auto_gain ? optimal_gain : manual_gain_;

    float soft_clipping_amount;
    if (soft_clipping_mode_ == SOFT_CLIPPING_MODE_OFF) {
      soft_clipping_amount = 0.0f;
    } else if (soft_clipping_mode_ == SOFT_CLIPPING_MODE_ON) {
      soft_clipping_amount = 1.0f;
    } else {
      soft_clipping_amount = 2.0f * (manual_gain_ / optimal_gain - 0.75f);
      CONSTRAIN(soft_clipping_amount, 0.0f, 1.0f)
    }

    stmlib::ParameterInterpolator gain_modulation(&gain_, gain, size);
    stmlib::ParameterInterpolator soft_clipping_amount_modulation(
        &soft_clipping_amount_,
        soft_clipping_amount,
        size);
    while (size--) {
      const float peak = max(fabsf(*in_l), fabsf(*in_r));
      SLOPE(peak_, peak, 0.1f, 2.0f * one_hertz_);

      const float g = gain_modulation.Next();

      float l = *in_l++ * g;
      float r = *in_r++ * g;

      if (!auto_gain) {
        if (soft_clipping_mode_ == SOFT_CLIPPING_MODE_OFF) {
          CONSTRAIN(l, -1.0f, +1.0f)
          CONSTRAIN(r, -1.0f, +1.0f)
        } else {
          // Crossfade between the clean, possibly hard-clipped signal and
          // the soft-clipped signal (bias trick from gain_control.cc).
          const float amount = soft_clipping_amount_modulation.Next();
          const float bias = 0.05f;
          const float soft_l = (1.0f - bias) * stmlib::SoftClip(l + bias) - bias;
          const float soft_r = (1.0f - bias) * stmlib::SoftClip(r + bias) - bias;

          CONSTRAIN(l, -1.0f, +1.0f)
          CONSTRAIN(r, -1.0f, +1.0f)
          l = stmlib::Crossfade(l, soft_l, amount);
          r = stmlib::Crossfade(r, soft_r, amount);
        }
      }

      out->l = l;
      out->r = r;
      ++out;
    }
  }

 private:
  float peak_ = 0.5f;
  float agc_peak_ = 0.5f;
  float stable_agc_peak_ = 0.5f;
  float gain_ = 1.0f;
  float manual_gain_ = 1.0f;
  float soft_clipping_amount_ = 0.0f;
  SoftClippingMode soft_clipping_mode_ = SOFT_CLIPPING_MODE_OFF;
  float one_hertz_ = 1.0f / 48000.0f;
  size_t time_ = 0;
  size_t ignore_time_ = 48000;
  size_t active_time_ = 48000 * 6;
};

struct BeadsUGen : public Unit {

  beads::Processor *processor;

  // 3 banks x 256 KB, shared by all four media engines (beads.cc layout)
  uint8_t   *delay_buffer;
  uint8_t   *buffer_banks[3];
  uint16_t  *reverb_buffer;

  BeadsGainControl gain_control_;

  // smoothed block-rate parameters
  float     cur_[POT_LAST];

  // switch state
  bool      freeze_;
  bool      mono_;
  int       media_;
  int       transition_;          // 250 ms mute after media/mono change

  // clock sync: when sync is on, a seed pulse is emitted whenever the
  // clockCount arg changes (counter pattern - safe against dropped OSC
  // messages). Pulses feed the DSP's external-clock paths: RenderDivider
  // in granular mode (density = division/probability) and the
  // synchronized DelayClock in delay mode (tap interval = beat).
  uint32_t  clock_count_prev_;
  bool      clock_pulse_;

  // Per-media rate adapters (hardware re-clocks its codec; we resample).
  // scorched tape: 48k <-> 24k (ratio 2). cold digital: 48k <-> 32k as
  // up-2/down-3. sunny tape handles its own 2:1 internally; digital is
  // native 48k. Each converter keeps its filter state across blocks.
  stmlib::SampleRateConverter<stmlib::SRC_DOWN, 2, 48> src_dirty_fwd_[2];
  stmlib::SampleRateConverter<stmlib::SRC_UP, 2, 48>   src_dirty_bwd_[2];
  stmlib::SampleRateConverter<stmlib::SRC_UP, 2, 48>   src_vintage_fwd_up_[2];
  stmlib::SampleRateConverter<stmlib::SRC_DOWN, 3, 48> src_vintage_fwd_down_[2];
  stmlib::SampleRateConverter<stmlib::SRC_UP, 3, 48>   src_vintage_bwd_up_[2];
  stmlib::SampleRateConverter<stmlib::SRC_DOWN, 2, 48> src_vintage_bwd_down_[2];

  // host-rate sample rings feeding the aligned superblocks (in ring holds
  // at most 191 leftover + 64 block = 255 samples; out ring peaks at ~194)
  float    in_ring_[2][kRingSize];
  int      in_read_[2];
  int      in_len_[2];
  float    out_ring_[2][kRingSize];
  int      out_read_[2];
  int      out_len_[2];
  uint32_t total_in_;
  uint32_t pending_pulses_[4];
  int      pending_pulse_count_;

  // per-chunk scratch
  beads::FloatFrame in_[kMaxChunk];
  beads::FloatFrame out_[kMaxChunk];
  bool       freeze_buf_[kMaxChunk];
  stmlib::GateFlags seed_buf_[kMaxChunk];   // clock-sync pulses only
  float      src_scratch_a_[2][2 * kSuperVintage + 4];
  float      src_scratch_b_[2][3 * kMaxChunk + 4];

  // mirror of the granular<->delay hysteresis, for the UI only
  float     delay_mode_transition_;
  bool      delay_mode_;
};

static void BeadsUGen_Ctor(BeadsUGen *unit);
static void BeadsUGen_Dtor(BeadsUGen *unit);
static void BeadsUGen_next(BeadsUGen *unit, int inNumSamples);

static inline void RingPush(float* ring, int* read_pos, int* len, float v) {
  ring[(*read_pos + *len) % kRingSize] = v;
  ++*len;
}

static inline float RingPop(float* ring, int* read_pos, int* len) {
  const float v = ring[*read_pos];
  *read_pos = (*read_pos + 1) % kRingSize;
  --*len;
  return v;
}

// CvReader PotChannel LAW_ATTENUVERTER (cv_reader.h): a raw 0..1 pot reads
// v = pot - 0.5; att = (2 / 0.47) * v * max(|v| - 0.03, 0). The port's
// linear -1..1 amount params map to pot = amt / 2 + 0.5, i.e. v = amt / 2 -
// same endpoints, same center dead zone, same expanding curve.
static inline float BeadsUGenAttenuverterLaw(float amt) {
  const float v = amt * 0.5f;
  return (2.0f / 0.47f) * v * std::max(fabsf(v) - 0.03f, 0.0f);
}

static void BeadsUGen_Ctor(BeadsUGen *unit) {

  if (SAMPLERATE != 48000.f) {
    Print("Beads WARNING: scsynth sample rate is %g Hz; the engines assume 48 kHz\n",
          SAMPLERATE);
  }

  const size_t kDelayBufferSize = kBankSize * kNumBanks;   // 786432
  const size_t kReverbBufferSize = 32768;

  unit->delay_buffer = (uint8_t*)RTAlloc(unit->mWorld, kDelayBufferSize);
  unit->reverb_buffer = (uint16_t*)RTAlloc(unit->mWorld,
                                           kReverbBufferSize * sizeof(uint16_t));
  if (unit->delay_buffer == NULL || unit->reverb_buffer == NULL) {
    Print("Beads ERROR: memory allocation failed\n");
    SETCALC(*ClearUnitOutputs);
    return;
  }
  for (size_t i = 0; i < kNumBanks; ++i) {
    unit->buffer_banks[i] = unit->delay_buffer + i * kBankSize;
  }

  unit->processor = new beads::Processor();
  unit->processor->Init(unit->buffer_banks, unit->reverb_buffer);

  unit->gain_control_.Init(48000.0f,
                           BeadsGainControl::SOFT_CLIPPING_MODE_OFF, true);

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
  unit->cur_[POT_GAIN] = 0.0f;

  unit->freeze_ = false;
  unit->mono_ = false;
  unit->media_ = beads::Processor::MEDIA_DIGITAL;   // Processor::Init configured this
  unit->transition_ = 0;
  unit->clock_count_prev_ = 0;
  unit->clock_pulse_ = false;
  unit->delay_mode_transition_ = 0.0f;
  unit->delay_mode_ = false;

  unit->in_read_[0] = unit->in_read_[1] = 0;
  unit->in_len_[0] = unit->in_len_[1] = 0;
  unit->out_read_[0] = unit->out_read_[1] = 0;
  unit->out_len_[0] = unit->out_len_[1] = 0;
  unit->total_in_ = 0;
  unit->pending_pulse_count_ = 0;

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


// Runs one aligned engine superblock: pulls `super` host samples out of the
// input ring, converts them to the engine's frame rate, renders, and pushes
// `super` host samples into the output ring. Rates are exact per
// superblock, so the rings neither starve nor accumulate in steady state.
static void BeadsUGen_Superblock(
    BeadsUGen* unit, int super, int frames, bool clocked,
    beads::SeedButtonState seed_state,
    const beads::ModulatedParameter& d,
    const beads::Parameters& p,
    const beads::Processor::MixParameters& m,
    bool freeze_now) {
  const bool dirty = unit->media_ == beads::Processor::MEDIA_DIRTY_TAPE;
  const uint32_t super_start = unit->total_in_ - unit->in_len_[0];

  // 1) pull host samples out of the input ring (deinterleaved)
  for (int i = 0; i < super; ++i) {
    unit->src_scratch_a_[0][i] =
        RingPop(unit->in_ring_[0], &unit->in_read_[0], &unit->in_len_[0]);
    unit->src_scratch_a_[1][i] =
        RingPop(unit->in_ring_[1], &unit->in_read_[1], &unit->in_len_[1]);
  }

  // 2) host rate -> engine rate
  if (dirty) {
    for (int c = 0; c < 2; ++c) {
      unit->src_dirty_fwd_[c].Process(
          unit->src_scratch_a_[c], unit->src_scratch_b_[c], super);
    }
    for (int f = 0; f < frames; ++f) {
      unit->in_[f].l = unit->src_scratch_b_[0][f];
      unit->in_[f].r = unit->src_scratch_b_[1][f];
    }
  } else {
    for (int c = 0; c < 2; ++c) {
      unit->src_vintage_fwd_up_[c].Process(
          unit->src_scratch_a_[c], unit->src_scratch_b_[c], super);
      unit->src_vintage_fwd_down_[c].Process(
          unit->src_scratch_b_[c], unit->src_scratch_a_[c], 2 * super);
    }
    for (int f = 0; f < frames; ++f) {
      unit->in_[f].l = unit->src_scratch_a_[0][f];
      unit->in_[f].r = unit->src_scratch_a_[1][f];
    }
  }

  // 3) freeze + seed flags at engine rate. Clock pulses are absolute host
  // sample indices; map each one to the engine frame covering it.
  for (int f = 0; f < frames; ++f) {
    unit->freeze_buf_[f] = freeze_now;
  }
  const stmlib::GateFlags* seed_input = nullptr;
  if (clocked) {
    for (int f = 0; f < frames; ++f) {
      unit->seed_buf_[f] = stmlib::GATE_FLAG_LOW;
    }
    int kept = 0;
    for (int k = 0; k < unit->pending_pulse_count_; ++k) {
      const uint32_t rel = unit->pending_pulses_[k] - super_start;
      if (rel < 0x80000000u) {                       // not in the past
        if (rel < static_cast<uint32_t>(super)) {
          const int f = dirty
              ? static_cast<int>(rel / 2)
              : static_cast<int>((rel * 2) / 3);
          unit->seed_buf_[f] = static_cast<stmlib::GateFlags>(
              stmlib::GATE_FLAG_RISING | stmlib::GATE_FLAG_HIGH);
        }
        unit->pending_pulses_[kept++] = unit->pending_pulses_[k];
      }
    }
    unit->pending_pulse_count_ = kept;
    seed_input = unit->seed_buf_;
  }

  // 4) render
  unit->processor->Process(
      seed_state,
      seed_input,
      unit->freeze_buf_,
      d, p, m,
      unit->in_,
      unit->out_,
      frames);

  for (int f = 0; f < frames; ++f) {
    CONSTRAIN(unit->out_[f].l, -1.0f, 0.999999f);
    CONSTRAIN(unit->out_[f].r, -1.0f, 0.999999f);
  }

  // 5) engine rate -> host rate, push into the output ring
  if (dirty) {
    for (int c = 0; c < 2; ++c) {
      for (int f = 0; f < frames; ++f) {
        unit->src_scratch_a_[c][f] =
            *(&(unit->out_[f].l) + c);
      }
      unit->src_dirty_bwd_[c].Process(
          unit->src_scratch_a_[c], unit->src_scratch_b_[c], frames);
    }
    for (int i = 0; i < super; ++i) {
      RingPush(unit->out_ring_[0], &unit->out_read_[0], &unit->out_len_[0],
               unit->src_scratch_b_[0][i]);
      RingPush(unit->out_ring_[1], &unit->out_read_[1], &unit->out_len_[1],
               unit->src_scratch_b_[1][i]);
    }
  } else {
    for (int c = 0; c < 2; ++c) {
      for (int f = 0; f < frames; ++f) {
        unit->src_scratch_a_[c][f] =
            *(&(unit->out_[f].l) + c);
      }
      unit->src_vintage_bwd_up_[c].Process(
          unit->src_scratch_a_[c], unit->src_scratch_b_[c], frames);
      unit->src_vintage_bwd_down_[c].Process(
          unit->src_scratch_b_[c], unit->src_scratch_a_[c], 3 * frames);
    }
    for (int i = 0; i < super; ++i) {
      RingPush(unit->out_ring_[0], &unit->out_read_[0], &unit->out_len_[0],
               unit->src_scratch_a_[0][i]);
      RingPush(unit->out_ring_[1], &unit->out_read_[1], &unit->out_len_[1],
               unit->src_scratch_a_[1][i]);
    }
  }
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
  CONSTRAIN(cur[POT_GAIN], 0.f, 255.f);
  const uint8_t gain_setting = static_cast<uint8_t>(cur[POT_GAIN] + 0.5f);

  const bool freeze_now = IN0(13) > 0.5f;
  const bool seed_now = IN0(14) > 0.5f;
  const bool latch_now = IN0(15) > 0.5f;
  int media_now = (int)IN0(16);
  CONSTRAIN(media_now, 0, 3);
  const bool mono_now = IN0(17) > 0.5f;
  const bool sync_now = IN0(18) > 0.5f;
  const uint32_t clock_count = (uint32_t)IN0(19);

  const bool adapter_media =
      media_now == beads::Processor::MEDIA_DIRTY_TAPE ||
      media_now == beads::Processor::MEDIA_VINTAGE_DIGITAL;

  if (clock_count != unit->clock_count_prev_) {
    unit->clock_count_prev_ = clock_count;
    if (sync_now && latch_now && adapter_media) {
      // the pulse becomes one host sample in the ring; the superblock
      // maps it to an engine frame
      if (unit->pending_pulse_count_ < 4) {
        unit->pending_pulses_[unit->pending_pulse_count_++] = unit->total_in_;
      }
    } else {
      unit->clock_pulse_ = true;    // consumed by the next direct chunk
    }
  }

  // media/mono changes are ignored while frozen (firmware behavior)
  const bool media_changed = media_now != unit->media_;
  const bool mono_changed = mono_now != unit->mono_;
  if (!unit->freeze_ && !freeze_now && (media_changed || mono_changed)) {
    unit->media_ = media_now;
    unit->mono_ = mono_now;
    unit->processor->Configure(
        static_cast<beads::Processor::Media>(media_now), mono_now);
    // equivalent of the 250 ms codec-restart mute; the hardware also
    // restarts the input stage here (GainControl mode follows the media,
    // AGC state reset only on mono change, like reset_gain_control)
    BeadsGainControl::SoftClippingMode gain_mode =
        media_now == beads::Processor::MEDIA_DIRTY_TAPE
            ? BeadsGainControl::SOFT_CLIPPING_MODE_ON
            : (media_now == beads::Processor::MEDIA_CLEAN_TAPE
                  ? BeadsGainControl::SOFT_CLIPPING_MODE_DYNAMIC
                  : BeadsGainControl::SOFT_CLIPPING_MODE_OFF);
    unit->gain_control_.Init(48000.0f, gain_mode, mono_changed);
    unit->transition_ = int(0.25f * SAMPLERATE);
    unit->in_read_[0] = unit->in_read_[1] = 0;
    unit->in_len_[0] = unit->in_len_[1] = 0;
    unit->out_read_[0] = unit->out_read_[1] = 0;
    unit->out_len_[0] = unit->out_len_[1] = 0;
    unit->pending_pulse_count_ = 0;
    for (int c = 0; c < 2; ++c) {
      unit->src_dirty_fwd_[c].Init();
      unit->src_dirty_bwd_[c].Init();
      unit->src_vintage_fwd_up_[c].Init();
      unit->src_vintage_fwd_down_[c].Init();
      unit->src_vintage_bwd_up_[c].Init();
      unit->src_vintage_bwd_down_[c].Init();
    }
  }
  unit->freeze_ = freeze_now;

  // ----- pack parameters (no CV on norns: the attenurandomizer only) -----
  beads::Parameters p;
  p.time.base = cur[POT_TIME];
  p.time.attenuverter = BeadsUGenAttenuverterLaw(cur[POT_TIME_AMT]);
  p.time.has_cv = false;
  p.time.cv = 0.0f;

  p.size.base = cur[POT_SIZE];
  p.size.attenuverter = BeadsUGenAttenuverterLaw(cur[POT_SIZE_AMT]);
  p.size.has_cv = false;
  p.size.cv = 0.0f;

  p.shape.base = cur[POT_SHAPE];
  p.shape.attenuverter = BeadsUGenAttenuverterLaw(cur[POT_SHAPE_AMT]);
  p.shape.has_cv = false;
  p.shape.cv = 0.0f;

  p.pitch.base = cur[POT_PITCH];     // semitones, +-24 from the panel law
  p.pitch.attenuverter = BeadsUGenAttenuverterLaw(cur[POT_PITCH_AMT]);
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

  float *outL = OUT(0);
  float *outR = OUT(1);

  if (unit->transition_ > 0) {
    // codec-restart mute; rings and converters were reset by Configure
    for (int i = 0; i < inNumSamples; ++i) {
      outL[i] = 0.0f;
      outR[i] = 0.0f;
    }
    unit->transition_ -= inNumSamples;
    if (unit->transition_ < 0) unit->transition_ = 0;
  } else if (adapter_media) {
    const int super = unit->media_ == beads::Processor::MEDIA_DIRTY_TAPE
        ? kSuperDirty : kSuperVintage;
    const int frames = unit->media_ == beads::Processor::MEDIA_DIRTY_TAPE
        ? kFramesDirty : kFramesVintage;

    // push the block through the input stage into the host-rate ring
    unit->gain_control_.Process(
        gain_setting,
        IN(kNumKrArgs), IN(kNumKrArgs + 1),
        unit->in_, inNumSamples);
    for (int i = 0; i < inNumSamples; ++i) {
      RingPush(unit->in_ring_[0], &unit->in_read_[0], &unit->in_len_[0],
               unit->in_[i].l);
      RingPush(unit->in_ring_[1], &unit->in_read_[1], &unit->in_len_[1],
               unit->in_[i].r);
    }
    unit->total_in_ += inNumSamples;

    while (unit->in_len_[0] >= super) {
      BeadsUGen_Superblock(
          unit, super, frames, sync_now && latch_now, seed_state, d, p, m,
          freeze_now);
    }

    for (int i = 0; i < inNumSamples; ++i) {
      outL[i] = unit->out_len_[0] > 0
          ? RingPop(unit->out_ring_[0], &unit->out_read_[0], &unit->out_len_[0])
          : 0.0f;
      outR[i] = unit->out_len_[1] > 0
          ? RingPop(unit->out_ring_[1], &unit->out_read_[1], &unit->out_len_[1])
          : 0.0f;
    }
  } else {
    int pos = 0;
    while (pos < inNumSamples) {
      const int n = (inNumSamples - pos) < kMaxChunk
          ? (inNumSamples - pos) : kMaxChunk;

      for (int i = 0; i < n; ++i) {
        unit->freeze_buf_[i] = freeze_now;
      }

      // Seed input: NULL when unsynchronized (exactly like the firmware with
      // an unpatched jack - the button state carries gating and tap tempo).
      // When clock sync is on, emit a 1-sample clock pulse on the counter
      // change: LOCKED + external input engages RenderDivider (granular) /
      // the synchronized DelayClock (delay mode), matching the hardware's
      // clocked-SEED behavior.
      const stmlib::GateFlags* seed_input = nullptr;
      if (sync_now && latch_now) {
        stmlib::GateFlags* seed_flags = unit->seed_buf_;
        const bool pulse = unit->clock_pulse_;
        for (int i = 0; i < n; ++i) {
          seed_flags[i] = (pulse && i == 0)
              ? (stmlib::GATE_FLAG_RISING | stmlib::GATE_FLAG_HIGH)
              : stmlib::GATE_FLAG_LOW;
        }
        unit->clock_pulse_ = false;
        seed_input = seed_flags;
      } else {
        unit->clock_pulse_ = false;
      }

      unit->gain_control_.Process(
          gain_setting,
          IN(kNumKrArgs) + pos, IN(kNumKrArgs + 1) + pos,
          unit->in_, n);

      unit->processor->Process(
          seed_state,
          seed_input,
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
        outL[i + pos] = l;
        outR[i + pos] = r;
      }

      pos += n;
    }
  }

  // mirror of the granular<->delay mode hysteresis (UI only)
  {
    const float threshold = unit->delay_mode_ ? 0.98f : 0.99f;
    const float direction = cur[POT_SIZE] > threshold ? 1.0f : -1.0f;
    unit->delay_mode_transition_ += direction * float(inNumSamples) / SAMPLERATE;
    CONSTRAIN(unit->delay_mode_transition_, -1.5f, 1.5f);
    unit->delay_mode_ = unit->delay_mode_transition_ > 0.0f;
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
