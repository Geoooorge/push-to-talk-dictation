-- ~/.hammerspoon/init.lua
--
-- Push-to-talk dictation. Hold the hotkey, speak, release.
-- Text appears at your cursor automatically. You never press paste.
--
-- Requires ~/bin/dictate.sh (see dictate.sh in this folder).

-- Lets the `hs` command-line tool talk to this config: syntax-check a change,
-- confirm the hotkey bound, check hs.accessibilityState(), reload from a
-- shell. Harmless if you never use it.
require("hs.ipc")

local DICTATE = os.getenv("HOME") .. "/bin/dictate.sh"

-- Hold this to record.
--
-- HOTKEY_MODE = "modifier" uses a single modifier key on its own, the way
-- Wispr Flow does. Held alone a modifier types nothing, so there is no chord
-- and nothing to conflict with. MODIFIER_MASK picks which one:
--
--   right option 0x40    left option 0x20
--   right cmd    0x10    left cmd     0x08
--   right ctrl   0x2000  left ctrl    0x01
--   right shift  0x04    left shift   0x02
--
-- HOTKEY_MODE = "chord" uses the classic HOTKEY_MODS + HOTKEY_KEY combo.
local HOTKEY_MODE   = "modifier"
local MODIFIER_MASK = 0x40          -- right option

local HOTKEY_MODS = { "cmd", "alt" } -- only used when HOTKEY_MODE == "chord"
local HOTKEY_KEY  = "D"

-- How the text gets inserted:
--
--   "type"   Hammerspoon types the characters directly. The clipboard is
--            never touched. Safest in apps with modal keybindings (vim) or
--            that intercept cmd-V. Slower on long text.
--
--   "paste"  Puts text on the clipboard and sends cmd-V, then restores your
--            previous clipboard. Instant regardless of length. Can misfire in
--            apps where cmd-V means something else.
--
--   "auto"   Types short results, pastes long ones.
--
-- "paste" is the default: it puts the whole dictation in at once, the way
-- Wispr Flow does, instead of visibly spelling it out. "auto" typed anything
-- under 250 characters, which is most dictations.
--
local INSERT_METHOD = "paste"

-- Under this many characters, "auto" types instead of pasting.
local AUTO_TYPE_THRESHOLD = 250

-- When typing, characters are sent in chunks with a small pause between them.
-- Larger chunks = faster. If an app drops characters, lower CHUNK_SIZE or
-- raise CHUNK_PAUSE.
local CHUNK_SIZE  = 40     -- characters per chunk
local CHUNK_PAUSE = 0.01   -- seconds between chunks

-- Pasting. SETTLE gives the pasteboard write time to land before cmd-V is
-- sent; RESTORE is how long to wait before putting your old clipboard back.
-- Raise SETTLE if a paste ever lands empty or stale.
local CLIPBOARD_SETTLE  = 0.05
local CLIPBOARD_RESTORE = 0.6

-- Recovery. macOS silently disables an event tap whose callback it considers
-- too slow, and a disabled tap delivers nothing — including the key release,
-- which used to leave "Listening" on screen forever with the hotkey dead until
-- Hammerspoon was reloaded. WATCHDOG_INTERVAL is how often, while recording,
-- the real modifier state is checked against what we think it is.
-- TAP_CHECK_INTERVAL is how often the tap itself is checked and revived.
-- Set TAP_CHECK_INTERVAL to 0 to switch the tap check off entirely. It costs
-- one 0.07-microsecond call per tick, so the only real expense is waking a
-- timer; at 5s that is trivial, but it is your machine.
local WATCHDOG_INTERVAL   = 0.25
local TAP_CHECK_INTERVAL  = 5.0
local MAX_RECORDING_SECS  = 120

------------------------------------------------------------------ internals

local recording      = false
local startTask      = nil   -- the "start" subprocess, so stop can wait for it
local stopTask       = nil   -- the "stop" subprocess (transcribing)
local warmupAlert    = nil
local listeningAlert = nil
local workingAlert   = nil

local flagWatcher    = nil   -- assigned at the bottom; the watchdog revives it
local watchdog       = nil   -- runs only while recording
local tapSupervisor  = nil   -- runs always
local recordingSince = 0
local releasedPolls  = 0
local pollTrusted    = false
local warnedNoPoll   = false

