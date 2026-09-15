# Push-to-talk dictation on an Intel Mac

Hold a hotkey, talk, release. Text lands where your cursor is.
No subscription, no word caps, works on Intel.

## How it works

```
   hold right option
        |
        v
   Hammerspoon  ──────►  dictate.sh start  ──►  sox records to /tmp/dictate.wav
        |                                        (16 kHz mono — small file)
   release key
        |
        v
   Hammerspoon  ──────►  dictate.sh stop
                              |
                              ├─► backend: groq / openai / local
                              |     (a few hundred KB uploaded, text back)
                              |
                              └─► optional LLM cleanup pass
                              |
        ┌─────────────────────┘
        v
   inserted at your cursor in the focused app
```

You never press paste. Releasing the hotkey is the last thing you do.

Your Mac only records and pastes. The transcription happens on rented hardware
for a fraction of a cent, which is why the Intel CPU never becomes the problem.

## Install

Assumes Homebrew is already installed. Check with `which brew` — on an Intel
Mac it should print `/usr/local/bin/brew`. If not, see brew.sh.

### 1. Install the dependencies

```bash
brew install sox
brew install --cask hammerspoon
brew install curl          # recommended, see below
```

`sox` is the command-line recorder. Hammerspoon is the hotkey layer — note the
`--cask`, it's a GUI app rather than a command-line formula.

`curl` is already on macOS, so the third line looks redundant. It is not.
Apple's build links LibreSSL 3.3.6, which intermittently aborts a large upload
and loses that dictation; the Homebrew build links OpenSSL and does not. On the
same 544 KB clip with retries disabled, Apple's failed about 1 upload in 6 and
the Homebrew build failed 0 in 12. Homebrew's curl is keg-only, so it never
joins your `PATH` and changes nothing else on the system — `dictate.sh` looks
for it directly. Skip it if you like; uploads retry either way.

### 2. Put the script in place

```bash
mkdir -p ~/bin ~/.config/dictate
cp dictate.sh ~/bin/dictate.sh
chmod +x ~/bin/dictate.sh
```

### 3. Get an API key

Sign up at console.groq.com and create a key. It starts with `gsk_`. There is a
free tier; add a card later if you hit the rate limits.

### 4. Write the config

Open `~/.config/dictate/env` in an editor and put this in it, with your own key:

```bash
GROQ_API_KEY="gsk_paste_your_key_here"
DICTATE_BACKEND="groq"
DICTATE_CLEANUP="0"
```

Then lock it down, since it holds your key:

```bash
chmod 600 ~/.config/dictate/env
```

### 5. Test before wiring up the hotkey

This step proves the microphone and the API both work while errors are still
visible in the terminal.

```bash
~/bin/dictate.sh start
# say something out loud for a few seconds
~/bin/dictate.sh stop
```

The second command should print your words. macOS will prompt for microphone
access on the first run — grant it to your terminal app. If nothing prints,
check `~/.config/dictate/dictate.log` before going further.

### 6. Install the Hammerspoon config

Launch Hammerspoon once from Applications so it creates its config folder. If
you already use Hammerspoon, **back up your existing config first** — this
replaces it:

```bash
mkdir -p ~/.hammerspoon
cp ~/.hammerspoon/init.lua ~/.hammerspoon/init.lua.backup 2>/dev/null
cp hammerspoon-init.lua ~/.hammerspoon/init.lua
```

Click the Hammerspoon menu bar icon and choose **Reload Config**. A "Dictation
loaded" alert should appear.

### 7. Grant permissions

System Settings → Privacy & Security:

- **Accessibility** → enable Hammerspoon. Required to insert text at your
  cursor. Without this, nothing will appear.
- **Microphone** → enable Hammerspoon if it appears in the list.

Toggling Accessibility off and back on fixes most "nothing appears" problems.

### 8. Launch Hammerspoon at login

Click the Hammerspoon menu bar icon → **Preferences** → tick **Launch
Hammerspoon at login**.

Do not skip this. Hammerspoon *is* the hotkey — if it is not running after a
restart, the key does nothing at all: no alert, no error, and nothing written
to the log, because the script is never invoked. It reads as the tool having
broken. Setting it inside Hammerspoon rather than in System Settings means it
survives app updates.

### 9. Use it

Hold the **right option** key, speak, release. Text appears where your cursor
is.

