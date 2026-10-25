-- beads
--
-- Mutable Instruments Beads for norns.
-- Granular delay / looper - a port of the eurorack module's DSP
-- (Emilie Gillet, MIT) as a SuperCollider UGen + CroneEngine.
--
-- E1 page  E2/E3/E4 = the page's three parameters (no modifier layers,
-- K1 untouched - it is the system menu key)
-- K2 freeze   K3 seed
--
-- pages:
--   PLAY   E2 time    E3 pitch         E4 pitch amount
--   GRAIN  E2 density E3 size          E4 shape
--   RANDOM E2 time amt   E3 size amt   E4 shape amt   (attenurandomizers)
--   MIX    E2 feedback   E3 reverb     E4 dry/wet
--   CLOCK  E2 sync    E3 subdivision  E4 seed latch
--   SETUP  E2 media   E3 channels      E4 input gain
--   MIDI   E2 note pitch E3 ref note   E4 bend range
--
-- MIDI note pitch = the hardware PITCH CV jack: notes (last-note priority,
-- held on release) transpose by (note - ref) semitones; PLAY E4 "pitch
-- amount" is the CV depth, like the module's PITCH AMOUNT knob.
--
-- amounts (RANDOM page): positive = spray the param toward random per grain
-- (pitch: +-24 st), negative = peak near the knob value, 0 = off
--
-- clock sync (needs latch on): delay mode tempo = norns bpm x subdivision;
-- granular mode = clocked divider (hardware SEED-jack clocking)
--
-- all params (incl. freeze/latch) live in the PARAMS menu; MIDI mapping
-- works there like any norns script.

engine.name = "Beads"

local beadse = include "lib/beads_engine"
local musicutil = require "musicutil"

local STATS = { reserve = 1.0, dmode = 0.0 }

local pages = { "PLAY", "GRAIN", "RANDOM", "MIX", "CLOCK", "SETUP", "MIDI" }
local page = 1
local seed_down = false
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

local W, H = 128, 64