-- stopRecording is defined below but referenced by the watchdog above it.
local stopRecording

-- hs.eventtap.event.getFlags() reports "alt" for either option key, so it
-- can't tell left from right. The raw CGEvent flags carry device-dependent
-- bits that can, so test those instead. Avoids Lua bitwise operators so
-- this works regardless of the Lua version Hammerspoon ships.
local function maskSet(value, mask)
  return (value % (mask + mask)) >= mask
end

-- Which named modifier MODIFIER_MASK refers to. checkKeyboardModifiers reports
-- device-INDEPENDENT flags, so it cannot tell left from right — an earlier
-- attempt to match MODIFIER_MASK against its raw value always failed. Side is
-- not needed here: the watchdog only has to answer "is that modifier still
-- down at all", and treating the other side as still-held merely makes it wait.
local MASK_TO_MOD = {
  [0x40]   = "alt",   [0x20] = "alt",
  [0x10]   = "cmd",   [0x08] = "cmd",
  [0x2000] = "ctrl",  [0x01] = "ctrl",
  [0x04]   = "shift", [0x02] = "shift",
}

-- true / false, or nil when the state cannot be read.
local function modifierHeld()
  local name = MASK_TO_MOD[MODIFIER_MASK]
  if not name then return nil end
  local ok, mods = pcall(hs.eventtap.checkKeyboardModifiers)
  if not ok or type(mods) ~= "table" then return nil end
  return mods[name] == true
end

local function closeAlert(id)
  if id then hs.alert.closeSpecific(id) end
  return nil
end

--- insertion -----------------------------------------------------------

local function typeChunked(text)
  local pos = 1
  local len = #text
  local function step()
    if pos > len then return end
    local chunk = text:sub(pos, pos + CHUNK_SIZE - 1)
    pos = pos + CHUNK_SIZE
    hs.eventtap.keyStrokes(chunk)
    if pos <= len then hs.timer.doAfter(CHUNK_PAUSE, step) end
  end
  step()
end

local function pasteViaClipboard(text)
  -- Save every flavour on the clipboard, not just plain text. getContents()
  -- returns nil for an image, a file or rich text, which used to mean those
  -- were silently dropped instead of restored.
  local previous  = hs.pasteboard.readAllData()
  local hadPrevious = previous ~= nil and next(previous) ~= nil

  hs.pasteboard.setContents(text)
  local ours = hs.pasteboard.changeCount()

  hs.timer.doAfter(CLIPBOARD_SETTLE, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    if not hadPrevious then return end

    hs.timer.doAfter(CLIPBOARD_RESTORE, function()
      -- Anything written to the clipboard since ours means you copied
      -- something in the meantime. Yours wins; don't clobber it.
      if hs.pasteboard.changeCount() ~= ours then return end
      hs.pasteboard.writeAllData(previous)
    end)
  end)
end

