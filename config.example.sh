# config.sh — record.sh / transcribe.sh / MeetingScribe.app が共有する設定
# このファイルを config.sh にコピーして自分の環境に合わせて編集する:
#   cp config.example.sh config.sh
# アプリは起動時にこのファイルを読むので、変更後の再ビルドは不要（アプリ再起動のみ）

# 録音ファイル（m4a）の保存先
RECORDINGS_DIR="$HOME/MeetingRecordings"

# 文字起こしノート（md）の出力先。Obsidian Vault 内のフォルダを指定すると
# Obsidian に自動で現れる（ただのフォルダなので Vault でなくてもよい）
VAULT_DIR="$HOME/path/to/your/vault"
VAULT_MEETINGS_DIR="$VAULT_DIR/Meetings"

# 録音デバイスの指定は不要:
#   マイク = システムのデフォルト入力（AirPods 接続中は AirPods マイク）
#   相手の声 = Core Audio プロセスタップ（出力デバイスに関係なくシステム音声を取得）
