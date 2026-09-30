#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/config.sh"
source "$SCRIPT_DIR/common.sh"

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
echo "$AUDIO" > "$TRANSCRIBING_FILE_FILE"
TMP_DIR="$(mktemp -d -t meetingscribe)"
# 状態ファイルは自分が書いたときだけ消す（並行実行時に他方の実行中表示を壊さない）
trap '[[ "$(cat "$TRANSCRIBING_PID_FILE" 2>/dev/null)" == "$$" ]] && rm -f "$TRANSCRIBING_PID_FILE" "$TRANSCRIBING_FILE_FILE"; rm -rf "$TMP_DIR"' EXIT

BASENAME="$(basename "$AUDIO")"
BODY="$TMP_DIR/body.md"
META="$TMP_DIR/note-meta.json"

generate_meta() {
  [[ -x "${CODEX_BIN:-}" ]] || return 1

  # codex は stdin をログにエコーするため、成功時は record.log に残さない（肥大するので）
  local codex_log="$TMP_DIR/codex.log" attempt
  for attempt in 1 2; do
    # Vault は git リポジトリではないので --skip-git-repo-check は必須
    "$CODEX_BIN" exec -s read-only --skip-git-repo-check \
      --output-schema "$SCRIPT_DIR/note-schema.json" -o "$META" \
      "$(cat "$SCRIPT_DIR/note-prompt.md")" \
      < "$BODY" >"$codex_log" 2>&1 && [[ -s "$META" ]] && return 0
    echo "warn: 要約の生成に失敗しました (attempt $attempt)" >&2
    cat "$codex_log" >>"$LOG_FILE"
  done
  return 1
}

CHANNELS="$("$FFPROBE_BIN" -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$AUDIO")"

if [[ "$CHANNELS" == "2" ]]; then
  split_stereo "$TMP_DIR" -nostdin -i "$AUDIO" || fail "チャンネル分離に失敗しました"

  run_whisper "$TMP_DIR/self.wav" "$TMP_DIR/self" -oj || fail "whisper の実行に失敗しました（自分）"
  run_whisper "$TMP_DIR/others.wav" "$TMP_DIR/others" -oj || fail "whisper の実行に失敗しました（相手）"

  /usr/bin/python3 "$SCRIPT_DIR/merge_transcript.py" "$TMP_DIR/self.json" "$TMP_DIR/others.json" \
    > "$BODY" || fail "文字起こし結果のマージに失敗しました"
else
  WAV="$TMP_DIR/audio.wav"
  run_ffmpeg -nostdin -i "$AUDIO" -ac 1 -ar 16000 "$WAV" || fail "wav 変換に失敗しました"
  run_whisper "$WAV" "$TMP_DIR/plain" -otxt || fail "whisper の実行に失敗しました"
  cp "$TMP_DIR/plain.txt" "$BODY"
fi

if [[ ! -s "$BODY" ]]; then
  rm -f "$AUDIO"
  echo "silent: deleted $AUDIO" >&2
  notify "発話が検出されなかったため音源を削除しました: $BASENAME"
  exit 0
fi

generate_meta

NOTE="$(/usr/bin/python3 "$SCRIPT_DIR/build_note.py" \
  --body "$BODY" --recording "$BASENAME" --out-dir "$VAULT_MEETINGS_DIR" --meta "$META")" \
  || fail "ノートの作成に失敗しました"

notify "文字起こしが完了しました: $(basename "$NOTE")"
echo "note: $NOTE"
