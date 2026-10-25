-- beads
--
-- Mutable Instruments Beads for norns.
-- Granular delay / looper - a port of the eurorack module's DSP
-- (Emilie Gillet, MIT) as a SuperCollider UGen + CroneEngine.
--
-- E1 page  E2/E3/E4 = the page's three parameters (no modifier layers)
-- K2 freeze   K3 seed   K1+K3 seed latch   K1+K2 clock sync
--
-- pages:
--   PLAY   E2 time    E3 pitch         E4 pitch amount
--   GRAIN  E2 density E3 size          E4 shape
--   RANDOM E2 time amt   E3 size amt   E4 shape amt   (attenurandomizers)
--   MIX    E2 feedback   E3 reverb     E4 dry/wet
--   SETUP  E2 media   E3 channels      E4 input gain
--
-- amounts (RANDOM page): positive = spray the param toward random per grain
-- (pitch: +-24 st), negative = peak near the knob value, 0 = off
--
-- clock sync (K1+K2, needs latch on): delay mode tempo = norns bpm x
-- DENSITY subdivision; granular mode = clocked divider (hardware SEED-jack
-- clocking)
--
-- all params (incl. freeze/latch) live in the PARAMS menu; MIDI mapping
-- works there like any norns script.

engine.name = "Beads"

local beadse = include "lib/beads_engine"

local STATS = { reserve = 1.0, write = 0.0, dmode = 0.0 }

local pages = { "PLAY", "GRAIN", "RANDOM", "MIX", "SETUP" }
local page = 1
local k1_down = false
local seed_down = false
local dirty = true
local redrawer

local W, H = 128, 64

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
        engine.clock()
        sync_last = os.clock()
      end
    end)
  end
end

local function sync_watchdog()
  if params:get("sync") == 2 and params:get("latch") == 1 then
    local stale = os.clock() - sync_last
    if stale > (60 / safe_bpm()) * 4 + 2 then
      start_sync()   -- loop died or clock was reset - revive it
    end
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
  screen.level(4)
  screen.move(0, 8)
  screen.text(pages[page])
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
  -- dashes anchored to the right edge so any page count fits
  local x0 = 125 - #pages * 5
  for i = 1, #pages do
    screen.move(x0 + (i - 1) * 5 + 1, 8)
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
      sync_watchdog()
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
  if redrawer then clock.cancel(redrawer) end
  stop_sync()
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
    dirty = true
    return
  end
  local e2 = { "time", "density", "time_amt", "feedback", "media" }
  local e3 = { "pitch", "size", "size_amt", "rvb", "mono" }
  local e4 = { "pitch_amt", "shape", "shape_amt", "drywet", "gain" }
  local t = n == 2 and e2[page] or (n == 3 and e3[page] or e4[page])
  params:delta(t, d)
  dirty = true
end

function key(n, z)
  if n == 1 then
    k1_down = z == 1
  elseif n == 2 and z == 1 then
    if k1_down then
      params:set("sync", params:get("sync") == 2 and 1 or 2)
    else
      params:set("freeze", params:get("freeze") == 1 and 0 or 1)
    end
    dirty = true
  elseif n == 3 then
    if k1_down and z == 1 then
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
      "  p.amt " .. string.format("%+.2f", params:get("pitch_amt")))
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
    screen.text("envelope - E4 shape " ..
      string.format("%.2f", params:get("shape")) ..
      (params:get("size") < 1 / 3 and "  rev" or
        (params:get("size") > 0.99 and "  delay" or "")))
  elseif page == 3 then
    -- RANDOM: the four attenurandomizers (pitch amt lives on PLAY E4)
    local rows = {
      { "E2 time amt", params:get("time_amt") },
      { "E3 size amt", params:get("size_amt") },
      { "E4 shape amt", params:get("shape_amt") },
    }
    for i, r in ipairs(rows) do
      local y = 26 + (i - 1) * 12
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
      local y = 26 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      bar(58, y - 5, 66, r[2], 10)
    end
    screen.level(4)
    screen.move(0, 62)
    if params:get("sync") == 2 then
      screen.text("delay tempo = " ..
        string.format("%d", math.floor(safe_bpm() + 0.5)) ..
        " bpm x density subdivision")
    else
      screen.text("K1+K2 clock sync on")
    end
  else
    local rows = {
      { "E2 media", beadse.media_name(params:get("media")) },
      { "E3 chans", params:get("mono") == 2 and "mono" or "stereo" },
      { "E4 in gain", string.format("%.2fx", params:get("gain")) },
    }
    for i, r in ipairs(rows) do
      local y = 26 + (i - 1) * 12
      screen.level(4)
      screen.move(0, y)
      screen.text(r[1])
      screen.level(15)
      screen.move(52, y)
      screen.text(r[2])
    end
    screen.level(4)
    screen.move(0, 62)
    screen.text("K1+K2 sync " ..
      (params:get("sync") == 2
        and (string.format("%d", math.floor(safe_bpm() + 0.5)) .. "bpm")
        or "off") ..
      "  K1+K3 latch " .. (params:get("latch") == 1 and "on" or "off"))
  end

  screen.update()
end
