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
