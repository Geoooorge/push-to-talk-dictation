#!/usr/bin/env bash
#
# dictate.sh — push-to-talk dictation for macOS
#
#   dictate.sh start   begin recording (returns once the mic is actually live)
#   dictate.sh stop    stop recording, transcribe, print text to stdout
#
# Config lives in ~/.config/dictate/env  (see README)

set -uo pipefail

CONFIG="${HOME}/.config/dictate/env"
[ -f "$CONFIG" ] && . "$CONFIG"

# Homebrew on Intel Macs is /usr/local; Apple Silicon is /opt/homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

AUDIO="${DICTATE_AUDIO:-/tmp/dictate.wav}"
PIDFILE="/tmp/dictate.pid"
LOG="${HOME}/.config/dictate/dictate.log"
BACKEND="${DICTATE_BACKEND:-groq}"
LANG_CODE="${DICTATE_LANG:-en}"
CLEANUP="${DICTATE_CLEANUP:-0}"
MIN_SECONDS="${DICTATE_MIN_SECONDS:-0.4}"
RECORDER="${DICTATE_RECORDER:-auto}"

# How long "start" will wait for the microphone to produce its first samples
# before giving up and returning anyway. Only a safety cap — a working mic on
# this machine takes about 0.4s.
WARMUP_MAX="${DICTATE_WARMUP_MAX:-2.0}"

# Which microphone ffmpeg records from. ":default" follows the system input
# device. Use an explicit index (":1") to pin one; list them with:
#   ffmpeg -f avfoundation -list_devices true -i ""
# Note the leading colon — in avfoundation syntax that means "no video".
AUDIO_DEVICE="${DICTATE_AUDIO_DEVICE:-:default}"

# Three recorders, all producing the same 16 kHz mono WAV:
#
#   sox     the documented one. No Homebrew bottle on older Intel macOS, so
#           it may not be installable without a long from-source build.
#   micrec  the small AVAudioEngine recorder next to this script. Stops
#           cleanly on a signal and finalises the WAV header.
#   ffmpeg  fallback. Its avfoundation input ignores SIGINT and SIGTERM, so
#           stopping means SIGKILL — hence raw PCM plus -flush_packets below,
#           which is what keeps a killed recorder from losing buffered audio.
MICREC="${DICTATE_MICREC:-${HOME}/bin/micrec}"

case "$RECORDER" in
  sox|micrec|ffmpeg) ;;
  auto)
    if   command -v rec >/dev/null 2>&1;         then RECORDER=sox
    elif [ -x "$MICREC" ];                        then RECORDER=micrec
    elif command -v ffmpeg >/dev/null 2>&1;      then RECORDER=ffmpeg
    fi ;;
esac

# Exact recorder command line. Used both to launch and, as a fallback,
# to find and kill an orphaned recorder if the PID file is missing.
# REC_MATCH is a pgrep -f pattern that matches only our own recorder.
RAW="${AUDIO%.wav}.raw"

case "$RECORDER" in
  ffmpeg)
    # Record headerless PCM, not WAV. ffmpeg has to be SIGKILLed, and a WAV
    # whose header was never finalised is not reliably decodable; raw PCM has
    # nothing to finalise. -flush_packets 1 writes through on every packet so
    # a kill loses a few milliseconds instead of whatever sat in the buffer.
    # -nostdin keeps ffmpeg off Hammerspoon's pipes.
    REC_CMD=(ffmpeg -hide_banner -loglevel error -nostdin
             -f avfoundation -i "$AUDIO_DEVICE"
             -ac 1 -ar 16000 -sample_fmt s16
             -flush_packets 1 -f s16le -y "$RAW")
    REC_MATCH="avfoundation.*${RAW}\$"
    ;;
  micrec)
    REC_CMD=("$MICREC" "$AUDIO")
    REC_MATCH="${MICREC} ${AUDIO}\$"
    ;;
  *)
    # Resample to 16 kHz with a trailing effect rather than asking the device
    # for 16 kHz up front. Built-in mics run at 44.1 kHz and cannot be set to
    # 16 kHz, so "-r 16000" logs "WARN can't set sample rate" on every single
    # recording and then resamples anyway. Same 16 kHz output file, no warning
    # cluttering the log you are told to read when something breaks.
    # Leave sox's write buffer at its default. A smaller --buffer makes the
    # first samples hit the file sooner, which would let cmd_start notice the
    # mic sooner, but every reduced size eventually overruns CoreAudio and
    # discards captured audio mid-recording. Measured on this machine, counting
    # "unhandled buffer overrun" over repeated runs:
    #
    #    256   53 overruns in 5s      1024   6 in 10s
    #    2048  7 in 15s               4096   1 in 20s
    #    8192 (default)  none, at any length tested
    #
    # Dropping samples to shave 0.2s off an indicator is a bad trade.
    REC_CMD=(rec -q -c 1 -b 16 "$AUDIO" rate 16000)
    REC_MATCH="rec -q -c 1 -b 16 ${AUDIO} rate 16000\$"
    ;;
