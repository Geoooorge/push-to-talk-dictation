-- Run from the repo root:  lua test/init_spec.lua
local here = arg[0]:match("(.*)/") or "."
dofile(here .. "/hammerspoon_stub.lua")
dofile(here .. "/../hammerspoon-init.lua")
TEST.clearAlerts()   -- drop the persistent "Dictation loaded" banner
local pass, fail = 0, 0
local function check(label, got, want)
  if got == want then pass = pass + 1; print(("  PASS  %s"):format(label))
  else fail = fail + 1; print(("  FAIL  %s\n        got %q want %q"):format(label, tostring(got), tostring(want))) end
end

print("1. normal press/release")
TEST.press(TAP); check("shows warm-up", TEST.alertsShown(), "Opening mic")
TEST.finishTask();  check("swaps to Listening", TEST.alertsShown(), "Listening")
TEST.release(TAP);  check("Listening cleared, transcribing", TEST.alertsShown(), "...")
TEST.finishTask();  check("all alerts cleared", TEST.alertsShown(), "")

print("2. tap never delivers the release (the reported bug)")
TEST.press(TAP); TEST.finishTask()
check("listening", TEST.alertsShown(), "Listening")
TEST.tick(1)                  -- a tick while genuinely held: trust is earned
TEST.silentRelease()          -- key physically up, no event delivered
TEST.tick(1); check("one poll: not yet (needs two)", TEST.alertsShown(), "Listening")
TEST.tick(1); check("two polls: recovered", TEST.alertsShown(), "...")
TEST.finishTask(); check("cleared after recovery", TEST.alertsShown(), "")

print("3. hotkey works again after a recovery")
TEST.press(TAP); check("re-arms", TEST.alertsShown(), "Opening mic")
TEST.finishTask(); TEST.release(TAP); TEST.finishTask()
check("clean", TEST.alertsShown(), "")

print("4. single blip must not stop a real recording")
TEST.press(TAP); TEST.finishTask()
TEST.setRaw(0)            -- one bad read
TEST.tick(1)
TEST.setRaw(0x40)         -- key still genuinely held
TEST.tick(1)
check("still listening", TEST.alertsShown(), "Listening")
TEST.release(TAP); TEST.finishTask()

print("5. macOS disables the tap -> supervisor revives it")
TEST.setTapEnabled(false)
check("tap down", TEST.tapEnabled(), false)
TEST.tick(1)
check("tap restarted", TEST.tapEnabled(), true)

print("6. API never reports the key held -> must never force-stop")
TEST.press(TAP); TEST.finishTask()
TEST.setModHeld(false)    -- as if checkKeyboardModifiers is useless on this build
check("listening", TEST.alertsShown(), "Listening")
TEST.tick(6)
check("trust never earned, still listening", TEST.alertsShown(), "Listening")
TEST.release(TAP); TEST.finishTask()
check("real release still works", TEST.alertsShown(), "")

print("7. trust is earned mid-recording, then release detected")
TEST.press(TAP); TEST.finishTask()
TEST.setModHeld(true); TEST.tick(1)      -- observed held -> trusted
check("still listening while held", TEST.alertsShown(), "Listening")
TEST.silentRelease()                      -- released, no event delivered
TEST.tick(2)
check("recovered after release", TEST.alertsShown(), "...")
TEST.finishTask(); check("cleared", TEST.alertsShown(), "")

print("8. trust does not leak between recordings")
TEST.press(TAP); TEST.finishTask()
TEST.setModHeld(false)   -- new recording, API unhelpful again
TEST.tick(6)
check("no stale trust from run 7", TEST.alertsShown(), "Listening")
TEST.release(TAP); TEST.finishTask()

print("9. tap comes back deaf after sleep -> wake rebuilds it")
-- The regression that made the hotkey need a manual reload: the tap still
-- reports enabled, so the supervisor never acts on it.
TEST.clearAlerts()
check("tap still claims enabled", TEST.tapEnabled(), true)
local before = TEST.tapGeneration()
TEST.tick(1)
check("supervisor does nothing, it looks fine", TEST.tapGeneration(), before)
TEST.wake()
check("wake rebuilt the tap", TEST.tapGeneration() > before, true)

print("10. hotkey still records after a wake")
TEST.press(TAP); check("re-arms after wake", TEST.alertsShown(), "Opening mic")
TEST.finishTask(); TEST.release(TAP); TEST.finishTask()
check("clean", TEST.alertsShown(), "")

print("11. press while the previous clip is still transcribing")
TEST.press(TAP); TEST.finishTask(); TEST.release(TAP)   -- stop pending, not finished
check("transcribing", TEST.alertsShown(), "...")
TEST.press(TAP)
check("says why instead of dying silently",
      TEST.alertsShown(), "...,Still transcribing…")
TEST.finishTask()

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
