#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/config.sh"
source "$SCRIPT_DIR/common.sh"

fail() {
  echo "error: $1" >&2
  exit 1
}

QUESTION="${1:-}"
[[ -n "$QUESTION" ]] || fail "質問が空です"
[[ -x "${CODEX_BIN:-}" ]] || fail "codex がありません: ${CODEX_BIN:-}"
[[ -d "$VAULT_MEETINGS_DIR" ]] || fail "ノートのフォルダがありません: $VAULT_MEETINGS_DIR"

TMP_DIR="$(mktemp -d -t meetingscribe-ask)"
trap 'rm -rf "$TMP_DIR"' EXIT
ANSWER="$TMP_DIR/answer.md"
CODEX_LOG="$TMP_DIR/codex.log"

# ノートの探索は codex 自身に grep させるので、Vault を作業ディレクトリにして読み取り専用で動かす
"$CODEX_BIN" exec -s read-only --skip-git-repo-check --ephemeral -C "$VAULT_MEETINGS_DIR" \
  -o "$ANSWER" "$(cat "$SCRIPT_DIR/ask-prompt.md")" <<<"$QUESTION" >"$CODEX_LOG" 2>&1 \
  && [[ -s "$ANSWER" ]] || { cat "$CODEX_LOG" >>"$LOG_FILE"; fail "codex が回答を返しませんでした"; }

# 回答ノートは Meetings 直下に置かない。直下は会議ノートの一覧・要約のやり直し・過去ノート候補の走査対象
OUT_DIR="$VAULT_MEETINGS_DIR/質問"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y-%m-%d-%H%M%S)"
SLUG="$(/usr/bin/python3 -c 'import re,sys; print(re.sub(r"[/:*?\"<>|\\\\\s]+", " ", sys.argv[1]).strip()[:40])' "$QUESTION")"
NOTE="$OUT_DIR/$STAMP ${SLUG:-質問}.md"

{
  printf -- '---\ndate: %s\ntags: [meeting-question]\n---\n\n# %s\n\n' "$(date +%Y-%m-%dT%H:%M:%S)" "${QUESTION//$'\n'/ }"
  cat "$ANSWER"
  printf '\n'
} > "$NOTE"

notify "回答ができました: $(basename "$NOTE")"
echo "note: $NOTE"