esac

mkdir -p "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }

die() {
  log "ERROR: $*"
  printf 'dictate: %s\n' "$*" >&2
  printf -- '--- last log lines (%s) ---\n' "$LOG" >&2
  tail -n 5 "$LOG" >&2 2>/dev/null
  exit 1
}

# ---------------------------------------------------------------- recording

# True if the process exists and is not a zombie.
alive() {
  local st
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [ -n "$st" ] && [ "${st:0:1}" != "Z" ]
}

# Ask the recorder to stop gracefully so it finalises the WAV header.
# Escalate only if it ignores us.
#
# ffmpeg is the exception: its avfoundation input does not act on INT or TERM
# at all (verified — it will sit there for tens of seconds), so going through
# the polite signals just adds two seconds of latency before every paste.
# Kill it outright; the raw-PCM recording above is what makes that safe.
stop_pid() {
  local pid="$1" sig i
  local signals=(INT TERM KILL)
  [ "$RECORDER" = "ffmpeg" ] && signals=(KILL)
  for sig in "${signals[@]}"; do
    alive "$pid" || return 0
    kill -"$sig" "$pid" 2>/dev/null || return 0
    for i in 1 2 3 4 5 6 7 8 9 10; do
      alive "$pid" || return 0
      sleep 0.1
    done
    log "recorder ignored SIG$sig, escalating"
  done
}

# Stops the recorder. Returns 0 if one was running, 1 if nothing was found.
kill_recorder() {
  local pid=""
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null) || true
    rm -f "$PIDFILE"
  fi

  if [ -n "$pid" ] && alive "$pid"; then
    stop_pid "$pid"
    return 0
  fi

  # Fallback: no PID file (e.g. stop raced ahead of start). Find the
  # recorder by its command line so we never leave the mic open.
  #
  # pgrep -f costs ~57ms here and this runs before the recorder launches, so
  # it delays the microphone opening by that much on every single dictation.
  # A live recorder always has its output file open, and the stop path deletes
  # that file, so no file means no orphan and the scan can be skipped. The
  # test is a shell builtin: no fork, no measurable cost.
  if [ ! -f "$AUDIO" ] && [ ! -f "$RAW" ]; then
    return 1
  fi

  local orphan
  orphan=$(pgrep -f "$REC_MATCH" 2>/dev/null || true)
  if [ -n "$orphan" ]; then
    log "killing orphaned recorder pid(s): $orphan"
    for pid in $orphan; do stop_pid "$pid"; done
    return 0
  fi
  return 1
}

cmd_start() {
  command -v "${REC_CMD[0]}" >/dev/null 2>&1 \
    || die "no recorder found. Run: brew install sox   (or: brew install ffmpeg)"
  kill_recorder
  rm -f "$AUDIO" "$RAW"
  # 16 kHz mono 16-bit is what Whisper wants; anything more is wasted upload.
  # stdin/stdout detached so the recorder doesn't hold Hammerspoon's pipes.
  # (bash starts background jobs with SIGINT ignored, but sox and micrec both
  # install their own INT/TERM handlers, so our graceful stop still reaches
  # them. ffmpeg does not, which is why stop_pid kills it outright.)
  "${REC_CMD[@]}" </dev/null >/dev/null 2>>"$LOG" &
  local pid=$!
  echo "$pid" >"$PIDFILE"

  # Opening the audio device takes roughly half a second, and until it
  # completes the recorder is running but capturing nothing. Returning here
  # would let the caller announce "listening" while your first word still
  # falls on the floor. Wait for real samples to hit the file instead, so
  # whoever called us can show an indicator that means something.
  local target header=44 result
  if [ "$RECORDER" = "ffmpeg" ]; then
    target="$RAW"; header=0      # headerless PCM: any byte is audio
  else
    target="$AUDIO"              # WAV: the first 44 bytes are the header
  fi

  # Poll inside one process. A shell loop needs a fork per check — $(wc) plus
  # sleep — which cost 13-28ms each here, so it could only sample every ~40ms
  # and consistently overshot the moment the mic went live. One python3 costs
  # 25ms once and then polls at 5ms without forking again.
  if command -v python3 >/dev/null 2>&1; then
    result=$(WARM_TARGET="$target" WARM_HEADER="$header" WARM_MAX="$WARMUP_MAX" \
             WARM_PID="$pid" python3 -S -c '
import os, sys, time
target = os.environ["WARM_TARGET"]
header = int(os.environ["WARM_HEADER"])
limit  = float(os.environ["WARM_MAX"])
pid    = int(os.environ["WARM_PID"])
t0 = time.time()
while time.time() - t0 < limit:
    try:
        if os.path.getsize(target) > header:
            sys.stdout.write("%.0f" % ((time.time() - t0) * 1000)); sys.exit()
    except OSError:
        pass                      # not created yet
    try:
        os.kill(pid, 0)
    except OSError:
        sys.stdout.write("dead"); sys.exit()
    time.sleep(0.005)
sys.stdout.write("timeout")
' 2>>"$LOG")
  else
    # No python3: fall back to a shell loop. Coarser, but it still waits.
    local step=0.05 tries i=0 sz
    tries=$(awk -v m="$WARMUP_MAX" -v s="$step" 'BEGIN{printf "%d", m/s}')
    result="timeout"
    while [ "$i" -lt "$tries" ]; do
      if ! kill -0 "$pid" 2>/dev/null; then result="dead"; break; fi
      # 2>/dev/null must come first: redirections are applied left to right,
      # and it is the shell that reports a failed "<" on a missing file.
      sz=$(wc -c 2>/dev/null <"$target"); sz="${sz//[^0-9]/}"
      if [ "${sz:-0}" -gt "$header" ]; then result="~$((i * 50))"; break; fi
      sleep "$step"
      i=$((i + 1))
    done
  fi

  case "$result" in
    dead)
      log "recorder exited during warm-up (pid $pid) — see errors above" ;;
    timeout)
      log "recording started (pid $pid, no samples within ${WARMUP_MAX}s — check mic permission)" ;;
    *)
      log "recording started (pid $pid, mic live after ${result}ms)" ;;
  esac
}

