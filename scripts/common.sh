: "${WHISPER_BIN:=/opt/homebrew/bin/whisper-cli}"
: "${FFMPEG_BIN:=/opt/homebrew/bin/ffmpeg}"
: "${FFPROBE_BIN:=/opt/homebrew/bin/ffprobe}"
MODEL="$ROOT_DIR/models/ggml-large-v3-turbo.bin"
VAD_MODEL="$ROOT_DIR/models/ggml-silero-v5.1.2.bin"
WHISPER_LANG="ja"
STATE_DIR="$ROOT_DIR/state"
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/record.log"
TRANSCRIBING_PID_FILE="$STATE_DIR/transcribing.pid"
TRANSCRIBING_FILE_FILE="$STATE_DIR/transcribing.file"

notify() {
  osascript -e "display notification \"$1\" with title \"MeetingScribe\"" 2>/dev/null || true
}

# VAD（音声区間検出）を必ず通す。無音・環境ノイズだけの区間は whisper が幻聴を出すため
run_whisper() {
  "$WHISPER_BIN" -m "$MODEL" -l "$WHISPER_LANG" -f "$1" "$3" -of "$2" -np \
    --vad --vad-model "$VAD_MODEL" >/dev/null 2>>"$LOG_FILE"
}

# codex は stdin をログにエコーするため、成功時は record.log に残さない（肥大するので）
# Vault は git リポジトリではないので --skip-git-repo-check は必須
generate_meta() {
  local body="$1" meta="$2" codex_log="$TMP_DIR/codex.log" attempt
  [[ -x "${CODEX_BIN:-}" ]] || return 1
  for attempt in 1 2; do
    "$CODEX_BIN" exec -s read-only --skip-git-repo-check \
      --output-schema "$SCRIPT_DIR/note-schema.json" -o "$meta" \
      "$(cat "$SCRIPT_DIR/note-prompt.md")" \
      < "$body" >"$codex_log" 2>&1 && [[ -s "$meta" ]] && return 0
    echo "warn: 要約の生成に失敗しました (attempt $attempt)" >&2
    cat "$codex_log" >>"$LOG_FILE"
  done
  return 1
}

run_ffmpeg() {
  "$FFMPEG_BIN" -hide_banner -y "$@" 2>>"$LOG_FILE"
}

split_stereo() {
  local out_dir="$1"; shift
  run_ffmpeg "$@" \
    -filter_complex "[0:a]channelsplit=channel_layout=stereo[l][r]" \
    -map "[l]" -ac 1 -ar 16000 "$out_dir/self.wav" \
    -map "[r]" -ac 1 -ar 16000 "$out_dir/others.wav"
}
