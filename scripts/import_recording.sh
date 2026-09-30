#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/config.sh"
source "$SCRIPT_DIR/common.sh"

fail() {
  echo "error: $1" >&2
  notify "録音の取り込みに失敗: $1"
  exit 1
}

SRC="${1:-}"
[[ -f "$SRC" ]] || fail "音声ファイルが見つかりません: $SRC"
[[ -x "$FFMPEG_BIN" ]] || fail "ffmpeg がありません (brew install ffmpeg)"

mkdir -p "$RECORDINGS_DIR"

STAMP="$(stat -f %SB -t %Y%m%d-%H%M%S "$SRC")"
NAME="meeting-$STAMP.m4a"
n=2
while [[ -e "$RECORDINGS_DIR/$NAME" ]]; do
  NAME="meeting-$STAMP-$n.m4a"
  n=$((n + 1))
done

# transcribe.sh は 2ch を自分/相手の話者分けとみなすので、スマホのステレオ録音は必ずモノラルにする
# 変換途中のファイルが未完了の文字起こしに出ないよう、隠しファイルに書いてから移す
TMP=".$NAME"
run_ffmpeg -nostdin -i "$SRC" -vn -ac 1 -c:a aac "$RECORDINGS_DIR/$TMP" \
  || { rm -f "$RECORDINGS_DIR/$TMP"; fail "変換に失敗しました: $(basename "$SRC")"; }
mv "$RECORDINGS_DIR/$TMP" "$RECORDINGS_DIR/$NAME"
rm -f "$SRC"

exec /bin/bash "$SCRIPT_DIR/transcribe.sh" "$RECORDINGS_DIR/$NAME"