Two indicators appear in sequence. **"Opening mic"** means the key is down but
the audio device is still opening — anything said now is lost. **"Listening"**
means it is genuinely recording. Wait for the second one before you speak.
On this hardware the gap is about 0.7 seconds; the breakdown is below.

Held on its own a modifier types nothing, so there is no chord and nothing
to conflict with — this is what `HOTKEY_MODE = "modifier"` at the top of
`init.lua` selects, and `MODIFIER_MASK` picks which modifier (the table above
it lists the codes). Set `HOTKEY_MODE = "chord"` if you would rather use a
classic combo such as cmd+alt+D.

## Commands

Hammerspoon calls the first two for you; `retry` is the only one you are likely
to type.

| Command | What it does |
|---|---|
| `dictate.sh start` | Begin recording. Returns once the mic is genuinely capturing, not when the recorder launches. |
| `dictate.sh stop` | Stop, transcribe, print the text to stdout. |
| `dictate.sh retry [file]` | Re-send a clip whose upload failed. Newest unsent clip if no file is named. |

## Config options

Everything goes in `~/.config/dictate/env`.

| Variable | Default | Notes |
|---|---|---|
| `DICTATE_BACKEND` | `groq` | `groq`, `openai`, or `local` |
| `DICTATE_CLEANUP` | `0` | `1` adds an LLM pass that strips filler words |
| `DICTATE_LANG` | `en` | Forcing a language is faster and more accurate |
| `DICTATE_MIN_SECONDS` | `0.4` | Ignores accidental taps of the hotkey |
| `DICTATE_WARMUP_MAX` | `2.0` | Seconds `start` waits for the mic before giving up |
| `GROQ_API_KEY` | — | Required for the groq backend |
| `DICTATE_GROQ_MODEL` | `whisper-large-v3-turbo` | |
| `DICTATE_CLEANUP_MODEL` | `qwen/qwen3.8-27b` | Only used if cleanup is on |
| `DICTATE_RECORDER` | `auto` | `sox`, `micrec`, or `ffmpeg`; `auto` prefers sox |
| `DICTATE_UNSENT` | `~/.config/dictate/unsent` | Where a recording is kept if its upload fails |
| `DICTATE_CURL` | auto | Path to curl; a Homebrew one is preferred automatically |

### Changing the API key

Your key lives in one file and nowhere else:

```bash
~/.config/dictate/env
```

To rotate it — you revoked the old one, hit a spending cap, or moved accounts —
edit that file, change the `GROQ_API_KEY=` line, and save. Nothing to reload and
nothing to restart: `dictate.sh` reads the file fresh on every keypress, so the
next thing you dictate uses the new key.

```bash
open -e ~/.config/dictate/env        # or: nano ~/.config/dictate/env
```

The file must stay readable only by you. If you ever recreate it, re-apply:

```bash
chmod 600 ~/.config/dictate/env
```

A wrong or revoked key shows up as `401` in `~/.config/dictate/dictate.log` and
nothing pasted. Keep the file out of any git repository — it holds a live
credential.

### What cleanup does

With `DICTATE_CLEANUP=0` you get a literal transcript — accurate, but your
"um"s and false starts are in it. With `DICTATE_CLEANUP=1` a second call sends
the transcript to a fast LLM that removes filler and fixes punctuation without
changing your words. That second pass is the actual thing Wispr Flow charges
for. It costs a fraction of a cent per dictation and adds roughly half a second
of latency. Try it both ways.

The cleanup model is hosted by the same provider as the transcription and uses
the same API key, so turning it on does not send your speech anywhere new.

Cleanup never fails loudly. If the request errors, times out, or comes back
looking wrong, the script logs a line and gives you the raw transcript instead
— you lose the filler removal, never your words. Two things count as "looking
wrong":

- **The model answered the text instead of cleaning it.** Dictate a sentence
  phrased like an instruction and a model may refuse it or obey it; either way
  your words are gone. The check is on length, and it is deliberately lopsided:
  the prompt forbids adding content, so a result *longer* than the input means
  the model wrote something of its own and is rejected fairly tightly, while a
  much *shorter* result is usually just a rambling clip being stripped of
  filler and is allowed. Only a collapse to near-nothing is rejected. The log
  says `cleanup output implausible`.

  This is a blunt instrument and it does not catch everything. A short
  instruction buried in a long dictation that the model quietly obeys can
  produce a plausible length. The guard is there so the common failure — a
  wordy refusal pasted into your document — cannot happen; it is not a
  security boundary.
