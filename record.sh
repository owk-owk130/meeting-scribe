#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/common.sh"

RECORDER="$SCRIPT_DIR/MeetingScribeRecorder"
PID_FILE="$SCRIPT_DIR/.recording.pid"
FILE_FILE="$SCRIPT_DIR/.recording.file"
STARTED_FILE="$SCRIPT_DIR/.recording.started"
LIVE_PCM="$SCRIPT_DIR/.live.pcm"
LIVE_TRANSCRIPT="$SCRIPT_DIR/.live-transcript.md"
LIVE_PID_FILE="$SCRIPT_DIR/.live.pid"

# PID 生存確認だけでなくプロセス名も検証する
# （クラッシュ後の stale PID が別プロセスに再利用されていた場合の誤 kill を防ぐ）
pid_file_alive() {
  [[ -f "$1" ]] || return 1
  [[ "$(ps -p "$(cat "$1")" -o comm= 2>/dev/null)" == *"$2"* ]]
}

is_recording() {
  pid_file_alive "$PID_FILE" MeetingScribeRecorder
}

is_transcribing() {
  pid_file_alive "$TRANSCRIBING_PID_FILE" bash
}

transcribing_file() {
  is_transcribing && cat "$TRANSCRIBING_FILE_FILE" 2>/dev/null
}

start_transcription() {
  nohup "$SCRIPT_DIR/transcribe.sh" "$1" >>"$LOG_FILE" 2>&1 &
  # transcribe.sh 自身が書くまでの間も status / pending が正しく答えられるよう親側でも書く
  echo $! > "$TRANSCRIBING_PID_FILE"
  echo "$1" > "$TRANSCRIBING_FILE_FILE"
}

clear_recording_state() {
  rm -f "$PID_FILE" "$FILE_FILE" "$STARTED_FILE"
}

# watcher を止めてライブ用の中間ファイルを消す。recorder がクラッシュした後の
# 取り残された watcher も、次の start / stop で必ずここを通して片付ける
stop_live_watcher() {
  pid_file_alive "$LIVE_PID_FILE" bash && kill "$(cat "$LIVE_PID_FILE")" 2>/dev/null
  rm -f "$LIVE_PID_FILE" "$LIVE_PCM" "$LIVE_PCM.rate"
}

cmd_status() {
  if is_recording; then
    echo "recording"
  elif is_transcribing; then
    echo "transcribing"
  else
    echo "idle"
  fi
}

cmd_start() {
  if is_recording; then
    echo "already recording" >&2
    return 0
  fi
  if [[ ! -x "$RECORDER" ]]; then
    echo "error: recorder not found: $RECORDER (run ./build.sh)" >&2
    return 1
  fi
  mkdir -p "$RECORDINGS_DIR"

  local outfile pid live
  live="${LIVE_TRANSCRIBE:-1}"
  outfile="$RECORDINGS_DIR/meeting-$(date +%Y%m%d-%H%M%S).m4a"
  stop_live_watcher
  export SILENCE_STOP_MINS SILENCE_THRESHOLD_DB MAX_RECORD_MINS RECORD_SCRIPT="$SCRIPT_DIR/record.sh"
  if [[ "$live" == "1" ]]; then
    : > "$LIVE_TRANSCRIPT"
    nohup "$RECORDER" "$outfile" "$LIVE_PCM" >>"$LOG_FILE" 2>&1 &
  else
    nohup "$RECORDER" "$outfile" >>"$LOG_FILE" 2>&1 &
  fi
  pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "error: recorder failed to start (see $LOG_FILE)" >&2
    return 1
  fi
  echo "$pid" > "$PID_FILE"
  echo "$outfile" > "$FILE_FILE"
  date +%s > "$STARTED_FILE"
  if [[ "$live" == "1" ]]; then
    nohup "$SCRIPT_DIR/transcribe-live.sh" "$LIVE_PCM" "$LIVE_TRANSCRIPT" >>"$LOG_FILE" 2>&1 &
    echo $! > "$LIVE_PID_FILE"
  fi
  notify "録音を開始しました"
  echo "started: $outfile"
}

cmd_stop() {
  local reason="${1:-録音を停止しました}"
  if ! is_recording; then
    clear_recording_state
    stop_live_watcher
    echo "not recording" >&2
    return 0
  fi
  local pid outfile
  pid="$(cat "$PID_FILE")"
  outfile="$(cat "$FILE_FILE" 2>/dev/null || true)"

  # SIGINT でファイルを正常にファイナライズさせる
  kill -INT "$pid" 2>/dev/null
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  clear_recording_state

  stop_live_watcher

  if [[ -n "$outfile" && -f "$outfile" ]]; then
    start_transcription "$outfile"
    notify "${reason}。文字起こし中…"
    echo "stopped: $outfile (transcribing in background)"
  else
    echo "stopped (no output file)" >&2
  fi
}

cmd_pending() {
  local known
  # recording: は [a.m4a, b.m4a] のリスト形式もある
  known="$(
    grep -h '^recording:' "$VAULT_MEETINGS_DIR"/*.md 2>/dev/null | grep -o '[^][ ,]*\.m4a'
    cat "$FILE_FILE" 2>/dev/null; transcribing_file
  )"
  (cd "$RECORDINGS_DIR" && ls -r *.m4a 2>/dev/null) \
    | grep -vxF -f <(sed 's|.*/||' <<<"$known") | sed "s|^|$RECORDINGS_DIR/|"
}

cmd_transcribe() {
  local audio="${1:-}"
  [[ -f "$audio" ]] || { echo "error: file not found: $audio" >&2; return 1; }
  if is_transcribing; then
    echo "error: already transcribing: $(transcribing_file)" >&2
    return 1
  fi
  start_transcription "$audio"
  notify "文字起こしを開始しました: $(basename "$audio")"
  echo "transcribing: $audio"
}

case "${1:-}" in
  status)     cmd_status ;;
  start)      cmd_start ;;
  stop)       cmd_stop "${2:-}" ;;
  toggle)     if is_recording; then cmd_stop; else cmd_start; fi ;;
  pending)    cmd_pending ;;
  transcribe) cmd_transcribe "${2:-}" ;;
  *) echo "usage: $0 toggle|start|stop [reason]|status|pending|transcribe <file>" >&2; exit 1 ;;
esac
