#!/bin/bash
# transcribe-live.sh — 録音中の raw PCM を一定間隔で文字起こしし、transcript へ追記する
# 使い方: transcribe-live.sh <live.pcm> <transcript-out>
# record.sh start が起動し、stop で kill される（pcm が消えた時点でも自然に終了する）
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/whisper-common.sh"

INTERVAL="${LIVE_INTERVAL_SECS:-30}"
BYTES_PER_FRAME=8   # 2ch × float32

PCM="${1:-}"
TRANSCRIPT="${2:-}"
[[ -n "$PCM" && -n "$TRANSCRIPT" ]] || { echo "usage: $0 <live.pcm> <transcript-out>" >&2; exit 1; }

TMP_DIR="$(mktemp -d -t meetingscribe-live)"
trap 'rm -rf "$TMP_DIR"' EXIT
# 実行中の whisper ごと止める。残すと最終文字起こしとモデルが同時に走る。
# バックグラウンドの run_whisper はサブシェルなので、その子（whisper-cli）から先に殺す
kill_jobs() {
  local p
  for p in $(jobs -p); do
    pkill -TERM -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
}
trap 'kill_jobs; exit 0' TERM INT

for _ in $(seq 1 50); do
  [[ -s "$PCM.rate" ]] && break
  sleep 0.2
done
RATE="$(cat "$PCM.rate" 2>/dev/null)"
[[ "$RATE" =~ ^[0-9]+$ ]] || { echo "error: live pcm のレートを読めません" >&2; exit 1; }

OFFSET=0
while sleep "$INTERVAL"; do
  [[ -f "$PCM" ]] || break
  SIZE="$(stat -f %z "$PCM" 2>/dev/null)" || break
  SIZE=$(( SIZE / BYTES_PER_FRAME * BYTES_PER_FRAME ))   # フレーム境界に丸める
  CHUNK=$(( SIZE - OFFSET ))
  (( CHUNK >= RATE * BYTES_PER_FRAME * 2 )) || continue  # 2 秒未満なら次の間隔まで待つ

  tail -c "+$((OFFSET + 1))" "$PCM" | head -c "$CHUNK" \
    | "$FFMPEG_BIN" -hide_banner -y -f f32le -ar "$RATE" -ac 2 -i pipe:0 \
        -filter_complex "[0:a]channelsplit=channel_layout=stereo[l][r]" \
        -map "[l]" -ac 1 -ar 16000 "$TMP_DIR/self.wav" \
        -map "[r]" -ac 1 -ar 16000 "$TMP_DIR/others.wav" \
        2>>"$LOG_FILE" || continue

  OFFSET_MS=$(( OFFSET / BYTES_PER_FRAME * 1000 / RATE ))
  OFFSET=$(( OFFSET + CHUNK ))

  # 自分/相手は独立なので並列にかけ、窓あたりの遅延を抑える
  run_whisper "$TMP_DIR/self.wav" "$TMP_DIR/self" -oj & SELF_PID=$!
  run_whisper "$TMP_DIR/others.wav" "$TMP_DIR/others" -oj & OTHERS_PID=$!
  wait "$SELF_PID"; SELF_RC=$?
  wait "$OTHERS_PID"; OTHERS_RC=$?
  (( SELF_RC == 0 && OTHERS_RC == 0 )) || continue

  /usr/bin/python3 "$SCRIPT_DIR/merge_transcript.py" "$TMP_DIR/self.json" "$TMP_DIR/others.json" \
    --offset-ms "$OFFSET_MS" --labels always >> "$TRANSCRIPT"
done