- **The model leaked its scratchpad.** Some models emit `<think>` reasoning
  inline with the reply. Those blocks are stripped before anything reaches the
  clipboard, and a reply that is nothing but an unterminated block is discarded.

If you swap `DICTATE_CLEANUP_MODEL`, check the log after a few dictations. A
model that trips either guard constantly is the wrong model for this job.

### Running fully local instead

If you'd rather nothing leave the machine, build whisper.cpp and point the
script at it. Expect it to be slower on Intel — stay on the small models.

```bash
git clone https://github.com/ggml-org/whisper.cpp ~/src/whisper.cpp
cd ~/src/whisper.cpp
cmake -B build && cmake --build build -j --config Release
sh ./models/download-ggml-model.sh base.en
```

Then in `~/.config/dictate/env`:

```bash
DICTATE_BACKEND="local"
WHISPER_CLI="$HOME/src/whisper.cpp/build/bin/whisper-cli"
WHISPER_MODEL="$HOME/src/whisper.cpp/models/ggml-base.en.bin"
WHISPER_THREADS="4"
```

Time a 20-second clip. If `base.en` is tolerable, try `small.en` for better
accuracy. If neither is fast enough, that answers the local-on-Intel question
for good and you go back to the API.

## Keeping it up to date

The files in this repository are sources. They are not what runs — `~/bin/` and
`~/.hammerspoon/` are. After pulling changes, copy them across again:

```bash
git pull
cp dictate.sh ~/bin/dictate.sh && chmod +x ~/bin/dictate.sh
cp hammerspoon-init.lua ~/.hammerspoon/init.lua
```

`dictate.sh` is re-read on every keypress, so it needs nothing further. The
Hammerspoon config is only read at load, so reload it from the menu bar icon —
or, since the config loads `hs.ipc`, from a shell:

```bash
hs -c 'hs.reload()'
```

Your settings live in `~/.config/dictate/env` and in the tunables at the top of
`init.lua`. Pulling will overwrite `init.lua` edits, so note any you have made.

## Developing

```bash
bash -n dictate.sh          # shell syntax
luac -p hammerspoon-init.lua   # lua syntax (brew install lua)
lua test/init_spec.lua      # 20 assertions, no microphone needed
```

`test/init_spec.lua` stubs the Hammerspoon API and loads the real `init.lua`
headless, so it can drive the things that are impractical to reproduce by hand:
a key release the event tap never delivers, a tap disabled by the system, a
modifier API that never reports the key held. If you change the recording state
machine, add a case — a syntax check will not catch a logic error in a callback
that only fires on failure.

To force the upload-failure path without touching your config, name a model
that does not exist:

```bash
DICTATE_GROQ_MODEL=does-not-exist ~/bin/dictate.sh stop
```

## Cost

Groq bills whisper-large-v3-turbo at $0.04 per hour of audio, minimum 10
seconds per request.

| Your usage | Audio/month | Cost/month |
|---|---|---|
| Light (15 min/week) | 1 hr | $0.04 |
| Moderate (1 hr/week) | 4 hrs | $0.16 |
| Heavy (1 hr/day) | 20 hrs | $0.80 |
| Very heavy (2 hrs/day) | 40 hrs | $1.60 |

Wispr Flow Pro is $144/year.

## Troubleshooting

**Nothing pastes.** Hammerspoon needs Accessibility permission. Toggle it off
and on in System Settings → Privacy & Security → Accessibility.

**"sox not found".** On Intel Macs Homebrew installs to `/usr/local/bin`; the
script already checks there, but confirm with `which rec`.

**"transcription failed" and nothing pasted.** The recording is not lost. A
clip whose upload fails is kept in `~/.config/dictate/unsent/`, and the log
line names the file. Send it again with:

```bash
~/bin/dictate.sh retry          # newest unsent clip, prints the transcript
~/bin/dictate.sh retry FILE     # or a specific one
```

The file is deleted once it transcribes successfully. Since `retry` prints to
stdout rather than typing at your cursor, pipe it to `pbcopy` if you want it on
the clipboard.

**`sslv3 alert bad record mac` in the log.** A TLS failure inside Apple's
bundled curl, which links LibreSSL 3.3.6. It hits large uploads specifically —
measured at roughly 1 upload in 6 for a 17-second clip, while 12 consecutive
small requests never failed. Nothing is wrong with your key or network.

