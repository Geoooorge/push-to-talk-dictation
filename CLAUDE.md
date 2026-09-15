# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Push-to-talk dictation for macOS (built and tuned on an Intel MacBook Pro): hold
the right option key, speak, release, and the transcript is inserted at the
cursor. Two source files, no build system and no package manager; published at
https://github.com/Geoooorge/push-to-talk-dictation. `README.md` is the
user-facing install and troubleshooting guide and is kept current — read it
before changing behaviour it documents.

## The repo is not what runs

This is the single most important thing to know. Editing a file here changes
nothing until it is copied to its live location:

| Repo file | Runs from |
|---|---|
| `dictate.sh` | `~/bin/dictate.sh` |
| `hammerspoon-init.lua` | `~/.hammerspoon/init.lua` |

Always sync after editing, and verify the two match. Config and logs live
outside the repo entirely, in `~/.config/dictate/`.

## Commands

```bash
# Sync after editing (do this every time)
cp dictate.sh ~/bin/dictate.sh && chmod +x ~/bin/dictate.sh
cp hammerspoon-init.lua ~/.hammerspoon/init.lua

# Confirm live copies match the repo
diff -q dictate.sh ~/bin/dictate.sh && diff -q hammerspoon-init.lua ~/.hammerspoon/init.lua

# Syntax checks — run BOTH before installing anything
bash -n dictate.sh
luac -p hammerspoon-init.lua        # brew install lua

# Lua test suite (20 assertions, stubs the Hammerspoon API, no mic needed)
lua test/init_spec.lua

# Exercise the shell side end to end (records real audio, hits the API)
~/bin/dictate.sh start && sleep 2 && ~/bin/dictate.sh stop

# Resend a clip whose upload failed (kept in ~/.config/dictate/unsent/)
~/bin/dictate.sh retry

# Force the failure path without breaking the config: an unknown model 404s
DICTATE_GROQ_MODEL=does-not-exist ~/bin/dictate.sh stop

# Watch what actually happened
tail -f ~/.config/dictate/dictate.log
```

### Driving Hammerspoon from the shell

`init.lua` loads `hs.ipc`, so the `hs` CLI can reload the config and inspect the
live runtime. Prefer this over asking the user to click Reload Config.

**Always put a timeout on `hs -c`.** It talks to Hammerspoon over a Mach port
and waits forever for a reply that may never arrive — observed hanging both on
`hs.reload()` (the Lua state is torn down mid-call) and on an ordinary query
issued soon after a reload. It is a race, not a deterministic failure, so it
will work repeatedly and then park a shell: one sat for 21 hours in this
project before anyone noticed. A fresh `hs -c` still answers normally while an
earlier one hangs, so a working call is no evidence the last one returned.

```bash
timeout 5 hs -c 'hs.reload()'                       # coreutils, if installed
perl -e 'alarm shift; exec @ARGV' 5 hs -c '...'     # always available on macOS

timeout 5 hs -c 'return tostring(hs.accessibilityState())'
# console output, including [dictate] watchdog lines
timeout 5 hs -c 'local c=hs.console.getConsole(); if type(c)=="userdata" and c.getString then c=c:getString() end; return tostring(c):sub(-600)'
```

If a shell is reported still running at the end of a session, this is the first
thing to check: `pgrep -fl "hs -c"`.

Console history survives reloads, so check timestamps before treating a warning
as current.

## Architecture

Two processes with a deliberate split: **Hammerspoon owns the keyboard, the
screen and the clipboard; `dictate.sh` owns the microphone and the network.**
They communicate only through process exit and stdout — `dictate.sh stop` prints
the final text and Hammerspoon inserts whatever it printed.

```
right option down ─► flagWatcher ─► startRecording ─► dictate.sh start
                                                        (blocks until mic live)
                          "Opening mic" → "Listening"
right option up   ─► stopRecording  ─► dictate.sh stop
                                         kill recorder → transcribe → polish
                                                        └─► stdout ─► insert()
```

### The warm-up contract

`dictate.sh start` does **not** return when the recorder launches. It polls the
growing audio file and returns only once real samples have landed (~0.6s),
capped by `DICTATE_WARMUP_MAX`. Hammerspoon relies on this: it shows "Opening
mic" until the task exits, then swaps to "Listening". Breaking this contract by
making `start` return early silently reintroduces clipped first words. The
polling runs inside one `python3` process because a shell loop needs a fork per
check (~13-28ms each), which overshot badly.

### Failure philosophy: degrade, never lose words

Every stage falls back rather than erroring out, and logs why:

- Transcription fails → the clip is moved to `$UNSENT`
  (`~/.config/dictate/unsent/`) and `dictate.sh retry` resends it. The paste is
  lost; the audio is not.