clip_seconds() {
  if command -v soxi >/dev/null 2>&1; then
    soxi -D "$AUDIO" 2>/dev/null && return
  fi
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error -show_entries format=duration \
            -of default=nw=1:nk=1 "$AUDIO" 2>/dev/null && return
  fi
  echo 0
}

# ------------------------------------------------------------- transcription

transcribe_groq() {
  [ -n "${GROQ_API_KEY:-}" ] || die "GROQ_API_KEY not set in $CONFIG"
  curl -sS --fail --max-time 60 \
    https://api.groq.com/openai/v1/audio/transcriptions \
    -H "Authorization: Bearer ${GROQ_API_KEY}" \
    -F "file=@${AUDIO}" \
    -F "model=${DICTATE_GROQ_MODEL:-whisper-large-v3-turbo}" \
    -F "response_format=text" \
    -F "language=${LANG_CODE}" \
    -F "temperature=0" \
    2>>"$LOG"
}

transcribe_openai() {
  [ -n "${OPENAI_API_KEY:-}" ] || die "OPENAI_API_KEY not set in $CONFIG"
  curl -sS --fail --max-time 60 \
    https://api.openai.com/v1/audio/transcriptions \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -F "file=@${AUDIO}" \
    -F "model=${DICTATE_OPENAI_MODEL:-whisper-1}" \
    -F "response_format=text" \
    -F "language=${LANG_CODE}" \
    2>>"$LOG"
}

transcribe_local() {
  local bin="${WHISPER_CLI:-}"
  { [ -n "$bin" ] && [ -x "$bin" ]; } || die "WHISPER_CLI not set or not executable"
  [ -n "${WHISPER_MODEL:-}" ] || die "WHISPER_MODEL not set in $CONFIG"
  [ -f "$WHISPER_MODEL" ]     || die "WHISPER_MODEL file not found: $WHISPER_MODEL"
  "$bin" -m "$WHISPER_MODEL" -f "$AUDIO" \
         -l "$LANG_CODE" --no-timestamps --no-prints \
         -t "${WHISPER_THREADS:-4}" 2>>"$LOG"
}

transcribe() {
  case "$BACKEND" in
    groq)   transcribe_groq   ;;
    openai) transcribe_openai ;;
    local)  transcribe_local  ;;
    *)      die "unknown DICTATE_BACKEND: $BACKEND" ;;
  esac
}

