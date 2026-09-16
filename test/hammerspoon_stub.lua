-- Stub enough of Hammerspoon to run init.lua headless and drive its failure modes.
package.preload["hs.ipc"] = function() return {} end

local clock, timers, alerts, nextAlert = 0, {}, {}, 0
local tapEnabled, rawFlags = true, 0
local tapGeneration = 0
local tasks = {}
local pasted = nil

hs = {}
hs.timer = {
  secondsSinceEpoch = function() return clock end,
  doEvery = function(interval, fn)
    local t = { interval = interval, fn = fn, running = true }
    t.stop = function(self) self.running = false end
    timers[#timers+1] = t; return t
  end,
  doAfter = function(delay, fn)
    local t = { delay = delay, fn = fn, once = true, running = true }
    t.stop = function(self) self.running = false end
    timers[#timers+1] = t; return t
  end,
}
hs.alert = {
  show = function(text) nextAlert = nextAlert + 1
    alerts[nextAlert] = text; return nextAlert end,
  closeSpecific = function(id) alerts[id] = nil end,
}
hs.screen = { mainScreen = function() return "screen" end }
hs.eventtap = {
  event = { types = { flagsChanged = 12 } },
  checkKeyboardModifiers = function(raw)
    local t = {}
    if MODHELD then t.alt = true end          -- device-independent, no side
    if raw then t._raw = rawFlags end
    return t
  end,
  new = function(types, fn)
    local t = { fn = fn }
    TAP = t
    t.start = function(self) tapEnabled = true; tapGeneration = tapGeneration + 1 end
    t.stop  = function(self) tapEnabled = false end
    t.isEnabled = function(self) return tapEnabled end
    return t
  end,
  keyStrokes = function(s) pasted = (pasted or "") .. s end,
  keyStroke = function() pasted = "<cmd-v>" end,
}
hs.pasteboard = {
  readAllData = function() return {} end, writeAllData = function() return true end,
  setContents = function() return true end, changeCount = function() return 1 end,
}
hs.task = {
  new = function(bin, cb, args)
    local t = { cb = cb, args = args, running = false }
    t.start = function(self) self.running = true; tasks[#tasks+1] = self end
    t.isRunning = function(self) return self.running end
    return t
  end,
}
hs.hotkey = { bind = function() end }
-- The tap that comes back deaf after sleep: start/stop still work and
-- isEnabled() still reports true, so only a wake event can rescue it.
local wakeFn = nil
hs.caffeinate = {
  watcher = {
    systemDidWake = "systemDidWake",
    screensDidUnlock = "screensDidUnlock",
    sessionDidBecomeActive = "sessionDidBecomeActive",
    new = function(fn)
      wakeFn = fn
      return { start = function() end, stop = function() end }
    end,
  },
}

-- helpers the test drives
TEST = {
  tick = function(n)
    for _ = 1, (n or 1) do
      clock = clock + 0.25
      for _, t in ipairs(timers) do
        if t.running then t.fn() end
        if t.once then t.running = false end
      end
    end
  end,
  finishTask = function()
    local t = table.remove(tasks, 1)
    if t then t.running = false; t.cb(0, "", "") end
  end,
  press   = function(tap) rawFlags = 0x40; MODHELD = true; tap.fn({ getRawEventData = function() return { CGEventData = { flags = 0x40 } } end }) end,
  release = function(tap) rawFlags = 0; MODHELD = false; tap.fn({ getRawEventData = function() return { CGEventData = { flags = 0 } } end }) end,
  -- a release the tap never delivers: hardware state changes, no event
  silentRelease = function() rawFlags = 0; MODHELD = false end,
  setModHeld = function(v) MODHELD = v end,
  alertsShown = function()
    local out = {}
    for _, v in pairs(alerts) do out[#out+1] = v end
    table.sort(out); return table.concat(out, ",")
  end,
  setTapEnabled = function(v) tapEnabled = v end,
  wake = function() if wakeFn then wakeFn("systemDidWake") end end,
  tapGeneration = function() return tapGeneration end,
  tapEnabled = function() return tapEnabled end,
  setRaw = function(v) rawFlags = v end,
  clearAlerts = function() for k in pairs(alerts) do alerts[k] = nil end end,
}
