-- beads
--
-- mutable instruments beads
-- for norns: the module's
-- actual dsp as a sc ugen.
--
-- e1 page; e2/e3 edit the
-- active pair (k3 toggles);
-- e4 = page's last param.
-- play: k2 freeze, k3 seed;
-- k1+k3 toggles latch.
-- tape: k3 play/stop.
--
-- full docs: readme.md

engine.name = "Beads"

-- Mutable Instruments Beads for norns.
-- E1 page  E2/E3 = the page's ACTIVE PARAM PAIR (K3 tap toggles the banks:
-- (1,2) <-> (3,4) on 4-param pages, (1,2) <-> (3) on 3-param pages; E4 on
-- 4-encoder hardware = the page's LAST param)
-- PLAY page: K2 freeze, K3 hold = seed (unchanged). TAPE page: K3 = play.
-- pages:
--   PLAY   time    pitch         pitch amount    (frozen layout)
--   GRAIN  density size          shape / shape amount
--   RANDOM time amt   size amt   shape amt / pitch amt (all 4 amounts)
--   MIX    feedback   reverb     dry/wet / input gain
--   CLOCK  sync    subdivision   seed latch
--   SETUP  media   channels
--   TAPE   level   loop/once     play/stop (K3 = play; file browser in menu)
--   MIDI   note pitch ref note   bend range
-- TAPE page: play an audio file (e.g. a norns TAPE recording) into the
-- granulator input - the buffer-feed path the hardware never had
-- MIDI note pitch = the hardware PITCH CV jack: notes (last-note priority,
-- held on release) transpose by (note - ref) semitones; PLAY E4 "pitch
-- amount" is the CV depth, like the module's PITCH AMOUNT knob.
-- amounts (RANDOM page): positive = spray the param toward random per grain
-- (pitch: +-24 st), negative = peak near the knob value, 0 = off
-- clock sync: with the latch on, the beats clock the DSP (delay tempo =
-- bpm x subdivision, granular divider - the hardware's clocked SEED jack);
-- with the latch off, every beat fires one seed trigger (the hardware's
-- patched-SEED trigger behavior)
-- all params (incl. freeze/latch) live in the PARAMS menu; MIDI mapping
-- works there like any norns script.

local beadse = include "lib/beads_engine"
local musicutil = require "musicutil"
local fileselect = include "lib/fileselect"

-- the matrix mod singleton (optional): needed to validate which sources
-- are STILL mapped to our params - matrix leaves stale entries in a
-- param's .modulation after an unmap
local mm_ok, mm = pcall(require, 'matrix/lib/matrix')
if not mm_ok or type(mm) ~= 'table' or mm.matrix == nil then
  mm_ok, mm = false, nil
end

local STATS = { reserve = 1.0, dmode = 0.0 }

local pages = { "PLAY", "GRAIN", "RND", "MIX", "CLOCK", "SETUP", "TAPE", "MIDI", "SYNTH" }
local page = 1
local seed_down = false
-- seed gate opened through matrix-mod modulation (e.g. a marbles t-gate
-- mapped to the "seed (hold)" param): matrix stores live source*depth
-- values on the param object but never fires the action (it only patches
-- number:bang, not binary:bang), so the gate is tracked separately
local seed_mod = false
-- K3 tap toggles the page's active param pair: bank 1 = params (1,2),
-- bank 2 = params (3,4) — or just (3) on 3-param pages (E3 idle there).
-- PLAY keeps K3 = seed (instant), TAPE keeps K3 = play/stop: no toggling
-- there. Pages with fewer than 3 params cannot switch.
local bank = { 1, 1, 1, 1, 1, 1, 1, 1, 1 }
local enc4_seen = false
-- norns forwards K1 to the script only on holds >= 0.25s (a short press
-- opens the system menu); the held state arms the PLAY-page latch toggle
local k1_down = false
local dirty = true
local redrawer

-- granulator particle sim state (declared before the sync loop, whose
-- clock closure feeds pending_pulses)
local grains = {}
local spawn_acc = 0
local pending_pulses = 0
-- tape splice point (buffer seam): a material point on the virtual tape,
-- synced from the engine's write-phase poll and dead-reckoned between
-- polls at one loop per buf_s; freezes with the tape. The reels are
-- phase-locked to it (same variable drives both).
local seam_pos = 0
local seam_have = false

-- MIDI note pitch (PITCH CV jack equivalent)
local midi_stack = {}   -- held notes, most recent last
local last_note = nil   -- persists after release: a CV keyboard holds voltage
local bend_st = 0.0
local last_cv_sent = nil

-- tape-file player (TAPE page): a loaded file streams into the granulator
-- input, summed with the hardware line-in
local tape_file = nil
local tape_name = ""
local tape_playing = false

local function load_tape_file()
  -- fileselect reroutes the screen keys (or the menu handlers, when opened
  -- from PARAMS) while it is open, and restores them after. Start in the
  -- shared samples folder - recordings live one level up in ~/tape and
  -- every sample folder is reachable from here.
  fileselect.enter(_path.audio, function(file)
    if file then
      tape_file = file
      tape_name = string.match(file, "[^/]+$") or file
      engine.buffer_load(file)
      if not tape_playing then
        tape_playing = true
        engine.buffer_play(1)
      end
    end
    dirty = true
  end, "audio")
end

local function push_pitch_cv()
  if params:get("midi_pitch") ~= 2 then
    if last_cv_sent ~= false then
      last_cv_sent = false
      pcall(function() engine.pitch_cv(0, 0) end)
    end
    return
  end
  local cv = 0
  if last_note then
    cv = util.clamp(last_note - params:get("midi_ref") + bend_st, -60, 60)
  end
  if last_cv_sent ~= cv then
    last_cv_sent = cv
    pcall(function() engine.pitch_cv(1, cv) end)
  end
end

local function midi_note_on(note)
  for i, n in ipairs(midi_stack) do
    if n == note then table.remove(midi_stack, i) break end
  end
  table.insert(midi_stack, note)
  last_note = note
  push_pitch_cv()
  dirty = true
end

local function midi_note_off(note)
  for i, n in ipairs(midi_stack) do
    if n == note then table.remove(midi_stack, i) break end
  end
  if #midi_stack > 0 then last_note = midi_stack[#midi_stack] end
  push_pitch_cv()
  dirty = true
end

local function midi_bend(val)
  local range = params:get("midi_bend")
  if range == 0 then return end
  bend_st = (val / 8192 - 1) * range
  push_pitch_cv()
end

local function midi_event(data)
  local msg = midi.to_msg(data)
  if msg.type == "note_on" and msg.vel > 0 then
    midi_note_on(msg.note)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    midi_note_off(msg.note)
  elseif msg.type == "pitchbend" then
    midi_bend(msg.val)
  end
end

-- (re)assert handlers on every vport: covers devices assigned after start
local function midi_connect_all()
  for i = 1, #midi.vports do
    pcall(function() midi.connect(i).event = midi_event end)
  end
end

-- per-page parameter stack (index 1..n). E2/E3 edit the ACTIVE PAIR window
-- over indexes 1..3 (K3 tap cycles); E4 (4-encoder hardware) edits the LAST
-- index. PLAY is frozen (time/pitch/pitch_amt exactly as before).
-- kind: d/opt = params:delta; t2 = option set d>0?2:1; t01 = binary
-- set d>0?1:0; flip = binary toggle on any detent; subdiv = clock stepper
local PAGE_PARAMS = {
  { { "time", "d" },       { "pitch", "d" },      { "pitch_amt", "d" } },
  { { "density", "d" },    { "size", "d" },       { "shape", "d" },      { "shape_amt", "d" } },
  { { "time_amt", "d" },   { "size_amt", "d" },   { "shape_amt", "d" },  { "pitch_amt", "d" } },
  { { "feedback", "d" },   { "rvb", "d" },        { "drywet", "d" },     { "gain", "d" } },
  { { "sync", "t2" },      { "subdiv", "subdiv" },{ "latch", "t01" } },
  { { "media", "opt" },    { "mono", "opt" } },
  { { "tp_level", "d" },   { "tp_loop", "opt" },  { "tp_play", "flip" } },
  { { "midi_pitch", "t2" },{ "midi_ref", "d" },   { "midi_bend", "d" } },
  { { "synth", "t2" },     { "feedback", "d" },   { "gate", "t2" } },
}

local W, H = 128, 64
local MEDIA_SHORT = { "scorched cassette", "sunny tape", "cold digital", "bright digital" }

-- which row each encoder edits on the current page: returns param id + kind
-- (nil when the encoder has no param in this bank, e.g. E3 on a 3-param
-- page's second bank)
local function enc_target(n)
  local defs = PAGE_PARAMS[page]
  local idx
  if n == 4 then
    idx = #defs
  elseif n == 2 then
    idx = bank[page] == 1 and 1 or 3
  else
    idx = bank[page] == 1 and 2 or 4
  end
  if idx > #defs then return nil, nil end
  return defs[idx][1], defs[idx][2]
end

-- active state for the redraw (i = param stack index): active rows are
-- bright, the rest dim - no encoder text tags on the rows
local function row_active(i)
  local w1 = bank[page] == 1 and 1 or 3
  local w2 = bank[page] == 1 and 2 or (#PAGE_PARAMS[page] >= 4 and 4 or nil)
  return i == w1 or i == w2
end

-- row baseline: 4-row pages tighten the leading so the footer still fits
local function row_y(i, n_rows)
  return n_rows > 3 and (20 + (i - 1) * 11) or (22 + (i - 1) * 12)
end

-- wavetable bank shown on the SYNTH page/PLAY view: the DSP quantizes
-- FEEDBACK into 12 banks (Synth kNumBanks, hysteresis 0.048)
local function bank_num()
  return math.min(12, math.floor(params:get("feedback") * 12) + 1)
end

-- clocked delay-mode ratios, exactly the DSP's kRatio table
-- (delay_controller.cc): 20 slots, density * 20 -> slot. CCW half =
-- binary subdivisions, CW half = dividers (the hardware's ratio ring).
local KDIV_LABELS = {
  "1/16", "1/16", "1/8", "1/8", "1/4", "1/4", "1/2", "1/2",
  "1/1", "1/1", "1/1", "1/1",
  "1/2", "1/3", "1/4", "1/6", "1/8", "1/10", "1/12", "1/16",
}

local function delay_division(d)
  local idx = math.min(19, math.max(0, math.floor(d * 20)))
  return KDIV_LABELS[idx + 1]
end

-- clock sync subdivision macro: exact kRatio slot centers (one target
-- per distinct division on the hardware's density ring)
local SYNC_DIVS = {
  { "1/16", 0.05 }, { "1/8", 0.15 }, { "1/4", 0.25 }, { "1/2", 0.35 },
  { "1/1", 0.475 },
  { "1/2", 0.60 }, { "1/3", 0.65 }, { "1/4", 0.70 }, { "1/6", 0.75 },
  { "1/8", 0.80 }, { "1/10", 0.85 }, { "1/12", 0.90 }, { "1/16", 0.95 },
}

local function sync_div_label()
  local d = params:get("density")
  local best, bi = 9, 1
  for i, t in ipairs(SYNC_DIVS) do
    local dist = math.abs(d - t[2])
    if dist < best then best, bi = dist, i end
  end
  return SYNC_DIVS[bi][1]
end

local function sync_div_step(dir)
  local d = params:get("density")
  local bi = 1
  local best = 9
  for i, t in ipairs(SYNC_DIVS) do
    local dist = math.abs(d - t[2])
    if dist < best then best, bi = dist, i end
  end
  bi = util.clamp(bi + dir, 1, #SYNC_DIVS)
  params:set("density", SYNC_DIVS[bi][2])
end

-- clock sync: one engine seed pulse per norns-system beat engages the DSP's
-- clocked paths (delay tempo = beat x density subdivision; granular divider)
local sync_clock
local sync_last = 0          -- os.clock() of the last pulse (watchdog)

-- clock.get_bpm can error or return junk right after clock source/tempo
-- changes; a stray error inside a clock coroutine kills it (frozen screen,
-- dead sync loop), so every bpm use goes through this
local function safe_bpm()
  local ok, b = pcall(clock.get_bpm)
  if ok and type(b) == "number" and b > 1 then return b end
  return 120
end

local function stop_sync()
  if sync_clock then
    clock.cancel(sync_clock)
    sync_clock = nil
  end
end

local function start_sync()
  stop_sync()
  -- beats drive the seed input; the latch selects the mode (clocked
  -- divider when latched, one trigger per beat when not)
  if params:get("sync") == 2 then
    sync_last = os.clock()
    sync_clock = clock.run(function()
      while true do
        clock.sleep(60 / safe_bpm())
        -- engine commands can throw mid-(re)load; never let that kill
        -- the pulse loop (the watchdog would flap-restart it)
        pcall(function() engine.clock() end)
        pending_pulses = pending_pulses + 1
        sync_last = os.clock()
      end
    end)
  end
end

local sync_restart_at = 0

local function sync_watchdog()
  if params:get("sync") == 2 then
    local now = os.clock()
    if now - sync_last > (60 / safe_bpm()) * 4 + 2
        and now - sync_restart_at > 3 then
      sync_restart_at = now
      start_sync()   -- loop died or clock was reset - revive it, rate-limited
    end
  end
end


-- grain envelope preview, mirroring beads' grain_envelope.h exactly:
-- attack rises (curve t), sustain holds, release FALLS 1->0 with t running
-- backwards (t = 1 - phase, base t^4) - getting this wrong flips the decay
local function smoothstep(x) return x * x * (3 - 2 * x) end

local function envelope_point(s, t)
  local sustain = math.max(1 - 3 * s, 0)
  local a = math.max(0, (s - 1 / 3) * 1.5)
  if a < 0.5 then a = a * a * a * 4 end
  local release = (1 - a) * (1 - sustain)
  local norm = a + sustain + release
  if norm <= 0 then return 0 end
  local a_n, su_n, re_n = a / norm, sustain / norm, release / norm
  local smoothness = a < 0.5 and (2 * a) or (2 - 2 * a)
  if t < a_n then
    local x = t / math.max(a_n, 0.0001)
    local base = x
    return base + (smoothstep(x) - base) * smoothness
  elseif t < a_n + su_n then
    return 1
  else
    local x = (t - a_n - su_n) / math.max(re_n, 0.0001)
    x = math.min(x, 1)
    local tt = 1 - x                -- release time runs backwards
    local base = tt * tt * tt * tt
    return base + (smoothstep(tt) - base) * smoothness
  end
end

local function draw_envelope(x0, y0, w, h, s, level)
  local n = 96
  screen.aa(1)
  -- closed contour: attack edge up the left, the curve, release edge down
  -- the right - so instant attack/release (shape near 0) still shows both
  -- vertical lines instead of a bare horizontal line. Cairo keeps the path
  -- after fill(), so the same contour is filled dark then stroked.
  screen.move(x0, y0 + h)
  screen.line(x0, y0 + h - envelope_point(s, 0) * h)
  for i = 1, n do
    local t = i / n
    screen.line(x0 + t * w, y0 + h - envelope_point(s, t) * h)
  end
  screen.line(x0 + w, y0 + h)
  screen.level(level and (level > 6 and 3 or 2) or 2)
  screen.fill()
  -- crisp 1 px white contour on top of the dark fill (both states)
  screen.line_width(1)
  screen.level(15)
  screen.stroke()
  screen.aa(0)
  screen.line_width(1)
end

-- grain rate in Hz from density (trigger_generator.cc); 0 in the deadband
local function density_rate(d)
  if d < 0.48 then
    return 130.81 * 2 ^ (-16 * d)
  elseif d > 0.52 then
    return 0.5 * 130.81 * 2 ^ (-16 * (1 - d))
  end
  return 0
end

-- grain duration in seconds from size (granular_player.cc law)
local function grain_dur_s(s)
  local sh
  if s < 1 / 3 then
    local v = s * 3
    sh = v * (2 - v)
  else
    sh = 1 - 1.5 * (s - 1 / 3)
  end
  sh = math.min(1, 1.025 * sh)
  return 2 ^ (-9 * sh) * 4
end

local function density_string(d)
  if STATS.dmode > 0.5 then
    -- delay mode: density reads as the hardware's ratio ring
    -- (the free-running path sweeps the interval continuously, but the
    -- label follows the printed ring)
    return delay_division(d)
  end
  -- clocked reads as the mode, not a rate: latched = division, unlatched
  -- = one seed per beat
  if params:get("sync") == 2 then
    return params:get("latch") == 1 and "div" or "beats"
  end
  local r = density_rate(d)
  if r > 0 then
    return string.format("%s%d hz", d > 0.52 and "~" or "", math.floor(r + 0.5))
  end
  return params:get("latch") == 1 and "silent" or "tap"
end

-- the live grain count (printed in the loop) is just #grains - it reads 0
-- whenever the seed gate is closed and saturates at the DSP's 32-grain pool

-- current loop length in seconds (media + mono)
local function buf_seconds()
  return ({ 16, 10.7, 8, 4 })[params:get("media")]
      * (params:get("mono") == 2 and 2 or 1)
end

-- head safety zone as a loop fraction: the DSP starts grains at
-- time * (max_delay - 514) + 257 frames, so time 0 sits 257 frames
-- behind the head instead of exactly on it
local function head_safety()
  local n = ({ 384000, 256000, 256000, 192000 })[params:get("media")]
  return 257 / n
end

-- granulator particle sim for the PLAY page: mirrors the DSP's per-grain
-- laws exactly. Each spawn re-rolls time/size/pitch/shape through the
-- same per-trigger randomization as RandomizedParameter (amount > 0:
-- crossfade toward uniform, amount < 0: peaked near the knob), the read
-- point drifts through the loop at (playback_ratio - 1) loop-fractions
-- per second (pitch 0 = fixed reading point, pitch up = slides toward
-- older tape), and brightness follows the grain's own envelope (shape).
-- The record head stays static - tape frame.
-- (state vars declared at the top of the file)

local function randomized_value(base, amt, range, clamp01)
  if amt > 0 then
    if clamp01 then
      return util.clamp(base + (math.random() - base) * amt, 0, 1)
    end
    return base + (2 * math.random() - 1) * range * amt
  elseif amt < 0 then
    local blend = math.min(1, amt * math.random() * -3)
    if clamp01 then
      return util.clamp(base + (math.random() - base) * blend, 0, 1)
    end
    return base + (2 * math.random() - 1) * range * blend
  end
  return base
end

local function spawn_grain()
  if #grains >= 32 then return end   -- the DSP's grain pool (GranularPlayer<..., 32>)
  local buf_s = buf_seconds()
  local frozen = params:get("freeze") == 1
  local size_k = randomized_value(params:get("size"), params:get("size_amt"), 1, true)
  local dur = grain_dur_s(size_k)
  local pitch_st = randomized_value(params:get("pitch"), params:get("pitch_amt"), 24, false)
  local ratio = 2 ^ (pitch_st / 12)
  local rev = size_k < 1 / 3
  -- DelayGrain::Start: consumption = speed - (frozen and 0 or 1),
  -- speed = (rev and -1 or 1) * pitch_ratio. Trims mirror the DSP:
  -- duration capped so the sweep fits, start age clamped so the grain
  -- never crosses the recording head.
  local speed = rev and -ratio or ratio
  local c = speed - (frozen and 0 or 1)
  if c ~= 0 then
    dur = math.min(dur, buf_s / math.abs(c))
  end
  local a0 = randomized_value(params:get("time"), params:get("time_amt"), 1, true)
  local s = head_safety()
  a0 = s + a0 * (1 - 2 * s)
  if c > 0 then
    a0 = math.max(a0, c * dur / buf_s)
  elseif c < 0 then
    a0 = math.min(a0, 1 - math.abs(c) * dur / buf_s)
  end
  grains[#grains + 1] = {
    born = os.clock(),
    anchor = a0,       -- oldest material of the grain (loop fraction)
    dur = dur,
    ratio = ratio,
    rev = rev,
    shape = randomized_value(params:get("shape"), params:get("shape_amt"), 1, true),
  }
end

-- matrix-mod modulation on the seed param: an entry only counts while the
-- mapping still exists in the matrix table (matrix's unmap removes
-- self.matrix[src][param] but leaves the stale value in p.modulation)
local function seed_mod_compute(p)
  local m = p and p.modulation
  if not (m and mm_ok) then return false end
  for src_id, v in pairs(m) do
    local mapping = mm.matrix[src_id]
    if mapping and mapping[p.id] and (v or 0) > 0 then
      return true
    end
  end
  return false
end

local function seed_mod_apply(on)
  if on == seed_mod then return end
  seed_mod = on
  -- the DSP registers a tap on the gate's OFF->ON edge (one grain in the
  -- density deadband, tap tempo in delay mode) - mirror that
  if on and density_rate(params:get("density")) == 0 then
    spawn_grain()
  end
  pcall(function() engine.seed((seed_down or seed_mod) and 1 or 0) end)
  dirty = true
end

local function grain_sim_tick(dt, buf_s, frozen)
  -- wavetable synth: no tape, no grains to simulate
  if params:get("synth") == 2 then
    grains = {}
    return
  end
  local rate = density_rate(params:get("density"))
  if STATS.dmode < 0.5 then
    local latch = params:get("latch") == 1
    local clocked = params:get("sync") == 2
    if clocked then
      -- beats drive the seed input: latched = the clocked divider (density
      -- is the subdivision; above the deadband each beat passes with the
      -- divider probability), unlatched = every beat fires one seed, like
      -- triggers into the hardware SEED jack
      while pending_pulses > 0 do
        pending_pulses = pending_pulses - 1
        local d = params:get("density")
        if latch and d > 0.52 then
          local p = (d - 0.52) * 2.15
          if math.random() < p * p then spawn_grain() end
        else
          spawn_grain()
        end
      end
    end
    if rate > 0 and ((latch and not clocked) or seed_down or seed_mod) then
      -- free-running gate: latched without clock, or the seed button held
      spawn_acc = spawn_acc + rate * dt
      while spawn_acc >= 1 do
        spawn_acc = spawn_acc - 1
        spawn_grain()
      end
      if spawn_acc > 2 then spawn_acc = 2 end
    end
  else
    pending_pulses = 0   -- delay mode: the DSP's delay clock eats the beats
  end
  -- grain kinematics: the material span is glued to the tape (anchors
  -- recede at one loop per buf_s while the tape runs); a grain dies at
  -- the end of its duration or when its stylus hits the head (the DSP's
  -- HEAD_CROSSING_POLICY_STOP)
  local now = os.clock()
  for i = #grains, 1, -1 do
    local g = grains[i]
    local age = now - g.born
    local stylus = g.anchor + (g.rev and g.ratio or -g.ratio) * age / buf_s
    -- epsilon absorbs tick-timing jitter at the head edge (the safety
    -- zone keeps legit grains ~0.001 off the head)
    if age > g.dur or stylus < -0.005 or stylus > 1.005 then
      table.remove(grains, i)
    end
  end
  if not frozen then
    for _, g in ipairs(grains) do
      g.anchor = (g.anchor + dt / buf_s) % 1
    end
  end
end

local function header()
  -- one-line top bar: page name + state tags left, page dashes right
  screen.level(4)
  screen.move(0, 8)
  screen.text(pages[page])
  local tag = ""
  if params:get("freeze") == 1 then tag = tag .. " FRZ" end
  if STATS.dmode > 0.5 then tag = tag .. " DELAY" end
  if tape_playing then tag = tag .. " TAPE" end
  if seed_down then tag = tag .. " SEED" end  -- button only, not modulation
  if params:get("latch") == 1 and not seed_down then tag = tag .. " LATCH" end
  if params:get("sync") == 2 then tag = tag .. " CLK" end
  if params:get("synth") == 2 then tag = tag .. " SYN" end
  if #midi_stack > 0 then tag = tag .. " NOTE" end
  if tag ~= "" then
    screen.level(15)
    screen.move(24, 8)
    screen.text(tag)
  end
  -- square page dots anchored to the right edge so any page count fits
  -- (rect fill - immune to the round line caps the grain strokes need);
  -- vertically centered on the status text
  local x0 = 125 - #pages * 5
  for i = 1, #pages do
    screen.level(i == page and 15 or 2)
    screen.rect(x0 + (i - 1) * 5 + 1, 3.5, 3, 3)
    screen.fill()
  end
end

local function bar(x, y, w, v, level)
  screen.aa(0)
  screen.level(2)
  screen.rect(x, y, w, 5)
  screen.stroke()
  screen.level(level or 10)
  -- fill covers the top frame line (no dim gap row above it) and sits
  -- on the bottom line; whole pixels only
  screen.rect(x + 1, y, math.max(0, util.round((w - 2) * v)), 4)
  screen.fill()
end

-- bipolar bar for the amounts: center = 0, left/right = -1/+1
local function bar_bi(x, y, w, v, level)
  bar(x, y, w, 0, 1)   -- empty frame
  local c = x + w / 2
  screen.aa(0)
  screen.level(level or 10)
  local half = util.round((w / 2 - 1) * math.abs(v))
  if v >= 0 then
    screen.rect(c, y, half, 4)
  else
    screen.rect(c - half, y, half, 4)
  end
  screen.fill()
  screen.level(4)
  screen.move(c, y)
  screen.line(c, y + 4)
  screen.stroke()
end

function init()
  beadse.add_params()

  -- polls kept lean: reserve feeds the loop shading (8 Hz is plenty),
  -- dmode is a boolean mode flag (2 Hz). The write-position poll was
  -- dropped - nothing reads it since the static-head redesign.
  local p_reserve = poll.set("beads_reserve")
  p_reserve.callback = function(v)
    if math.abs(v - STATS.reserve) > 0.03 then
      STATS.reserve = v
      dirty = true
    end
  end
  p_reserve.time = 1 / 8
  p_reserve:start()

  local p_dmode = poll.set("beads_dmode")
  p_dmode.callback = function(v)
    if (v > 0.5) ~= (STATS.dmode > 0.5) then
      STATS.dmode = v
      dirty = true
    end
  end
  p_dmode.time = 1 / 2
  p_dmode:start()

  -- write-head phase = the tape splice: synced every 125 ms, dead-reckoned
  -- between polls at one loop per buf_s (frozen tape pauses it)
  local p_write = poll.set("beads_write")
  p_write.callback = function(v)
    seam_pos = v
    seam_have = true
  end
  p_write.time = 1 / 8
  p_write:start()

  -- tape-file player state (TAPE page rows + header tag)
  local p_bufplay = poll.set("beads_bufplay")
  p_bufplay.callback = function(v)
    local on = v > 0.5
    if on ~= tape_playing then
      tape_playing = on
      -- keep the tp_play param in step (silent: no action ping-pong)
      pcall(function() params:set("tp_play", on and 1 or 0, true) end)
      dirty = true
    end
  end
  p_bufplay.time = 1 / 2
  p_bufplay:start()

  -- hooks BEFORE params:bang() so the actions reach them at init
  beadse.on_seed = function(x)
    seed_down = x == 1
    -- deadband manual tap = one grain trigger
    if x == 1 and density_rate(params:get("density")) == 0 then
      spawn_grain()
    end
    -- the engine gate is the combined state: button OR matrix modulation
    pcall(function() engine.seed((seed_down or seed_mod) and 1 or 0) end)
    dirty = true
  end
  beadse.on_load_file = load_tape_file
  beadse.on_sync = function() start_sync() dirty = true end
  beadse.on_latch = function() start_sync() dirty = true end
  beadse.on_midi_pitch = function() push_pitch_cv() dirty = true end
  beadse.on_midi_cv = function() push_pitch_cv() dirty = true end
  beadse.on_media = function()
    -- buffer reset (media/mono Configure): no grains survive, splice
    -- re-syncs from the next poll
    grains = {}
    spawn_acc = 0
    pending_pulses = 0
    seam_have = false
    dirty = true
  end
  beadse.on_synth = function()
    -- wavetable synth: no tape, no grains, splice meaningless
    grains = {}
    seam_have = false
    dirty = true
  end

  -- The matrix mod drives a mapped param by updating its .modulation and
  -- deferring a CLASS bang - and Binary:bang fires action(self.value) with
  -- the raw user value (0), so the modulation would never open the seed
  -- gate (matrix patches number:bang but not binary:bang). Wrap the seed
  -- param's bang: recompute the modulation component (synchronous in
  -- matrix:set), then let the class bang run the action path, which pushes
  -- the combined gate. A low-rate poll in the redrawer catches unmapping
  -- while a gate is high (unmap fires no bang).
  local seed_param = params:lookup_param("seed_btn")
  local seed_class_bang = seed_param.bang
  seed_param.bang = function(self)
    seed_mod_apply(seed_mod_compute(self))
    seed_class_bang(self)
  end
  local function seed_mod_poll()
    seed_mod_apply(seed_mod_compute(seed_param))
  end

  params:default()
  params:bang()

  midi_connect_all()
  start_sync()

  redrawer = clock.run(function()
    local ticks = 0
    local last_tick = os.clock()
    while true do
      clock.sleep(1 / 15)
      ticks = ticks + 1
      if ticks % 30 == 0 then midi_connect_all() end
      sync_watchdog()
      seed_mod_poll()
      local now = os.clock()
      local dt = now - last_tick
      last_tick = now
      local buf_s = buf_seconds()
      local frozen = params:get("freeze") == 1
      if not frozen then
        -- tape runs: the splice advances one loop per buf_s (the reels
        -- are locked to it in redraw, so they advance with it)
        if seam_have then
          seam_pos = (seam_pos + dt / buf_s) % 1
        end
      end
      grain_sim_tick(dt, buf_s, frozen)
      -- PLAY page is live: grains spawn, drift and die continuously
      if page == 1 then dirty = true end
      -- debug helper: touch /tmp/dbgshot -> one screenshot to dust/data
      if ticks % 15 == 0 then
        local have = false
        pcall(function() have = util.file_exists("/tmp/dbgshot") end)
        if have then
          pcall(function() os.remove("/tmp/dbgshot") end)
          pcall(function() screen.export_screenshot("dbg") end)
        end
      end
      if dirty then
        dirty = false
        -- keep the loop alive through a bad frame (e.g. clock mid-change)
        local ok, err = pcall(redraw)
        if not ok then print("beads redraw: " .. tostring(err)) end
      end
    end
  end)
end

function cleanup()
  pcall(function() if redrawer then clock.cancel(redrawer) end end)
  pcall(stop_sync)
  pcall(function() engine.buffer_play(0) end)
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
    dirty = true
    return
  end
  if n == 4 then enc4_seen = true end
  local id, kind = enc_target(n)
  if id == nil then return end
  if kind == "d" or kind == "opt" then
    params:delta(id, d)
  elseif kind == "t2" then
    params:set(id, d > 0 and 2 or 1)
  elseif kind == "t01" then
    params:set(id, d > 0 and 1 or 0)
  elseif kind == "flip" then
    if d ~= 0 then params:set(id, params:get(id) == 1 and 0 or 1) end
  elseif kind == "subdiv" then
    sync_div_step(d > 0 and 1 or -1)
  end
  dirty = true
end

function key(n, z)
  if n == 1 then
    k1_down = z == 1
    dirty = true
    return
  end
  if n == 2 and page == 1 and z == 1 then
    -- freeze lives on the PLAY page only
    params:set("freeze", params:get("freeze") == 1 and 0 or 1)
    dirty = true
    return
  end
  if n == 3 then
    if page == 1 then
      if k1_down then
        -- K1 held + K3: toggle the seed latch (no seed while armed)
        if z == 1 then
          params:set("latch", params:get("latch") == 1 and 0 or 1)
          dirty = true
        end
      else
        -- seed lives on the PLAY page only (instant, as before)
        params:set("seed_btn", z)
        dirty = true
      end
    elseif page == 7 then
      -- TAPE page: K3 tap = play/stop (file browser is in the menu)
      if z == 1 then
        params:set("tp_play", params:get("tp_play") == 1 and 0 or 1)
        dirty = true
      end
    elseif z == 1 then
      -- quick tap = toggle this page's active pair bank
      if #PAGE_PARAMS[page] >= 3 then
        bank[page] = bank[page] == 1 and 2 or 1
        dirty = true
      end
    end
  end
end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  -- round joins/caps: the thick grain-span strokes wrap the pill's end
  -- caps - cairo's default miter join spikes there (jagged edges)
  screen.line_join("round")
  screen.line_cap("round")
  header()

  if page == 1 then
    -- values
    screen.level(4)
    screen.move(0, 18)
    screen.text("time")
    screen.level(15)
    screen.move(38, 18)
    screen.text(string.format("%.2f", params:get("time")))
    screen.level(4)
    screen.move(64, 18)
    screen.text("pitch")
    screen.level(15)
    screen.move(96, 18)
    screen.text(string.format("%+.1f st", params:get("pitch")))

    local bx, bw = 4, 120
    local cy, r = 37, 12   -- loop centered in the band between the values
                           -- row and the footer
    local L = bw - 2 * r
    local arc_len = math.pi * r
    local T = 2 * L + 2 * arc_len        -- loop perimeter
    local synth_mode = params:get("synth") == 2

    -- point on the pill loop, t in [0,1): clockwise from top-left
    local function loop_point(t)
      t = t - math.floor(t)
      local d = t * T
      if d < L then
        return bx + r + d, cy - r
      elseif d < L + arc_len then
        local a = (d - L) / arc_len * math.pi - math.pi / 2
        return bx + bw - r + r * math.cos(a), cy + r * math.sin(a)
      elseif d < 2 * L + arc_len then
        return bx + bw - r - (d - L - arc_len), cy + r
      else
        local a = (d - 2 * L - arc_len) / arc_len * math.pi + math.pi / 2
        return bx + r + r * math.cos(a), cy + r * math.sin(a)
      end
    end

    -- the loop: 1px outline, shaded by overwrite reserve (dims as the
    -- head approaches unrecorded tape); drawn WITHOUT anti-aliasing -
    -- AA spread the arcs across two pixel rows and the rounded sides
    -- read brighter than the straight lines; in wavetable synth mode
    -- there is no tape - the transport view is replaced by synth status
    if not synth_mode then
    screen.aa(1)
    screen.line_width(1)
    screen.level(2 + math.floor(STATS.reserve * 4))
    local segs = 96
    local x0, y0 = loop_point(0)
    screen.move(x0, y0)
    for i = 1, segs do
      local x, y = loop_point(i / segs)
      screen.line(x, y)
    end
    screen.stroke()
    screen.aa(1)

    -- the record head is a FIXED caret (^) centered on the top of the
    -- loop; the tape moves past it. Grain/read positions are drawn as
    -- fixed offsets from the head along the loop - static until a
    -- parameter changes, nothing animates on its own
    local HEAD_T = L / (2 * T)   -- midpoint of the top straight

    -- a grain is a trimmed segment of a second 3px stroke on the same
    -- path: sample the loop between q-d and q+d so the dash follows the
    -- curve (no rotating chords)
    local function path_stroke(q, len_px, level)
      local d = (len_px / 2) / T
      local steps = math.max(3, math.min(48, math.floor(len_px / 2)))
      screen.line_width(3)
      screen.level(level)
      local x, y = loop_point(q - d)
      screen.move(x, y)
      for i = 1, steps do
        local px, py = loop_point(q - d + (2 * d) * i / steps)
        screen.line(px, py)
      end
      screen.stroke()
      screen.line_width(1)
    end

    local now = os.clock()

    -- transport reels: a 6-notch hub in each end cap, PHASE-LOCKED to the
    -- tape splice - one rotation per splice revolution, notch pointing up
    -- when the splice passes the head, counterclockwise (tape direction);
    -- frozen tape = stopped reels (they share the splice's phase)
    local tape_rot = seam_have and (2 * math.pi * seam_pos) or 0
    local function draw_reel(cx0, cy0)
      local rr = 7
      screen.level(4)
      screen.move(cx0 + rr, cy0)
      for i = 1, 20 do
        local a = i / 20 * 2 * math.pi
        screen.line(cx0 + rr * math.cos(a), cy0 + rr * math.sin(a))
      end
      screen.stroke()
      screen.level(9)
      for k = 0, 5 do
        local a = k * math.pi / 3 - math.pi / 2 - tape_rot
        screen.move(cx0 + (rr - 2.5) * math.cos(a), cy0 + (rr - 2.5) * math.sin(a))
        screen.line(cx0 + (rr - 0.5) * math.cos(a), cy0 + (rr - 0.5) * math.sin(a))
      end
      screen.stroke()
    end
    draw_reel(bx + r, cy)
    draw_reel(bx + bw - r, cy)

    if STATS.dmode > 0.5 then
      -- tape mode: read position with regen echoes trailing behind
      local base = (HEAD_T - params:get("time")) % 1
      for i = 3, 0, -1 do
        path_stroke(base + i * 0.09, 5, 15 - i * 4)
      end
    else
      -- live grains, exact geometry: a grain's material span is
      -- ratio x duration of tape, GLUED TO THE LOOP (the anchor recedes
      -- with the tape like the splice), extending toward newer material
      -- for forward grains, older for reverse; the stylus (bright pixel)
      -- sweeps the span at the playback ratio. Brightness = envelope.
      local buf_s = buf_seconds()
      for _, g in ipairs(grains) do
        local age = now - g.born
        local t = age / g.dur
        if t < 1 then
          local env = envelope_point(g.shape, t)
          if env > 0.02 then
            local dir = g.rev and -1 or 1
            local span_frac = math.min(g.ratio * g.dur / buf_s, 1)
            local anchor_t = (HEAD_T - g.anchor) % 1
            local center_t = anchor_t + dir * span_frac / 2
            path_stroke(center_t % 1, span_frac * T,
                        math.max(1, math.floor((g.rev and 6 or 12) * env)))
            local stylus_t = (anchor_t + dir * g.ratio * age / buf_s) % 1
            local sx, sy = loop_point(stylus_t)
            screen.level(math.floor(6 + 9 * env))
            screen.rect(util.round(sx), util.round(sy), 1, 1)
            screen.fill()
          end
        end
      end
      -- live rate + count, drawn separately at fixed RIGHT anchors: the
      -- the font's "1" glyph is narrower than other digits, so ANY text
      -- combining number+label shifts when digits change. Numbers and
      -- labels are therefore separate draws with hard-pinned anchors:
      -- numbers right-aligned at a fixed edge (grow leftward), labels
      -- left-aligned at a fixed x. Nothing on screen can move.
      local d = params:get("density")
      local rate_hz = density_rate(d)
      screen.level(#grains > 0 and 15 or 4)
      if params:get("sync") == 2 or rate_hz <= 0 then
        screen.move(bx + 60, cy + 3)
        screen.text(string.format("%d", #grains))
        screen.move(bx + 72, cy + 3)
        screen.text("grains")
      else
        screen.move(bx + 26, cy + 3)
        screen.text(string.format("%d", math.floor(rate_hz + 0.5)))
        screen.move(bx + 41, cy + 3)
        screen.text("Hz")
        screen.move(bx + 60, cy + 3)
        screen.text(string.format("%d", #grains))
        screen.move(bx + 72, cy + 3)
        screen.text("grains")
      end
    end

    -- the static record head: a ^ caret sitting on the loop
    local hx, hy = loop_point(HEAD_T)
    screen.level(15)
    screen.move(hx - 3, hy + 5)
    screen.line(hx, hy + 1)
    screen.line(hx + 3, hy + 5)
    screen.stroke()
    screen.aa(0)

    -- the tape splice (buffer seam): a 1px material point riding the
    -- tape - one revolution per buffer length, paused while frozen
    if seam_have then
      local sx, sy = loop_point((HEAD_T - seam_pos) % 1)
      screen.level(15)
      screen.rect(util.round(sx), util.round(sy), 1, 1)
      screen.fill()
    end
    else
      -- wavetable synth: no tape to draw
      screen.level(15)
      screen.move(bx + bw / 2, cy - 2)
      screen.text_center("SYNTH")
      screen.level(9)
      screen.move(bx + bw / 2, cy + 10)
      screen.text_center("bank " .. bank_num() .. "/12")
    end

    -- footer: quality + rate + resolution + buffer length (the manual's
    -- media table; buffer seconds follow the channels setting)
    local m = params:get("media")
    local rate = ({ 24, 24, 32, 48 })[m]
    local res = ({ 8, 12, 12, 16 })[m]
    local buf = buf_seconds()
    local buf_txt = (buf == math.floor(buf)) and string.format("%d", buf)
        or string.format("%.1f", buf)
    screen.level(4)
    screen.move(0, 62)
    screen.text(MEDIA_SHORT[m] .. " " .. rate .. "k " .. res .. "b " ..
      buf_txt .. "s")
  elseif page == 2 then
    -- BOTH pairs stay on screen: density/size above the envelope,
    -- shape/shape amount below it - K3 only moves the editing highlight
    local gtop = {
      { "dens", function() return density_string(params:get("density")) end },
      { "size", function() return string.format("%.2f", params:get("size")) end },
    }
    local gbot = {
      { "env", function() return string.format("%.2f", params:get("shape")) end },
      { "s.amt", function() return string.format("%+.2f", params:get("shape_amt")) end },
    }
    -- 20% side padding; dim while the other pair is being edited
    draw_envelope(26, 22, 76, 20, params:get("shape"),
      bank[2] == 2 and 12 or 3)
    for col = 1, 2 do
      local x = col == 1 and 0 or 64
      local vx = col == 1 and 30 or 90
      local t_active = bank[2] == 1
      screen.level(t_active and 12 or 3)
      screen.move(x, 18)
      screen.text(gtop[col][1])
      screen.level(t_active and 15 or 4)
      screen.move(vx, 18)
      screen.text(gtop[col][2]())
      screen.level(bank[2] == 2 and 12 or 3)
      screen.move(x, 52)
      screen.text(gbot[col][1])
      screen.level(bank[2] == 2 and 15 or 4)
      screen.move(vx, 52)
      screen.text(gbot[col][2]())
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K3: toggle param")
  elseif page == 3 then
    -- RANDOM: all four attenurandomizers (the pitch amount row edits the
    -- same param as PLAY E4)
    local rows = {
      { "time", params:get("time_amt") },
      { "size", params:get("size_amt") },
      { "shape", params:get("shape_amt") },
      { "pitch", params:get("pitch_amt") },
    }
    for i, r in ipairs(rows) do
      local y = row_y(i, #rows)
      local active = row_active(i)
      screen.level(active and 12 or 3)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(active and 15 or 4)
      screen.move(34, y)
      screen.text(string.format("%+.2f", r[2]))
      bar_bi(64, y - 5, 60, r[2], active and 15 or 4)
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K3: toggle param")
  elseif page == 4 then
    local rows = {
      { "feedback", params:get("feedback") },
      { "reverb", params:get("rvb") },
      { "dry/wet", params:get("drywet") },
      { "in gain", params:get("gain") / 255 },
    }
    for i, r in ipairs(rows) do
      local y = row_y(i, #rows)
      local active = row_active(i)
      screen.level(active and 12 or 3)
      screen.move(0, y)
      screen.text(r[1])
      bar(58, y - 5, 66, r[2], active and 15 or 4)
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K3: toggle param")
  elseif page == 5 then
    -- CLOCK
    local rows = {
      { "sync", params:get("sync") == 2
          and (string.format("%d", math.floor(safe_bpm() + 0.5)) .. " bpm")
          or "off" },
      { "subdiv", sync_div_label() },
      { "latch", params:get("latch") == 1 and "on (free run)" or "off (trig)" },
    }
    for i, r in ipairs(rows) do
      local y = row_y(i, #rows)
      local active = row_active(i)
      screen.level(active and 12 or 3)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(active and 15 or 4)
      screen.move(54, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K3: toggle param")
  elseif page == 6 then
    -- SETUP
    local rows = {
      { "media", beadse.media_name(params:get("media")) },
      { "chans", params:get("mono") == 2 and "mono" or "stereo" },
    }
    for i, r in ipairs(rows) do
      local y = row_y(i, #rows)
      local active = row_active(i)
      screen.level(active and 12 or 3)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(active and 15 or 4)
      screen.move(52, y)
      screen.text(r[2])
    end
  elseif page == 7 then
    -- TAPE: file player feeding the granulator input
    local rows = {
      { "level", string.format("%.2fx", params:get("tp_level")) },
      { "loop", params:get("tp_loop") == 2 and "loop" or "once" },
      { "play", tape_playing and "playing" or "stopped" },
    }
    for i, r in ipairs(rows) do
      local y = row_y(i, 4)   -- 4-line spacing: the file name is line 4
      local active = row_active(i)
      screen.level(active and 12 or 3)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(active and 15 or 4)
      screen.move(52, y)
      screen.text(r[2])
    end
    if tape_name ~= "" then
      screen.level(4)
      screen.move(0, row_y(4, 4))
      local nm = tape_name
      if #nm > 25 then nm = ".." .. string.sub(nm, -23) end
      screen.text(nm)
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K3 play  file: menu")
  elseif page == 8 then
    -- MIDI: notes stand in for the hardware PITCH CV jack
    local ref = params:get("midi_ref")
    local rows = {
      { "note pitch", params:get("midi_pitch") == 2 and "on" or "off" },
      { "ref note", musicutil.note_num_to_name(ref) },
      { "bend range", params:get("midi_bend") == 0 and "off"
          or (params:get("midi_bend") .. " st") },
    }
    for i, r in ipairs(rows) do
      local y = row_y(i, #rows)
      local active = row_active(i)
      screen.level(active and 12 or 3)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(active and 15 or 4)
      screen.move(68, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    if params:get("midi_pitch") == 2 then
      local active = last_note and musicutil.note_num_to_name(last_note) or "-"
      screen.text("cv " .. string.format("%+.1f st", last_cv_sent or 0) ..
        "  " .. active)
    else
      screen.text("off - depth on PLAY")
    end
  else
    -- SYNTH: wavetable synth mode, bank (= FEEDBACK), gate out
    local rows = {
      { "synth", params:get("synth") == 2 and "on" or "off" },
      { "bank", bank_num() .. "/12" },
      { "gate out", params:get("gate") == 2 and "on" or "off" },
    }
    for i, r in ipairs(rows) do
      local y = row_y(i, #rows)
      local active = row_active(i)
      screen.level(active and 12 or 3)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(active and 15 or 4)
      screen.move(68, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K3: toggle param")
  end

  screen.update()
end
