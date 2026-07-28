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
BODY="$TMP_DIR/body.md"

# 文字起こし本文から タイトル / タグ / 要約 を codex に作らせる。
# 標準出力の 1 行目=タイトル、2 行目=タグ(カンマ区切り)、3 行目以降=要約。
# 失敗したら非ゼロを返し、呼び出し側が従来どおりのノートにフォールバックする
generate_meta() {
  [[ -n "${CODEX_BIN:-}" && -x "$CODEX_BIN" ]] || return 1

  local schema="$TMP_DIR/note-schema.json" result="$TMP_DIR/note-meta.json"
  # codex は受け取った stdin をログにエコーするので、成功時は record.log に残さない
  # （毎回文字起こし全文が追記されてログが肥大する）。失敗時だけ原因調査用に転記する
  local codex_log="$TMP_DIR/codex.log"
  cat > "$schema" <<'JSON'
{
  "type": "object",
  "properties": {
    "title": { "type": "string", "description": "会議内容が分かる簡潔な日本語タイトル。30文字以内" },
    "tags": { "type": "array", "items": { "type": "string" }, "description": "内容を表すタグ 2〜4 個" },
    "summary": { "type": "string", "description": "要約。決定事項とアクションアイテムを箇条書きで" }
  },
  "required": ["title", "tags", "summary"],
  "additionalProperties": false
}
JSON

  # Vault は git リポジトリではないので --skip-git-repo-check が必須（無いと即エラー終了する）
  "$CODEX_BIN" exec -s read-only --skip-git-repo-check \
    --output-schema "$schema" -o "$result" \
    '以下は会議の文字起こしです。JSON で title / tags / summary を返してください。

- title: 内容が分かる簡潔な日本語タイトル（30文字以内）
- tags: 内容を表すタグ 2〜4 個。日本語・英語どちらでも可
- summary: 決定事項とアクションアイテムを箇条書きで。無い場合は話題の要点を箇条書きで' \
    < "$BODY" >"$codex_log" 2>&1 || { cat "$codex_log" >>"$LOG_FILE"; return 1; }

  [[ -s "$result" ]] || return 1
  /usr/bin/python3 - "$result" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

# タイトルはファイル名に使うので、パス区切りと Windows/macOS の禁止文字を落とす
title = re.sub(r'[/:*?"<>|\\]', "", str(data.get("title", ""))).strip()
# タグは frontmatter の [a, b] 形式に入れるため、区切りと衝突する文字を落とす
tags = []
for tag in data.get("tags") or []:
    tag = re.sub(r"[,\[\]]", "", str(tag)).strip()
    if tag:
        tags.append(tag)

print(title)
print(",".join(tags))
print(str(data.get("summary", "")).strip())
PY
}

# VAD（音声区間検出）を必ず通す。無音・環境ノイズだけの区間を whisper にかけると
# 「ご視聴ありがとうございました」等の幻聴を出すため、発話区間だけを対象にする
run_whisper() {  # $1: 16kHz mono wav, $2: 出力ベースパス（.json / .txt が付く）, $3: 出力形式フラグ
  "$WHISPER_BIN" -m "$MODEL" -l "$WHISPER_LANG" -f "$1" "$3" -of "$2" -np \
    --vad --vad-model "$VAD_MODEL" 2>>"$LOG_FILE"
}

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

TITLE="会議メモ $STAMP"
TAGS="meeting"
SUMMARY=""
if META="$(generate_meta)"; then
  META_TITLE="$(sed -n '1p' <<<"$META")"
  META_TAGS="$(sed -n '2p' <<<"$META")"
  SUMMARY="$(sed -n '3,$p' <<<"$META")"
  [[ -n "$META_TITLE" ]] && TITLE="$META_TITLE"
  [[ -n "$META_TAGS" ]] && TAGS="meeting,$META_TAGS"
else
  echo "warn: 要約の生成に失敗しました。文字起こしのみのノートを作ります" >&2
fi

NOTE="$VAULT_MEETINGS_DIR/$STAMP $TITLE.md"

{
  echo "---"
  echo "date: $(date +%Y-%m-%dT%H:%M:%S)"
  echo "recording: $BASENAME"
  echo "title: $TITLE"
  echo "tags: [$TAGS]"
  echo "---"
  echo
  echo "# $TITLE"
  echo
  if [[ -n "$SUMMARY" ]]; then
    echo "## 要約"
    echo
    echo "$SUMMARY"
    echo
  fi
  echo "## 文字起こし"
  echo
  cat "$BODY"
} > "$NOTE"

notify "文字起こしが完了しました: $(basename "$NOTE")"
echo "note: $NOTE"
