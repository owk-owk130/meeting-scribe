WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
FFPROBE_BIN="/opt/homebrew/bin/ffprobe"
MODEL="$SCRIPT_DIR/models/ggml-large-v3-turbo.bin"
VAD_MODEL="$SCRIPT_DIR/models/ggml-silero-v5.1.2.bin"
WHISPER_LANG="ja"
LOG_FILE="$SCRIPT_DIR/record.log"

# VAD（音声区間検出）を必ず通す。無音・環境ノイズだけの区間は whisper が幻聴を出すため
run_whisper() {
  "$WHISPER_BIN" -m "$MODEL" -l "$WHISPER_LANG" -f "$1" "$3" -of "$2" -np \
    --vad --vad-model "$VAD_MODEL" 2>>"$LOG_FILE"
}