- Cleanup fails, times out, or returns implausible output → raw transcript.
- Recorder never produces samples → returns anyway after `DICTATE_WARMUP_MAX`.
- Key release never delivered → watchdog completes the dictation.

When adding a stage, follow this: the user's words are the thing that must
survive.

### `dictate.sh` shape

`set -uo pipefail`, no `-e`. Config is sourced from `~/.config/dictate/env`,
which holds the API key. `RECORDER` selects between `sox` (default), `micrec`
and `ffmpeg`, each defining `REC_CMD` plus `REC_MATCH` — a `pgrep -f` pattern
used to find an orphaned recorder. **`REC_MATCH` must be kept byte-identical to
`REC_CMD`**; they are separate strings and a change to one silently breaks
orphan cleanup.

`polish()` is the optional LLM cleanup pass. It strips `<think>` scratchpad and
rejects output whose length is implausible — deliberately lopsided, tight on
growth (a refusal is wordy) and loose on shrinkage (stripping filler legitimately
halves text).

### `hammerspoon-init.lua` shape

`HOTKEY_MODE = "modifier"` uses a raw `flagsChanged` eventtap so a modifier held
alone works as push-to-talk; `MODIFIER_MASK` selects which one via
device-dependent bits. `INSERT_METHOD = "paste"` is the default because typing
character by character is visibly slow; the clipboard is saved and restored
across all flavours, and the restore is skipped if the user copied something
meanwhile.

Two recovery mechanisms exist because macOS silently disables an eventtap whose
callback it judges too slow, which previously froze "Listening" on screen and
killed the hotkey until a manual reload:

- **Release watchdog** (while recording) polls the modifier and recovers a
  release the tap never delivered.
- **Tap supervisor** (`TAP_CHECK_INTERVAL`, 0 disables) restarts a tap the
  system disabled.

## Constraints proven by measurement — do not regress these

Each was established by testing in-session and is documented in `README.md`.
Re-deriving them costs an hour and a broken microphone.

- **Never add `--buffer` to the sox command.** Smaller buffers make the first
  samples appear sooner but overrun CoreAudio and discard audio mid-recording.
  Every reduced size passes a short soak and fails a longer one (256: 53
  overruns in 5s; 1024: 6 in 10s; 2048: 7 in 15s; 4096: 1 in 20s; 1024 with
  `--input-buffer 8192`: clean at 20s, 69 at 30s). **Audio soak tests must run
  30s or longer** — shorter runs produce false confidence.
- **Do not build the `micrec` AVAudioEngine backend to reduce latency.** Measured
  665-695ms to first buffer versus sox's ~410ms. The ~410ms is a CoreAudio floor.
- **`hs.eventtap.checkKeyboardModifiers` cannot distinguish left from right.** It
  returns device-independent flags, so matching it against `MODIFIER_MASK`
  always fails. Left/right information exists only on the event. The watchdog
  therefore asks only whether the modifier is down at all, and must observe it
  held once per recording before it may conclude anything was released.
- **Apple's curl links LibreSSL 3.3.6 and intermittently fails large multipart
  uploads** with `sslv3 alert bad record mac` — measured at ~1 in 6 for a 544KB
  clip, while small requests never failed. Two guards, keep both: every call
  goes through `$CURL`, which prefers a keg-only Homebrew curl (OpenSSL, 0
  failures in 12 on the same clip) over Apple's, and all upload calls carry
  `--retry 3 --retry-all-errors`, which also covers 429 and 5xx. Diagnose an
  upload complaint by reproducing at realistic payload size, not with a small
  GET — 12 small requests failed 0 times while the fault was live.
- **Cleanup models get retired.** A `404` in the log means the model in
  `DICTATE_CLEANUP_MODEL` no longer exists; check the provider's model list
  rather than assuming the key broke. Verify a replacement against the provider
  before switching to it.
- Reducing work before the recorder forks is the only latency lever that helped
  (`pgrep -f` cost 57ms and is now skipped when no audio file exists). Work done
  after the fork is free — it overlaps the microphone opening.

## Testing notes

`test/init_spec.lua` stubs the Hammerspoon API and loads the real `init.lua`
headless, driving the failure modes that cannot be reproduced by hand: a release
the tap never delivers, a disabled tap, a modifier API that never reports the
key held, and stale trust leaking between recordings. Add a case here when
touching the recording state machine — two regressions shipped in this codebase
passed a syntax check and would have been caught by it.

The stub's `TEST` table exposes `press`, `release`, `silentRelease` (hardware
state changes with no event delivered), `tick`, `finishTask` and `setModHeld`.
