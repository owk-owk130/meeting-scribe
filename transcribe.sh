#!/bin/bash
# transcribe.sh — 録音ファイルを whisper-cpp で文字起こしして Obsidian Vault にノートを作る
# 使い方: transcribe.sh <audio-file>
# ステレオ録音（L=自分 / R=相手）なら L/R を別々に文字起こしして話者ラベル付きノートにする。
# モノラル、または R が無音（対面会議・システム音声なし）なら従来どおりのプレーンな文字起こし。
# 実行中は .transcribing.pid を置き、record.sh status が "transcribing" を返せるようにする
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
MODEL="$SCRIPT_DIR/models/ggml-large-v3-turbo.bin"
WHISPER_LANG="ja"
TRANSCRIBING_PID_FILE="$SCRIPT_DIR/.transcribing.pid"
LOG_FILE="$SCRIPT_DIR/record.log"
SILENCE_THRESHOLD_DB=-50

notify() {
  osascript -e "display notification \"$1\" with title \"MeetingScribe\"" 2>/dev/null || true
}

fail() {
  echo "error: $1" >&2
  notify "文字起こし失敗: $1"
  exit 1
}

AUDIO="${1:-}"
[[ -f "$AUDIO" ]] || fail "音声ファイルが見つかりません: $AUDIO"
[[ -x "$WHISPER_BIN" ]] || fail "whisper-cli がありません (brew install whisper-cpp)"
[[ -f "$MODEL" ]] || fail "モデルがありません: $MODEL"

mkdir -p "$VAULT_MEETINGS_DIR"

echo $$ > "$TRANSCRIBING_PID_FILE"
TMP_DIR="$(mktemp -d -t meetingscribe)"
# pid ファイルは自分が書いたときだけ消す（並行実行時に他方の実行中表示を壊さない）
trap '[[ "$(cat "$TRANSCRIBING_PID_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$TRANSCRIBING_PID_FILE"; rm -rf "$TMP_DIR"' EXIT

BASENAME="$(basename "$AUDIO")"
STAMP="$(date +%Y-%m-%d-%H%M%S)"   # 秒まで含めて同名ノートの上書きを防ぐ
NOTE="$VAULT_MEETINGS_DIR/$STAMP 会議メモ.md"
BODY="$TMP_DIR/body.md"

run_whisper() {  # $1: 16kHz mono wav, $2: 出力ベースパス（.json / .txt が付く）, $3: 出力形式フラグ
  "$WHISPER_BIN" -m "$MODEL" -l "$WHISPER_LANG" -f "$1" "$3" -of "$2" -np 2>>"$LOG_FILE"
}

is_silent() {  # $1: wav — 平均音量が閾値未満なら無音扱い（無音を whisper にかけると幻聴を出す）
  local mean
  mean="$(ffmpeg -nostdin -i "$1" -af volumedetect -f null - 2>&1 | sed -n 's/.*mean_volume: \([-0-9.]*\) dB.*/\1/p')"
  [[ -z "$mean" ]] && return 0
  awk -v m="$mean" -v t="$SILENCE_THRESHOLD_DB" 'BEGIN { exit !(m < t) }'
}

notify "文字起こしを開始しました"

CHANNELS="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$AUDIO")"

if [[ "$CHANNELS" == "2" ]]; then
  # L=自分 / R=相手 に分離して 16kHz mono wav へ
  ffmpeg -nostdin -hide_banner -y -i "$AUDIO" \
    -filter_complex "[0:a]channelsplit=channel_layout=stereo[l][r]" \
    -map "[l]" -ac 1 -ar 16000 "$TMP_DIR/self.wav" \
    -map "[r]" -ac 1 -ar 16000 "$TMP_DIR/others.wav" \
    2>>"$LOG_FILE" || fail "チャンネル分離に失敗しました"
fi

if [[ "$CHANNELS" == "2" ]] && ! is_silent "$TMP_DIR/others.wav"; then
  # 話者ラベル付き: 各チャンネルを個別に文字起こしし、タイムスタンプでマージ
  if ! is_silent "$TMP_DIR/self.wav"; then
    run_whisper "$TMP_DIR/self.wav" "$TMP_DIR/self" -oj || fail "whisper の実行に失敗しました（自分）"
  fi
  run_whisper "$TMP_DIR/others.wav" "$TMP_DIR/others" -oj || fail "whisper の実行に失敗しました（相手）"

  /usr/bin/python3 - "$TMP_DIR/self.json" "$TMP_DIR/others.json" > "$BODY" <<'PY' || fail "文字起こし結果のマージに失敗しました"
import json
import sys


def load(path, label):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError:
        return []
    segments = []
    for seg in data.get("transcription", []):
        text = seg["text"].strip()
        if text:
            segments.append((seg["offsets"]["from"], label, text))
    return segments


merged = sorted(load(sys.argv[1], "自分") + load(sys.argv[2], "相手"))
for offset_ms, label, text in merged:
    minutes, seconds = divmod(offset_ms // 1000, 60)
    print(f"- [{minutes:02d}:{seconds:02d}] **{label}**: {text}")
PY
else
  # プレーン: モノラル録音、またはシステム音声なし（対面会議など）
  if [[ "$CHANNELS" == "2" ]]; then
    WAV="$TMP_DIR/self.wav"
  else
    WAV="$TMP_DIR/audio.wav"
    ffmpeg -nostdin -hide_banner -y -i "$AUDIO" -ac 1 -ar 16000 "$WAV" 2>>"$LOG_FILE" \
      || fail "wav 変換に失敗しました"
  fi
  is_silent "$WAV" && fail "録音が無音のため文字起こしをスキップしました"
  run_whisper "$WAV" "$TMP_DIR/plain" -otxt || fail "whisper の実行に失敗しました"
  cp "$TMP_DIR/plain.txt" "$BODY"
fi

[[ -s "$BODY" ]] || fail "文字起こし結果が空です"

{
  echo "---"
  echo "date: $(date +%Y-%m-%dT%H:%M:%S)"
  echo "recording: $BASENAME"
  echo "tags: [meeting]"
  echo "---"
  echo
  echo "# 会議メモ $STAMP"
  echo
  echo "## 文字起こし"
  echo
  cat "$BODY"
} > "$NOTE"

notify "文字起こしが完了しました: $(basename "$NOTE")"
echo "note: $NOTE"