Two things guard against it. Uploads retry up to three times, which alone took
8 uploads to zero failures. And if a Homebrew curl is installed it is used in
preference to Apple's, since it links OpenSSL instead:

```bash
brew install curl        # keg-only; dictate.sh finds it without touching PATH
```

Same 544KB clip, no retries, Apple's curl failed about 1 in 6 while the
Homebrew build failed 0 in 12. The transcription-failure message names which
curl was used, so the log tells you which one was in play. `DICTATE_CURL`
overrides the choice.

**Empty output.** Check `~/.config/dictate/dictate.log`. Usually a bad API key
or a clip under the minimum length. A `404` there means the model named in your
config no longer exists — providers retire them; check the provider's model
list and update `DICTATE_CLEANUP_MODEL` or `DICTATE_GROQ_MODEL`.

**Filler words come back sometimes.** Cleanup fell back to the raw transcript.
The log line says why — see "What cleanup does" above. A `429` there is rate
limiting, which on a free tier can happen when you dictate in fast bursts.

**"Listening" stays on screen after you let go, and the hotkey goes dead.**
Fixed, but worth knowing about. macOS silently disables an event tap whose
callback it judges too slow, and a disabled tap delivers no further events —
including your key release. The recording state was then stuck on, the alert
never closed, and every later keypress hit the "already recording" guard, so
only reloading Hammerspoon brought it back.

Two guards now handle it. While recording, the real modifier state is polled
four times a second, so a release the tap never delivered is picked up within
half a second. Separately the tap itself is checked every `TAP_CHECK_INTERVAL`
seconds (default 5) and restarted if the system has disabled it. Both write a
line to the Hammerspoon console when they fire, so a recovery is never silent.

The tap check costs one call per tick, measured at 0.07 microseconds — a few
milliseconds of CPU per day. The only real expense is waking a timer. Set
`TAP_CHECK_INTERVAL = 0` at the top of `init.lua` to switch it off; you then
keep the release watchdog, and a tap disabled by the system stays dead until
you reload Hammerspoon, which is the behaviour this guard exists to prevent.

The polling guard earns the right to act rather than assuming it. macOS reports
modifier state to a background query in *device-independent* form, which cannot
distinguish left option from right, and an attempt to match it against the
left/right `MODIFIER_MASK` value always failed — that side information only
exists on the event itself. So the watchdog asks a weaker question: is that
modifier still down at all. It may only answer "released" after it has seen the
key genuinely held at least once during the current recording, which proves the
reading works on this machine before anything acts on it. Trust is re-earned on
every recording and never carried over.

Two consequences worth knowing. Holding the *other* option key when you release
yours leaves the watchdog waiting — it sees a modifier still down, so recovery
falls back to the 120-second cap. And a press released within the first 250 ms,
before any tick observes it held, is likewise not covered; in practice the
microphone warm-up means you are holding the key far longer than that.

**Stuck on "Opening mic".** The microphone never produced samples. Usually a
permission problem — check the log for `no samples within`. Grant Microphone
access to Hammerspoon, or run `~/bin/dictate.sh start` from Terminal to see the
recorder's own error.

**Silent recording.** Hammerspoon needs Microphone permission. If macOS never
prompted, run `~/bin/dictate.sh start` from Terminal once — Terminal will
prompt instead, then grant it to Hammerspoon manually.

**Hotkey conflicts.** Change `MODIFIER_MASK` at the top of `init.lua` to pick a
different modifier, or set `HOTKEY_MODE = "chord"` and change `HOTKEY_MODS` /
`HOTKEY_KEY`. Reload Hammerspoon from its menu bar icon afterwards.

**Text goes to the wrong place, or a shortcut fires instead of text.** You're
in an app where cmd-V means something else. Set `INSERT_METHOD = "type"` at the
top of `init.lua` — slower and visibly typed, but it never sends cmd-V.

**A paste lands empty, or pastes the previous dictation.** The app read the
clipboard before the write landed. Raise `CLIPBOARD_SETTLE` at the top of
`init.lua` to 0.1 and reload.

**Characters get dropped or scrambled when typing.** Some Electron apps and
remote-desktop sessions can't keep up with synthetic keystrokes. Set
`TYPE_DELAY = 0.01` in `init.lua`.

