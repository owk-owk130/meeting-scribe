#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/whisper-common.sh"

TRANSCRIBING_PID_FILE="$SCRIPT_DIR/.transcribing.pid"

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
[[ -x "$FFMPEG_BIN" && -x "$FFPROBE_BIN" ]] || fail "ffmpeg がありません (brew install ffmpeg)"
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

generate_meta() {
  [[ -x "${CODEX_BIN:-}" ]] || return 1

  local schema="$TMP_DIR/note-schema.json" result="$TMP_DIR/note-meta.json"
  # codex は stdin をログにエコーするため、成功時は record.log に残さない（肥大するので）
  local codex_log="$TMP_DIR/codex.log"
  cat > "$schema" <<'JSON'
{
  "type": "object",
  "properties": {
    "title": { "type": "string", "description": "会議内容が分かる簡潔な日本語タイトル。30文字以内" },
    "tags": { "type": "array", "items": { "type": "string" }, "description": "内容を表すタグ 2〜4 個" },
    "summary": { "type": "string", "description": "議論の概要。段落を分けた散文" },
    "topics": { "type": "array", "items": { "type": "string" }, "description": "主な論点" },
    "actions": { "type": "array", "items": { "type": "string" }, "description": "決定事項とアクションアイテム" }
  },
  "required": ["title", "tags", "summary", "topics", "actions"],
  "additionalProperties": false
}
JSON

  # Vault は git リポジトリではないので --skip-git-repo-check は必須
  "$CODEX_BIN" exec -s read-only --skip-git-repo-check \
    --output-schema "$schema" -o "$result" \
    '以下は会議の文字起こしです。JSON で title / tags / summary / topics / actions を返してください。

- title: 内容が分かる簡潔な日本語タイトル（30文字以内）
- tags: 内容を表すタグ 2〜4 個。日本語・英語どちらでも可
- summary: 議論の概要を散文で。何をなぜ議論し、どう結論づいたかが後から読んで分かるよう、
  背景・検討の流れ・理由まで書く。話題ごとに段落を分ける。箇条書きにはしない
- topics: 議論で挙がった主な論点。判断の根拠や補足も 1 項目 1 文で残す
- actions: 決定事項とアクションアイテム。担当・期限が話されていれば含める。無ければ空配列' \
    < "$BODY" >"$codex_log" 2>&1 || { cat "$codex_log" >>"$LOG_FILE"; return 1; }

  [[ -s "$result" ]] || return 1
  /usr/bin/python3 - "$result" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

# タイトルはファイル名に使うのでパス区切りなどを落とす
print(re.sub(r'[/:*?"<>|\\]', "", data["title"]).strip())
# タグは frontmatter の [a, b] 形式に入れるので区切りと衝突する文字を落とす
tags = (re.sub(r"[,\[\]]", "", tag).strip() for tag in data["tags"])
print(",".join(tag for tag in tags if tag))

print("## 要約")
print()
print(data["summary"].strip())
for heading, items in (("主な論点", data["topics"]), ("決定事項とアクション", data["actions"])):
    if not items:
        continue
    print()
    print(f"## {heading}")
    print()
    for item in items:
        print(f"- {item.strip()}")
PY
}

CHANNELS="$("$FFPROBE_BIN" -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$AUDIO")"

if [[ "$CHANNELS" == "2" ]]; then
  "$FFMPEG_BIN" -nostdin -hide_banner -y -i "$AUDIO" \
    -filter_complex "[0:a]channelsplit=channel_layout=stereo[l][r]" \
    -map "[l]" -ac 1 -ar 16000 "$TMP_DIR/self.wav" \
    -map "[r]" -ac 1 -ar 16000 "$TMP_DIR/others.wav" \
    2>>"$LOG_FILE" || fail "チャンネル分離に失敗しました"

  run_whisper "$TMP_DIR/self.wav" "$TMP_DIR/self" -oj || fail "whisper の実行に失敗しました（自分）"
  run_whisper "$TMP_DIR/others.wav" "$TMP_DIR/others" -oj || fail "whisper の実行に失敗しました（相手）"

  /usr/bin/python3 "$SCRIPT_DIR/merge_transcript.py" "$TMP_DIR/self.json" "$TMP_DIR/others.json" \
    > "$BODY" || fail "文字起こし結果のマージに失敗しました"
else
  WAV="$TMP_DIR/audio.wav"
  "$FFMPEG_BIN" -nostdin -hide_banner -y -i "$AUDIO" -ac 1 -ar 16000 "$WAV" 2>>"$LOG_FILE" \
    || fail "wav 変換に失敗しました"
  run_whisper "$WAV" "$TMP_DIR/plain" -otxt || fail "whisper の実行に失敗しました"
  cp "$TMP_DIR/plain.txt" "$BODY"
fi

[[ -s "$BODY" ]] || fail "発話が検出されませんでした（無音の録音の可能性）"

TITLE="会議メモ $STAMP"
TAGS="meeting"
SECTIONS=""
if META="$(generate_meta)"; then
  META_TITLE="$(sed -n '1p' <<<"$META")"
  META_TAGS="$(sed -n '2p' <<<"$META")"
  SECTIONS="$(sed -n '3,$p' <<<"$META")"
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
  if [[ -n "$SECTIONS" ]]; then
    echo "$SECTIONS"
    echo
  fi
  echo "## 文字起こし"
  echo
  cat "$BODY"
} > "$NOTE"

notify "文字起こしが完了しました: $(basename "$NOTE")"
echo "note: $NOTE"
