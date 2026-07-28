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
VAD_MODEL="$SCRIPT_DIR/models/ggml-silero-v5.1.2.bin"
WHISPER_LANG="ja"
TRANSCRIBING_PID_FILE="$SCRIPT_DIR/.transcribing.pid"
LOG_FILE="$SCRIPT_DIR/record.log"

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
[[ -f "$VAD_MODEL" ]] || fail "VAD モデルがありません: $VAD_MODEL"

mkdir -p "$VAULT_MEETINGS_DIR"

echo $$ > "$TRANSCRIBING_PID_FILE"
TMP_DIR="$(mktemp -d -t meetingscribe)"
# pid ファイルは自分が書いたときだけ消す（並行実行時に他方の実行中表示を壊さない）
trap '[[ "$(cat "$TRANSCRIBING_PID_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$TRANSCRIBING_PID_FILE"; rm -rf "$TMP_DIR"' EXIT

BASENAME="$(basename "$AUDIO")"
STAMP="$(date +%Y-%m-%d-%H%M%S)"   # 秒まで含めて同名ノートの上書きを防ぐ
NOTE="$VAULT_MEETINGS_DIR/$STAMP 会議メモ.md"
BODY="$TMP_DIR/body.md"

# VAD（音声区間検出）を必ず通す。無音・環境ノイズだけの区間を whisper にかけると
# 「ご視聴ありがとうございました」等の幻聴を出すため、発話区間だけを対象にする
run_whisper() {  # $1: 16kHz mono wav, $2: 出力ベースパス（.json / .txt が付く）, $3: 出力形式フラグ
  "$WHISPER_BIN" -m "$MODEL" -l "$WHISPER_LANG" -f "$1" "$3" -of "$2" -np \
    --vad --vad-model "$VAD_MODEL" 2>>"$LOG_FILE"
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

if [[ "$CHANNELS" == "2" ]]; then
  # 各チャンネルを個別に文字起こしし、タイムスタンプでマージする。
  # 相手チャンネルに発話がなければ（対面会議など）ラベルなしのプレーン出力にする
  run_whisper "$TMP_DIR/self.wav" "$TMP_DIR/self" -oj || fail "whisper の実行に失敗しました（自分）"
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


mine = load(sys.argv[1], "自分")
others = load(sys.argv[2], "相手")
if others:
    for offset_ms, label, text in sorted(mine + others):
        minutes, seconds = divmod(offset_ms // 1000, 60)
        print(f"- [{minutes:02d}:{seconds:02d}] **{label}**: {text}")
else:
    for _, _, text in sorted(mine):
        print(text)
PY
else
  WAV="$TMP_DIR/audio.wav"
  ffmpeg -nostdin -hide_banner -y -i "$AUDIO" -ac 1 -ar 16000 "$WAV" 2>>"$LOG_FILE" \
    || fail "wav 変換に失敗しました"
  run_whisper "$WAV" "$TMP_DIR/plain" -otxt || fail "whisper の実行に失敗しました"
  cp "$TMP_DIR/plain.txt" "$BODY"
fi

[[ -s "$BODY" ]] || fail "発話が検出されませんでした（無音の録音の可能性）"

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