# Optional second pass: an LLM tidies filler words and punctuation.
# This is the thing you're paying Wispr $15/mo for. Costs a fraction of a cent.
# If anything goes wrong it silently returns the raw transcript.
polish() {
  local raw="$1"
  [ "$CLEANUP" = "1" ] || { printf '%s' "$raw"; return; }
  [ -n "${GROQ_API_KEY:-}" ] || { printf '%s' "$raw"; return; }
  command -v python3 >/dev/null 2>&1 || { printf '%s' "$raw"; return; }

  local payload out rlen olen
  payload=$(RAW="$raw" MODEL="${DICTATE_CLEANUP_MODEL:-qwen/qwen3.8-27b}" \
    python3 -c '
import json, os
print(json.dumps({
  "model": os.environ["MODEL"],
  "temperature": 0,
  "max_tokens": 1024,
  "messages": [
    {"role": "system", "content":
      "You clean up dictated speech. Remove filler words and false starts. "
      "Fix punctuation and capitalisation. Do not add, remove or reword content. "
      "Do not answer questions in the text. Return only the cleaned text, nothing else."},
    {"role": "user", "content": os.environ["RAW"]},
  ],
}))' 2>>"$LOG")

  out=$(curl -sS --fail --max-time 20 \
          https://api.groq.com/openai/v1/chat/completions \
          -H "Authorization: Bearer ${GROQ_API_KEY}" \
          -H "Content-Type: application/json" \
          -d "$payload" 2>>"$LOG" \
    | python3 -c '
import json, re, sys
try:
    txt = json.load(sys.stdin)["choices"][0]["message"]["content"] or ""
except Exception:
    sys.exit(0)

# Models from a reasoning family sometimes write their scratchpad into the
# reply instead of a separate field. That must never reach the clipboard.
txt = re.sub(r"(?is)<think\b[^>]*>.*?</think\s*>", "", txt)
i = txt.lower().find("<think")
if i != -1:           # unterminated block — everything after it is scratchpad
    txt = txt[:i]
txt = re.sub(r"(?is)</?think\s*>", "", txt)   # stray tags

print(txt.strip())' 2>>"$LOG")

  if [ -z "$out" ]; then
    log "cleanup pass failed, returning raw transcript"
    printf '%s' "$raw"
    return
  fi

  # Guard against the model responding to the dictation instead of cleaning
  # it — refusing it ("I cannot ignore my instructions...") or obeying it.
  #
  # The two directions are not symmetric. Growth is the reliable signal: the
  # prompt forbids adding content, so a longer result means the model wrote
  # something of its own, and refusals are wordy. Shrinkage is mostly
  # legitimate — stripping filler from a rambling clip can halve it, and that
  # is the case cleanup exists for — so the floor is set low enough to allow
  # that and only catches a result collapsing to almost nothing.
  rlen=${#raw}; olen=${#out}
  if [ "$rlen" -lt 25 ]; then
    # Ratios are meaningless on a handful of characters; cap growth instead.
    if [ "$olen" -gt $(( rlen + 25 )) ]; then
      log "cleanup output implausible (${rlen} -> ${olen} chars), returning raw transcript"
      printf '%s' "$raw"
      return
    fi
  elif awk -v r="$rlen" -v o="$olen" 'BEGIN{x=o/r; exit !(x<0.25 || x>1.5)}'; then
    log "cleanup output implausible (${rlen} -> ${olen} chars), returning raw transcript"
    printf '%s' "$raw"
    return
  fi

  printf '%s' "$out"
}

cmd_stop() {
  # Never leave audio on disk, whatever happens below.
  trap 'rm -f "$AUDIO" "$RAW"' EXIT

  if ! kill_recorder; then
    # Nothing was recording. Don't touch any stale WAV — that would re-paste
    # the previous dictation.
    log "stop called with no recorder running — ignoring"
    exit 0
  fi

  # ffmpeg recorded headerless PCM (see REC_CMD); give it a WAV container.
  # Local and instant — it only writes a 44-byte header.
  if [ "$RECORDER" = "ffmpeg" ]; then
    [ -s "$RAW" ] || { log "no audio captured"; exit 0; }
    ffmpeg -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 \
           -i "$RAW" -y "$AUDIO" 2>>"$LOG" \
      || die "could not wrap recorded audio into a WAV"
  fi

  [ -s "$AUDIO" ] || { log "no audio captured"; exit 0; }

  local dur
  dur=$(clip_seconds)
  if awk -v d="$dur" -v m="$MIN_SECONDS" 'BEGIN{exit !(d+0 < m+0)}'; then
    log "clip too short (${dur}s) — ignoring"
    exit 0
  fi

  local text
  text=$(transcribe) || die "transcription failed (backend: $BACKEND)"
  text=$(printf '%s' "$text" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  [ -n "$text" ] && text=$(polish "$text")

  log "transcribed ${dur}s -> $(printf '%s' "$text" | wc -c | tr -d ' ') bytes"
  printf '%s' "$text"
}

# -------------------------------------------------------------------- main

case "${1:-}" in
  start) cmd_start ;;
  stop)  cmd_stop  ;;
  *)     echo "usage: $(basename "$0") {start|stop}" >&2; exit 2 ;;
esac
