-- beads
--
-- Mutable Instruments Beads for norns.
-- Granular delay / looper - a port of the eurorack module's DSP
-- (Emilie Gillet, MIT) as a SuperCollider UGen + CroneEngine.
--
-- E1 page  E2/E3/E4 = the page's three parameters (K1 held = amount layer)
-- K2 freeze   K3 seed (hold K1+K3 = seed latch)
--
-- pages:
--   PLAY  E2 time   (alt: time amt)    E3 pitch (alt: pitch amt)  E4 dry/wet
--   GRAIN E2 density (alt: size amt)   E3 size  (alt: shape amt)  E4 shape
--   MIX   E2 feedback   E3 reverb   E4 input gain
--   SETUP E2 media   E3 channels  E4 clock sync (norns bpm -> seed clock)
--
-- clock sync (SETUP E4, needs latch on): delay mode tempo = norns bpm x
-- DENSITY subdivision; granular mode = clocked divider (hardware SEED-jack
-- clocking)
--
-- all params (incl. freeze/latch) live in the PARAMS menu; MIDI mapping
-- works there like any norns script.

engine.name = "Beads"

local beadse = include "lib/beads_engine"

local STATS = { reserve = 1.0, write = 0.0, dmode = 0.0 }

local pages = { "PLAY", "GRAIN", "MIX", "SETUP" }
local page = 1
local alt = false
local seed_down = false
local dirty = true
local redrawer

local W, H = 128, 64

-- clock sync: one engine seed pulse per norns-system beat engages the DSP's
-- clocked paths (delay tempo = beat x density subdivision; granular divider)
local sync_clock

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
    sync_clock = clock.run(function()
      while true do
        clock.sleep(60 / clock.get_bpm())
        engine.clock()
      end
    end)
  end
end


-- grain envelope preview, mirroring beads' grain_envelope.h
local function envelope_point(s, t)
  local sustain = math.max(1 - 3 * s, 0)
  local a = math.max(0, (s - 1 / 3) * 1.5)
  if a < 0.5 then a = a * a * a * 4 end
  local release = (1 - a) * (1 - sustain)
  local norm = a + sustain + release
  if norm <= 0 then return 0 end
  a, sustain = a / norm, sustain / norm
  local smoothness = a < 0.5 and (2 * a) or (2 - 2 * a)
  if t < a then
    local x = t / a
    return x + (x * x * (3 - 2 * x) - x) * smoothness
  elseif t < a + sustain then
    return 1
  else
    local x = (t - a - sustain) / math.max(release / norm, 0.0001)
    x = math.min(x, 1)
    local x4 = x * x * x * x
    return x4 + (x * x * (3 - 2 * x) - x4) * smoothness
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

local function density_string(d)
  if d < 0.48 then
    return string.format("%d hz", math.floor(130.81 * 2 ^ (-16 * d) + 0.5))
  elseif d > 0.52 then
    return string.format("~%d hz", math.floor(0.5 * 130.81 * 2 ^ (-16 * (1 - d)) + 0.5))
  end
  -- deadband: latched = no grains (manual), unlatched = manual taps
  return params:get("latch") == 1 and "silent" or "tap"
end

local function header()
  -- one-line top bar: page name + state tags left, page dashes right
  screen.level(alt and 15 or 4)
  screen.move(0, 8)
  screen.text(alt and pages[page] .. "+" or pages[page])
  local tag = ""
  if params:get("freeze") == 1 then tag = tag .. " FRZ" end
  if STATS.dmode > 0.5 then tag = tag .. " TAPE" end
  if seed_down then tag = tag .. " SEED" end
  if params:get("latch") == 1 then tag = tag .. " LATCH" end
  if params:get("sync") == 2 then tag = tag .. " CLK" end
  if tag ~= "" then
    screen.level(15)
    screen.move(32, 8)
    screen.text(tag)
  end
  for i = 1, #pages do
    screen.move(112 + (i - 1) * 5, 8)
    screen.line_rel(3, 0)
    screen.line_width(3)
    screen.level(i == page and 15 or 2)
    screen.stroke()
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

function init()
  beadse.add_params()

  local p_reserve = poll.set("beads_reserve")
  p_reserve.callback = function(v)
    if math.abs(v - STATS.reserve) > 0.03 then
      STATS.reserve = v
      dirty = true
    end
  end
  p_reserve.time = 1 / 15
  p_reserve:start()

  local p_write = poll.set("beads_write")
  p_write.callback = function(v)
    if math.abs(v - STATS.write) > 0.008 then
      STATS.write = v
      dirty = true
    end
  end
  p_write.time = 1 / 15
  p_write:start()

  local p_dmode = poll.set("beads_dmode")
  p_dmode.callback = function(v)
    if (v > 0.5) ~= (STATS.dmode > 0.5) then
      STATS.dmode = v
      dirty = true
    end
  end
  p_dmode.time = 1 / 15
  p_dmode:start()

  params:default()
  params:bang()

  beadse.on_sync = function() start_sync() dirty = true end
  beadse.on_latch = function() start_sync() dirty = true end
  start_sync()

  redrawer = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      if dirty then
        dirty = false
        redraw()
      end
    end
  end)