-- clocked-mode subdivisions: in clocked delay/granular the DENSITY knob
-- walks the DSP's ratio table (1/16..1/1 below center, beat multiples
-- above). These targets address its slots directly; the MIX page exposes
-- them as a setting while sync is on (K1 tap to cycle).
local SYNC_DIVS = {
  { "1/16", 0.025 }, { "1/8", 0.125 }, { "1/4", 0.225 }, { "1/2", 0.35 },
  { "1", 0.46 },
  { "x2", 0.60 }, { "x3", 0.65 }, { "x4", 0.70 }, { "x6", 0.75 },
  { "x8", 0.80 }, { "x12", 0.90 }, { "x16", 0.97 },
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
  -- clocked SEED behavior needs the latch on, like the hardware
  if params:get("sync") == 2 and params:get("latch") == 1 then
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
  if params:get("sync") == 2 and params:get("latch") == 1 then
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

local function draw_envelope(x0, y0, w, h, s)
  local n = 48
  screen.aa(1)
  screen.line_width(1.5)
  screen.move(x0, y0 + h)
  for i = 0, n do
    local t = i / n
    local v = envelope_point(s, t)
    screen.line(x0 + t * w, y0 + h - v * h)
  end
  screen.level(10)
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
  local r = density_rate(d)
  if r > 0 then
    return string.format("%s%d hz", d > 0.52 and "~" or "", math.floor(r + 0.5))
  end
  -- deadband: latched = no grains (manual), unlatched = manual taps
  return params:get("latch") == 1 and "silent" or "tap"
end

-- exact expected concurrent grain count (rate x duration), printed in
-- the loop - no ">12" fallback, the number is always real
local function n_exp_grains(rate, dur)
  local n = rate > 0 and math.floor(rate * dur + 0.5) or 0
  return n .. " grains"
end

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
  if #grains >= 16 then return end
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

local function grain_sim_tick(dt, buf_s, frozen)
  local rate = density_rate(params:get("density"))
  if STATS.dmode < 0.5 and rate > 0
      and (params:get("latch") == 1 or seed_down) then
    if params:get("sync") == 2 and params:get("latch") == 1 then
      -- clocked divider: one trigger opportunity per received beat,
      -- gated by the density probability above the deadband
      while pending_pulses > 0 do
        pending_pulses = pending_pulses - 1
        local d = params:get("density")
        if d > 0.52 then
          local p = (d - 0.52) * 2.15
          if math.random() < p * p then spawn_grain() end
        else
          spawn_grain()
        end
      end
    else
      spawn_acc = spawn_acc + rate * dt
      while spawn_acc >= 1 do
        spawn_acc = spawn_acc - 1
        spawn_grain()
      end
      if spawn_acc > 2 then spawn_acc = 2 end
    end
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
  if STATS.dmode > 0.5 then tag = tag .. " TAPE" end
  if seed_down then tag = tag .. " SEED" end
  if params:get("latch") == 1 then tag = tag .. " LATCH" end
  if params:get("sync") == 2 then tag = tag .. " CLK" end
  if #midi_stack > 0 then tag = tag .. " NOTE" end
  if tag ~= "" then
    screen.level(15)
    screen.move(32, 8)
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
  screen.level(2)
  screen.rect(x, y, w, 5)
  screen.stroke()
  screen.level(level or 10)
  screen.rect(x + 1, y + 1, math.max(0, (w - 2) * v), 3)
  screen.fill()
end

-- bipolar bar for the amounts: center = 0, left/right = -1/+1
local function bar_bi(x, y, w, v, level)
  bar(x, y, w, 0, 1)   -- empty frame
  local c = x + w / 2
  screen.level(level or 10)
  if v >= 0 then
    screen.rect(c, y + 1, (w / 2 - 1) * v, 3)
  else
    screen.rect(c + (w / 2 - 1) * v, y + 1, -(w / 2 - 1) * v, 3)
  end
  screen.fill()
  screen.level(4)
  screen.move(c, y - 1)
  screen.line(c, y + 6)
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

  params:default()
  params:bang()

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
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
    dirty = true
    return
  end
  if page == 5 then
    -- CLOCK: E2 sync on/off, E3 subdivision, E4 seed latch
    if n == 2 then
      params:set("sync", d > 0 and 2 or 1)
    elseif n == 3 then
      sync_div_step(d > 0 and 1 or -1)
    elseif d > 0 then
      params:set("latch", 1)
    else
      params:set("latch", 0)
    end
    dirty = true
    return
  end
  if page == 7 then
    -- MIDI: E2 note pitch, E3 reference note, E4 bend range
    if n == 2 then
      params:set("midi_pitch", d > 0 and 2 or 1)
    elseif n == 3 then
      params:delta("midi_ref", d)
    elseif n == 4 then
      params:delta("midi_bend", d)
    end
    dirty = true
    return
  end
  local e2 = { "time", "density", "time_amt", "feedback", nil, "media" }
  local e3 = { "pitch", "size", "size_amt", "rvb", nil, "mono" }
  local e4 = { "pitch_amt", "shape", "shape_amt", "drywet", nil, "gain" }
  local t = n == 2 and e2[page] or (n == 3 and e3[page] or e4[page])
  if t then params:delta(t, d) end
  dirty = true
end

function key(n, z)
  if n == 2 and z == 1 then
    params:set("freeze", params:get("freeze") == 1 and 0 or 1)
    dirty = true
  elseif n == 3 then
    seed_down = z == 1
    engine.seed(z)
    -- deadband manual tap = one grain trigger
    if z == 1 and density_rate(params:get("density")) == 0 then
      spawn_grain()
    end
    dirty = true
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

    -- the loop: 1px outline (aa'd sampled path), shaded by overwrite
    -- reserve (dims as the head approaches unrecorded tape)
    screen.aa(1)
    screen.line_width(1)
    screen.level(2 + math.floor(STATS.reserve * 4))
    local segs = 48
    local x0, y0 = loop_point(0)
    screen.move(x0, y0)
    for i = 1, segs do
      local x, y = loop_point(i / segs)
      screen.line(x, y)
    end
    screen.stroke()

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

    local rate = density_rate(params:get("density"))
    local dur = grain_dur_s(params:get("size"))
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
      local drawn = 0
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
            drawn = drawn + 1
          end
        end
      end
      -- exact expected concurrent count, centered in the loop
      screen.level(drawn > 0 and 15 or 4)
      screen.move(bx + bw / 2, cy + 3)
      screen.text_center(n_exp_grains(rate, dur))
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

    -- footer
    screen.level(4)
    screen.move(0, 62)
    screen.text(beadse.media_name(params:get("media")) .. "  " ..
      density_string(params:get("density")) ..
      "  p.amt " .. string.format("%+.2f", params:get("pitch_amt")))
  elseif page == 2 then
    draw_envelope(4, 22, 119, 26, params:get("shape"))
    screen.level(4)
    screen.move(0, 18)
    screen.text("dens")
    screen.level(15)
    screen.move(30, 18)
    screen.text(density_string(params:get("density")))
    screen.level(4)
    screen.move(64, 18)
    screen.text("size")
    screen.level(15)
    screen.move(90, 18)
    screen.text(string.format("%.2f", params:get("size")))
    screen.level(4)
    screen.move(0, 62)
    if params:get("sync") == 2 and params:get("latch") == 1 then
      -- clocked: density IS the subdivision (E2 edits it here too)
      screen.text("envelope - E4 shape " ..
        string.format("%.2f", params:get("shape")) ..
        "  E2 div " .. sync_div_label())
    else
      screen.text("envelope - E4 shape " ..
        string.format("%.2f", params:get("shape")) ..
        (params:get("size") < 1 / 3 and "  rev" or
          (params:get("size") > 0.99 and "  delay" or "")))
    end
  elseif page == 3 then
    -- RANDOM: the four attenurandomizers (pitch amt lives on PLAY E4)
    local rows = {
      { "E2 time amt", params:get("time_amt") },
      { "E3 size amt", params:get("size_amt") },
      { "E4 shape amt", params:get("shape_amt") },
    }
    for i, r in ipairs(rows) do
      local y = 22 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      bar_bi(64, y - 5, 60, r[2], 10)
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("0=off  +=random  -=peaked (per grain)")
  elseif page == 4 then
    local rows = {
      { "E2 feedback", params:get("feedback") },
      { "E3 reverb", params:get("rvb") },
      { "E4 dry/wet", params:get("drywet") },
    }
    for i, r in ipairs(rows) do
      local y = 22 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      bar(58, y - 5, 66, r[2], 10)
    end
    screen.level(4)
    screen.move(0, 62)
    if params:get("sync") == 2 then
      screen.text("delay = " ..
        string.format("%d", math.floor(safe_bpm() + 0.5)) ..
        " bpm x " .. sync_div_label() .. "  (CLOCK)")
    else
      screen.text("clock settings on CLOCK page")
    end
  elseif page == 5 then
    -- CLOCK
    local rows = {
      { "E2 sync", params:get("sync") == 2
          and (string.format("%d", math.floor(safe_bpm() + 0.5)) .. " bpm")
          or "off" },
      { "E3 subdiv", sync_div_label() },
      { "E4 latch", params:get("latch") == 1 and "on (free run)" or "off (gated)" },
    }
    for i, r in ipairs(rows) do
      local y = 22 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(15)
      screen.move(54, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("sync needs latch; delay mode: size to max")
  elseif page == 6 then
    -- SETUP
    local rows = {
      { "E2 media", beadse.media_name(params:get("media")) },
      { "E3 chans", params:get("mono") == 2 and "mono" or "stereo" },
      { "E4 in gain", string.format("%.2fx", params:get("gain")) },
    }
    for i, r in ipairs(rows) do
      local y = 22 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(15)
      screen.move(52, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K2 freeze  K3 seed  clock: CLOCK page")
  else
    -- MIDI: notes stand in for the hardware PITCH CV jack
    local ref = params:get("midi_ref")
    local rows = {
      { "E2 note pitch", params:get("midi_pitch") == 2 and "on" or "off" },
      { "E3 ref note", musicutil.note_num_to_name(ref) },
      { "E4 bend range", params:get("midi_bend") == 0 and "off"
          or (params:get("midi_bend") .. " st") },
    }
    for i, r in ipairs(rows) do
      local y = 22 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(15)
      screen.move(68, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    if params:get("midi_pitch") == 2 then
      local active = last_note and musicutil.note_num_to_name(last_note) or "-"
      screen.text("cv " .. string.format("%+.1f st", last_cv_sent or 0) ..
        "  " .. active .. "  depth: PLAY p.amt")
    else
      screen.text("off - depth lives on PLAY p.amt")
    end
  end

  screen.update()
end
