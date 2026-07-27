#!/bin/bash
# record.sh — 会議録音のコントローラ
# 使い方: record.sh toggle | start | stop | status
#   status は stdout に "recording" / "transcribing" / "idle" を出力する
# 録音は MeetingScribeRecorder（Core Audio タップ）が行う:
#   L=デフォルト入力（自分の声） / R=システム音声（会議相手の声）
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

RECORDER="$SCRIPT_DIR/MeetingScribeRecorder"
PID_FILE="$SCRIPT_DIR/.recording.pid"
FILE_FILE="$SCRIPT_DIR/.recording.file"
STARTED_FILE="$SCRIPT_DIR/.recording.started"
TRANSCRIBING_PID_FILE="$SCRIPT_DIR/.transcribing.pid"
LOG_FILE="$SCRIPT_DIR/record.log"

# PID 生存確認だけでなくプロセス名も検証する
# （クラッシュ後の stale PID が別プロセスに再利用されていた場合の誤 kill を防ぐ）
is_recording() {
  [[ -f "$PID_FILE" ]] || return 1
  [[ "$(ps -p "$(cat "$PID_FILE")" -o comm= 2>/dev/null)" == *MeetingScribeRecorder* ]]
}

is_transcribing() {
  [[ -f "$TRANSCRIBING_PID_FILE" ]] || return 1
  [[ "$(ps -p "$(cat "$TRANSCRIBING_PID_FILE")" -o comm= 2>/dev/null)" == *bash* ]]
}

clear_recording_state() {
  rm -f "$PID_FILE" "$FILE_FILE" "$STARTED_FILE"
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

  local outfile pid
  outfile="$RECORDINGS_DIR/meeting-$(date +%Y%m%d-%H%M%S).m4a"
  nohup "$RECORDER" "$outfile" >>"$LOG_FILE" 2>&1 &
  pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "error: recorder failed to start (see $LOG_FILE)" >&2
    return 1
  fi
  echo "$pid" > "$PID_FILE"
  echo "$outfile" > "$FILE_FILE"
  date +%s > "$STARTED_FILE"
  echo "started: $outfile"
}

cmd_stop() {
  if ! is_recording; then
    clear_recording_state
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

  if [[ -n "$outfile" && -f "$outfile" ]]; then
    nohup "$SCRIPT_DIR/transcribe.sh" "$outfile" >>"$LOG_FILE" 2>&1 &
    # transcribe.sh 自身が pid を書くまでの間も status が "transcribing" を返せるよう親側でも書く
    echo $! > "$TRANSCRIBING_PID_FILE"
    echo "stopped: $outfile (transcribing in background)"
  else
    echo "stopped (no output file)" >&2
  fi
}

case "${1:-}" in
  status) cmd_status ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  toggle) if is_recording; then cmd_stop; else cmd_start; fi ;;
  *) echo "usage: $0 toggle|start|stop|status" >&2; exit 1 ;;
esac