local function insert(text)
  local method = INSERT_METHOD
  if method == "auto" then
    method = (#text <= AUTO_TYPE_THRESHOLD) and "type" or "paste"
  end
  if method == "type" then typeChunked(text) else pasteViaClipboard(text) end
end

--- recording -----------------------------------------------------------

-- Catches a key release that the tap never delivered. Polling is only trusted
-- when the raw flags read at key-down actually contain MODIFIER_MASK: if this
-- build encodes them differently the check would misfire constantly, so it is
-- proven against a key we know is held before it is allowed to stop anything.
local function watchdogTick()
  if not recording then return end

  -- Only a modifier seen genuinely held during THIS recording may later be
  -- judged released. Reading at key-down was unreliable — the system state
  -- lags the event we are handling — so trust is earned from any tick, and a
  -- reading that never reports held simply never triggers a stop.
  local held = modifierHeld()
  if held == true then
    pollTrusted   = true
    releasedPolls = 0
  elseif held == false and pollTrusted then
    releasedPolls = releasedPolls + 1
    if releasedPolls >= 2 then   -- two in a row, never a single blip
      print("[dictate] hotkey release was never delivered — recovering")
      stopRecording()
      return
    end
  end

  -- Last resort, and the only guard when polling could not be trusted.
  if hs.timer.secondsSinceEpoch() - recordingSince > MAX_RECORDING_SECS then
    print("[dictate] recording exceeded " .. MAX_RECORDING_SECS .. "s — recovering")
    stopRecording()
  end
end

local function startRecording()
  if recording then return end
  if stopTask then return end   -- still transcribing the previous one
  recording = true

  recordingSince = hs.timer.secondsSinceEpoch()
  releasedPolls  = 0
  pollTrusted    = false   -- earned again on each recording, see watchdogTick
  if HOTKEY_MODE == "modifier" and not MASK_TO_MOD[MODIFIER_MASK] and not warnedNoPoll then
    warnedNoPoll = true
    print("[dictate] MODIFIER_MASK " .. string.format("0x%x", MODIFIER_MASK) ..
          " is not a known modifier; a missed key release will take " ..
          MAX_RECORDING_SECS .. "s to recover")
  end
  if watchdog then watchdog:stop() end
  watchdog = hs.timer.doEvery(WATCHDOG_INTERVAL, watchdogTick)

  -- The microphone takes about half a second to open. "start" does not return
  -- until it is genuinely capturing, so hold a different indicator until then
  -- rather than claiming to be listening while your first word is dropped.
  warmupAlert = hs.alert.show("Opening mic", { radius = 6 },
                              hs.screen.mainScreen(), true)

  startTask = hs.task.new("/bin/bash", function()
    startTask   = nil
    warmupAlert = closeAlert(warmupAlert)
    -- You may have released the key already; don't light up after the fact.
    if not recording then return end
    listeningAlert = hs.alert.show("Listening", { radius = 6 },
                                   hs.screen.mainScreen(), true)
  end, { DICTATE, "start" })
  startTask:start()
end

local function runStop()
  -- Guard against a very fast tap: if the "start" subprocess hasn't finished
  -- writing its PID file yet, wait for it. Otherwise "stop" could run first,
  -- find nothing to kill, and leave the recorder running with the mic open.
  if startTask and startTask:isRunning() then
    hs.timer.doAfter(0.05, runStop)
    return
  end

  stopTask = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    stopTask = nil
    workingAlert = closeAlert(workingAlert)

    local text = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if exitCode ~= 0 then
      hs.alert.show("Dictation failed — see Hammerspoon console")
      print("[dictate] exit " .. tostring(exitCode) .. "\n" .. tostring(stderr))
      return
    end
    if text == "" then return end   -- silence, or clip too short

    insert(text)
  end, { DICTATE, "stop" })

  stopTask:start()
end

stopRecording = function()
  if not recording then return end
  recording = false
  if watchdog then watchdog:stop(); watchdog = nil end
  warmupAlert    = closeAlert(warmupAlert)
  listeningAlert = closeAlert(listeningAlert)
  workingAlert = hs.alert.show("...", { radius = 6 },
                               hs.screen.mainScreen(), true)
  runStop()
end

--- binding --------------------------------------------------------------

if HOTKEY_MODE == "modifier" then
  flagWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
    function(e)
      local raw = e:getRawEventData().CGEventData.flags
      local down = maskSet(raw, MODIFIER_MASK)
      if down and not recording then
        startRecording()
      elseif (not down) and recording then
        stopRecording()
      end
      return false   -- never swallow the event; other apps still see the key
    end)
  flagWatcher:start()
else
  hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, startRecording, stopRecording)
end

-- A tap disabled by macOS stays disabled, which is what made the hotkey go
-- dead until a reload. Nothing else notices, so check it on a slow timer and
-- start it again. Held at file scope so it is not garbage collected.
if flagWatcher and TAP_CHECK_INTERVAL > 0 then
  tapSupervisor = hs.timer.doEvery(TAP_CHECK_INTERVAL, function()
    if not flagWatcher:isEnabled() then
      flagWatcher:start()
      print("[dictate] event tap had been disabled by the system — restarted")
    end
  end)
end

hs.alert.show("Dictation loaded (" .. HOTKEY_MODE .. ", " .. INSERT_METHOD .. ")")
