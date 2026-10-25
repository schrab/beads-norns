-- beads_engine.lua - parameter registration + engine bindings
-- for the beads-norns port of Mutable Instruments Beads.
--
-- Every panel control maps to a norns param; the param action pushes the
-- value to the engine. The AMOUNT knobs (-1..1) mirror the module's
-- attenurandomizers: positive adds randomization, negative peaks it.

local beadse = {}

local MEDIA = { "scorched tape", "sunny tape", "cold digital", "digital" }

local cs = {
  unit = controlspec.new(0, 1, "lin", 0.005, 0.5, ""),
  amt = controlspec.new(-1, 1, "lin", 0.02, 0, ""),
  pitch = controlspec.new(-24, 24, "lin", 0.05, 0, "st"),
  gain = controlspec.new(0.25, 4, "lin", 0.02, 1, ""),
}

local function ri(x) return math.floor(x + 0.5) end

local function density_format(param)
  local d = param:get()
  if d < 0.48 then
    return string.format("%d hz", ri(130.81 * 2 ^ (-16 * d)))
  elseif d > 0.52 then
    return string.format("~%d hz", ri(0.5 * 130.81 * 2 ^ (-16 * (1 - d))))
  else
    return "tap/gate"
  end
end

function beadse.add_params()

  params:add_separator("beads", "BEADS")

  params:add {
    type = "control", id = "time", name = "time",
    controlspec = cs.unit,
    action = function(x) engine.time(x) end,
  }
  params:add {
    type = "control", id = "time_amt", name = "time amount",
    controlspec = cs.amt,
    action = function(x) engine.time_amt(x) end,
  }
  params:add {
    type = "control", id = "pitch", name = "pitch",
    controlspec = cs.pitch,
    action = function(x) engine.pitch(x) end,
  }
  params:add {
    type = "control", id = "pitch_amt", name = "pitch amount",
    controlspec = cs.amt,
    action = function(x) engine.pitch_amt(x) end,
  }

  params:add_separator("beads_grain", "GRAIN")

  params:add {
    type = "control", id = "density", name = "density",
    controlspec = controlspec.new(0, 1, "lin", 0.005, 0.3, ""),
    formatter = density_format,
    action = function(x) engine.density(x) end,
  }
  params:add {
    type = "control", id = "size", name = "size",
    controlspec = controlspec.new(0, 1, "lin", 0.005, 0.3, ""),
    formatter = function(param)
      local s = param:get()
      if s > 0.99 then return "delay mode" end
      if s < 1 / 3 then return string.format("rev %d ms", ri(4000 * 2 ^ (-81 * (s * 3 * (2 - s * 3))))) end
      local sh = math.min(1, 1.025 * (1 - 1.5 * (s - 1 / 3)))
      return string.format("%d ms", ri(4000 * 2 ^ (-108 * sh)))
    end,
    action = function(x) engine.size(x) end,
  }
  params:add {
    type = "control", id = "size_amt", name = "size amount",
    controlspec = cs.amt,
    action = function(x) engine.size_amt(x) end,
  }
  params:add {
    type = "control", id = "shape", name = "shape",
    controlspec = cs.unit,
    action = function(x) engine.shape(x) end,
  }
  params:add {
    type = "control", id = "shape_amt", name = "shape amount",
    controlspec = cs.amt,
    action = function(x) engine.shape_amt(x) end,
  }

  params:add_separator("beads_mix", "MIX")

  params:add {
    type = "control", id = "feedback", name = "feedback",
    controlspec = controlspec.new(0, 1, "lin", 0.005, 0, ""),
    action = function(x) engine.feedback(x) end,
  }
  params:add {
    type = "control", id = "drywet", name = "dry/wet",
    controlspec = controlspec.new(0, 1, "lin", 0.005, 1, ""),
    formatter = function(param)
      local v = param:get()
      return v < 0.025 and "dry" or (v > 0.975 and "wet" or
        string.format("%d/%d", ri((1 - v) * 100), ri(v * 100)))
    end,
    action = function(x) engine.drywet(x) end,
  }
  params:add {
    -- id must not be "reverb": something (a mod hook) adds its own
    -- "reverb" param after script init and paramset clobbers on collision
    type = "control", id = "rvb", name = "reverb",
    controlspec = controlspec.new(0, 1, "lin", 0.005, 0, ""),
    action = function(x) engine.reverb(x) end,
  }
  params:add {
    type = "control", id = "gain", name = "input gain",
    controlspec = cs.gain,
    formatter = function(param) return string.format("%.2fx", param:get()) end,
    action = function(x) engine.gain(x) end,
  }

  params:add_separator("beads_setup", "SETUP")

  params:add {
    type = "option", id = "media", name = "media",
    options = MEDIA, default = 4,
    action = function(x) engine.media(x - 1) end,
  }
  params:add {
    type = "option", id = "mono", name = "channels",
    options = { "stereo", "mono" }, default = 1,
    action = function(x) engine.mono(x - 1) end,
  }
  params:add {
    type = "binary", id = "freeze", name = "freeze",
    behavior = "toggle", default = 0,
    action = function(x) engine.freeze(x) end,
  }
  params:add {
    type = "binary", id = "latch", name = "seed latch",
    behavior = "toggle", default = 1,
    action = function(x)
      engine.latch(x)
      if beadse.on_latch then beadse.on_latch(x) end
    end,
  }
  params:add {
    type = "option", id = "sync", name = "clock sync",
    options = { "off", "norns bpm" }, default = 1,
    action = function(x)
      engine.sync(x - 1)
      if beadse.on_sync then beadse.on_sync(x) end
    end,
  }

end

function beadse.media_name(i) return MEDIA[i] end

return beadse
