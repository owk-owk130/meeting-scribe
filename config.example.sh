# config.sh — record.sh / transcribe.sh / MeetingScribe.app が共有する設定
# アプリは起動時にこのファイルを読むので、変更後の再ビルドは不要（アプリ再起動のみ）

# 録音ファイル（m4a）の保存先
RECORDINGS_DIR="$HOME/MeetingRecordings"

# 文字起こしノート（md）の出力先
VAULT_DIR="$HOME/path/to/your/vault"
VAULT_MEETINGS_DIR="$VAULT_DIR/Meetings"

# 要約・タイトル・タグの生成に使う codex CLI。アプリ起動時は PATH が最小なので絶対パスで指定する。
# 空にすると要約なしのノートになる
CODEX_BIN="$HOME/.local/share/mise/shims/codex"
