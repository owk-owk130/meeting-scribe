#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/config.sh"
source "$SCRIPT_DIR/common.sh"

fail() {
  echo "error: $1" >&2
  notify "要約の再生成に失敗: $1"
  exit 1
}

NOTE="${1:-}"
[[ -f "$NOTE" ]] || fail "ノートが見つかりません: $NOTE"
[[ -x "${CODEX_BIN:-}" ]] || fail "codex がありません: ${CODEX_BIN:-}"

echo $$ > "$TRANSCRIBING_PID_FILE"
echo "$NOTE" > "$TRANSCRIBING_FILE_FILE"
TMP_DIR="$(mktemp -d -t meetingscribe-resum)"
trap '[[ "$(cat "$TRANSCRIBING_PID_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$TRANSCRIBING_PID_FILE" "$TRANSCRIBING_FILE_FILE"; rm -rf "$TMP_DIR"' EXIT

NOTE_DIR="$(dirname "$NOTE")"
BODY="$TMP_DIR/body.md"
META="$TMP_DIR/note-meta.json"

# recording: は [a.m4a, b.m4a] のリスト形式もあるので先頭だけ使う
RECORDING="$(grep -m1 '^recording:' "$NOTE" | grep -o '[^][ ,]*\.m4a' | head -1)"
[[ -n "$RECORDING" ]] || fail "frontmatter に recording がありません"
sed -n '/^## 文字起こし$/,$p' "$NOTE" | tail -n +3 > "$BODY"
[[ -s "$BODY" ]] || fail "文字起こしが空です"

build_codex_input "$BODY" "$RECORDING" "$TMP_DIR/codex-input.md"
generate_meta "$TMP_DIR/codex-input.md" "$META" || fail "codex が要約を返しませんでした"

NEW="$(/usr/bin/python3 "$SCRIPT_DIR/build_note.py" \
  --body "$BODY" --recording "$RECORDING" --out-dir "$TMP_DIR" --notes-dir "$NOTE_DIR" --meta "$META" \
  --event "$(event_sidecar "$RECORDING")")" \
  || fail "ノートの作成に失敗しました"

rm -f "$NOTE"
mv "$NEW" "$NOTE_DIR/"
notify "要約を再生成しました: $(basename "$NEW")"
echo "note: $NOTE_DIR/$(basename "$NEW")"
