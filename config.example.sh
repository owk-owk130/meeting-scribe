RECORDINGS_DIR="$HOME/MeetingRecordings"

VAULT_DIR="$HOME/path/to/your/vault"
VAULT_MEETINGS_DIR="$VAULT_DIR/Meetings"

# 要約・タイトル・タグの生成に使う codex CLI。アプリ起動時は PATH が最小なので絶対パスで指定する。
CODEX_BIN="$HOME/.local/share/mise/shims/codex"

# whisper / ffmpeg のパス。省略時は common.sh の既定値（Homebrew）
# WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
# FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
# FFPROBE_BIN="/opt/homebrew/bin/ffprobe"

# 話者分離。uv sync で作った .venv があるときだけ動く。0 で止める
DIARIZE=1
# DIARIZE_PYTHON="$ROOT_DIR/.venv/bin/python"

# カレンダーの予定が始まるとき、録音を促す通知を出す。0 で止める
REMIND_MEETINGS=1

LIVE_TRANSCRIBE=1

LIVE_INTERVAL_SECS=30

# 自動停止。無音判定は 1 バッファの RMS が閾値 dBFS 以下。いずれも 0 で無効
SILENCE_STOP_MINS=10
SILENCE_THRESHOLD_DB=-50
MAX_RECORD_MINS=480

# ノートになった録音をこの日数を過ぎたら消す。0 で消さない
RECORDINGS_KEEP_DAYS=0

# スマホの録音を受け取るフォルダ。置かれた音声を取り込んでノートにする。空なら無効
INBOX_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/MeetingScribe/Inbox"