**Nothing happens in a password field.** macOS Secure Input blocks synthetic
keystrokes entirely. This is a system protection, not a bug, and there's no way
around it.

### Why there are two indicators

Opening the audio device takes roughly half a second on a built-in Mac
microphone. That delay is real and not tunable — the recorder process starts
instantly, but the first samples do not arrive until CoreAudio has the device
ready, so a naive "Listening" alert shown on keypress is lying to you for the
first half second and your opening word lands nowhere.

Measured on an Intel MacBook Pro, holding the key for exactly two seconds:

| | Audio captured |
|---|---|
| Indicator shown on keypress | 1.38 – 1.55 s |
| Indicator shown when samples arrive | 2.29 – 2.36 s |

So `dictate.sh start` now polls the growing audio file and does not return
until real samples have landed, and Hammerspoon only swaps to "Listening" at
that point. Speaking when the second indicator appears loses nothing — the
surplus above is audio banked while the indicator caught up.

The cost is that "Listening" arrives about 0.70–0.74s after you press the key,
measured end to end from inside Hammerspoon. That breaks down as:

| | |
|---|---|
| Audio device opening | ~410 ms |
| `sox` buffering before its first write | ~190 ms |
| Script startup before the recorder launches | ~65 ms |

All three were attacked and only the last one moved.

**The device open is a hardware floor.** A native `AVAudioEngine` recorder —
the `micrec` backend this script supports — was measured at 665–695 ms to its
first buffer, *slower* than sox's ~410 ms. There is nothing to win there.

**The buffering cannot be reduced safely.** `sox --buffer` makes the first
samples appear sooner, but every reduced size eventually overruns the
CoreAudio input buffer and discards audio mid-recording. Each of these looked
clean at shorter durations before failing:

| `--buffer` | Result |
|---|---|
| 256 | 53 overruns in 5 s |
| 1024 | clean at 5 s, 6 overruns in 10 s |
| 2048 | clean at 10 s, 7 overruns in 15 s |
| 4096 | clean at 15 s, 1 overrun in 20 s |
| 1024 with `--input-buffer 8192` | clean at 20 s, 69 overruns in 30 s |
| 8192 (default) | no overruns at any length tested |

Silently dropping samples to shave 0.2s off an indicator is a bad trade, so
the default stands and `dictate.sh` carries a comment saying why.

**Script startup was worth trimming.** `pgrep -f`, used to find an orphaned
recorder, costs ~57 ms and ran before the recorder launched — delaying the
microphone by that much on every dictation. A live recorder always holds its
output file open and the stop path deletes that file, so when no such file
exists the scan is skipped via a shell builtin test. The orphan safety net is
unchanged when a file *is* present.

The only remaining way to go faster is to keep the microphone open between
dictations, which trades a live mic for the 600 ms. That is not done here.

`DICTATE_WARMUP_MAX` caps that wait so a dead or permission-blocked microphone
cannot hang the hotkey; if it expires you get a line in the log saying so.

## Notes

- Audio is recorded to `/tmp/dictate.wav` and deleted as soon as the
  transcript comes back. The one exception is an upload that fails: that clip
  is moved to `~/.config/dictate/unsent/` so it can be re-sent, and deleted
  once it transcribes. If you abandon one, delete the file — it is a recording
  of you sitting on disk. Nothing is stored server-side by this script;
  retention is whatever your API provider's policy says.
- The microphone is open for as long as you hold the key, so anything audible
  in the room is transcribed along with you — a video playing nearby will have
  its dialogue land in your text. That is the transcription working correctly,
  not a fault. True silence is different: on an empty clip Whisper tends to
  emit a stock phrase such as "Thank you.", which is why very short clips are
  discarded via `DICTATE_MIN_SECONDS`.
- `INSERT_METHOD` controls how text lands. `"paste"` (the default) puts the
  whole dictation in at once via the clipboard, then restores what you had
  about half a second later — this is what makes it appear in one go rather
  than visibly spelling itself out. `"type"` synthesises keystrokes instead and
  never touches the clipboard, which is safer in apps with modal keybindings.
  `"auto"` types results under 250 characters and pastes longer ones.
- The clipboard restore preserves whatever was there, including images, files
  and rich text — not just plain text. If you copy something during the half
  second before the restore fires, your copy wins and the restore is skipped.
- `whisper.cpp` is unrelated to Wispr Flow despite the name. It's a C++ port of
  OpenAI's open-weights Whisper model.