end

function cleanup()
  if redrawer then clock.cancel(redrawer) end
  stop_sync()
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
    dirty = true
    return
  end
  if n == 4 then
    -- Fates 4th knob: this page's third parameter
    local p = { "drywet", "shape", "gain" }
    if page < 4 then
      params:delta(p[page], d)
    elseif d > 0 then
      params:set("sync", params:get("sync") == 2 and 1 or 2)
    end
    dirty = true
    return
  end
  local target
  if page == 1 then
    target = (n == 2)
        and (alt and "time_amt" or "time")
        or (alt and "pitch_amt" or "pitch")
  elseif page == 2 then
    target = (n == 2)
        and (alt and "size_amt" or "density")
        or (alt and "shape_amt" or "size")
  elseif page == 3 then
    target = (n == 2) and "feedback" or "reverb"
  else
    target = (n == 2) and "media" or "mono"
  end
  params:delta(target, d)
  dirty = true
end

function key(n, z)
  if n == 1 then
    alt = z == 1
    dirty = true
  elseif n == 2 and z == 1 then
    params:set("freeze", params:get("freeze") == 1 and 0 or 1)
    dirty = true
  elseif n == 3 then
    if alt and z == 1 then
      params:set("latch", params:get("latch") == 1 and 0 or 1)
    else
      seed_down = z == 1
      engine.seed(z)
    end
    dirty = true
  end
end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  header()

  if page == 1 then
    -- tape bar
    local bx, by, bw, bh = 4, 42, 120, 6
    bar(bx, by, bw, 1, 1 + math.floor(STATS.reserve * 5))
    -- grain position marker (time)
    local tx = bx + params:get("time") * bw
    screen.level(15)
    screen.move(tx, by - 2)
    screen.line(tx, by + bh + 2)
    screen.stroke()
    -- write head triangle
    local wx = bx + STATS.write * bw
    screen.level(12)
    screen.move(wx - 2, by + bh + 2)
    screen.line(wx, by + bh + 6)
    screen.line(wx + 2, by + bh + 2)
    screen.close()
    screen.fill()
    -- values
    screen.level(4)
    screen.move(0, 24)
    screen.text("time")
    screen.level(15)
    screen.move(38, 24)
    screen.text(string.format("%.2f", params:get("time")))
    screen.level(4)
    screen.move(64, 24)
    screen.text("pitch")
    screen.level(15)
    screen.move(96, 24)
    screen.text(string.format("%+.1f st", params:get("pitch")))
    -- footer
    screen.level(4)
    screen.move(0, 62)
    screen.text(beadse.media_name(params:get("media")) .. "  " ..
      density_string(params:get("density")) ..
      "  dw " .. string.format("%.2f", params:get("drywet")))
  elseif page == 2 then
    draw_envelope(4, 26, 119, 26, params:get("shape"))
    screen.level(4)
    screen.move(0, 20)
    screen.text("dens")
    screen.level(15)
    screen.move(30, 20)
    screen.text(density_string(params:get("density")))
    screen.level(4)
    screen.move(64, 20)
    screen.text("size")
    screen.level(15)
    screen.move(90, 20)
    screen.text(string.format("%.2f", params:get("size")))
    screen.level(4)
    screen.move(0, 62)
    if alt then
      screen.text("alt e2 size amt  alt e3 shape amt")
    else
      screen.text("envelope - E4 shape " ..
        string.format("%.2f", params:get("shape")))
    end
  elseif page == 3 then
    local rows = {
      { "E2 feedback", params:get("feedback") },
      { "E3 reverb", params:get("reverb") },
      { "E4 in gain", (params:get("gain") - 0.25) / 3.75 },
    }
    for i, r in ipairs(rows) do
      local y = 26 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      bar(58, y - 5, 66, r[2], 10)
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K1 hold = alt layer on PLAY/GRAIN")
  else
    local rows = {
      { "E2 media", beadse.media_name(params:get("media")) },
      { "E3 chans", params:get("mono") == 2 and "mono" or "stereo" },
      { "E4 sync", params:get("sync") == 2
          and ("bpm " .. string.format("%d", math.floor(clock.get_bpm() + 0.5)))
          or "off" },
    }
    for i, r in ipairs(rows) do
      local y = 26 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(15)
      screen.move(46, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K2 freeze  K3 seed  K1+K3 latch")
  end

  screen.update()
end
