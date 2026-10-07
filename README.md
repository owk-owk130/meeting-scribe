# MeetingScribe

会議を録音し、文字起こしと要約を付けた Obsidian ノートを自動で作る macOS メニューバーアプリ。

自分の声はマイク、相手の声はシステム音声から別々に録るので、リモート会議では発言が「自分」「相手」に分かれる。

## 必要なもの

- macOS 14.4 以降、Apple Silicon
- Xcode Command Line Tools
- ffmpeg、whisper-cpp
- codex CLI。無くても文字起こしだけのノートは作れる
- uv と Hugging Face のアカウント。話者分離に使う。無くても話者ラベル無しで動く

## セットアップ

```sh
git clone https://github.com/owk-owk130/meeting-scribe.git
cd meeting-scribe
brew install ffmpeg whisper-cpp uv

mkdir -p models
curl -L -o models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
curl -L -o models/ggml-silero-v5.1.2.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

cp config.example.sh config.sh   # Vault の場所と codex のパスを書く
./build.sh
open MeetingScribe.app
```

話者分離を使う場合は、続けて次を行う。使わなければ飛ばしてよく、話者ラベルの無いノートになる。

1. Hugging Face のアカウントで [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) を開き、利用規約に同意する
2. `uv sync` で Python 環境を `.venv` に作る。約 1GB
3. `uv run hf auth login` でログインする。トークンは `~/.cache/huggingface` に保存される

モデルは初回の文字起こし時にダウンロードされるので、そのときはネットにつないでおく。

初回はマイク・システム音声・カレンダーの許可を求められる。カレンダーは任意で、拒否しても録音は動く。

`MeetingScribe.app` はリポジトリ内のスクリプトを参照するので、単体で別の場所へ移さない。
ログイン時に起動したい場合は「システム設定 > 一般 > ログイン項目」に追加する。

## 使い方

メニューバーの 🎙 から操作する。録音中は 🔴、一時停止中は ⏸ と経過時間が出る。

| メニュー | 動作 |
|---|---|
| 録音開始 / 録音停止 ⌘R | 停止すると文字起こしが始まり、終わるとノートができる |
| 一時停止 / 再開 ⌘P | 止めている間は録音にも経過時間にも含めない |
| ライブ文字起こしを表示 ⌘L | 録音中の発言を数十秒遅れで流すパネルを開閉する |
| 最近のノート | 直近 5 件を Obsidian で開く |
| 要約をやり直す | 文字起こしはそのままに、要約・タイトル・タグを作り直す |
| 過去の会議に質問する… | codex がノートを検索して答える。回答は Vault の `Meetings/質問/` に保存され Obsidian で開く |
| 未完了の文字起こし | 失敗・中断した録音を選んで文字起こしし直す |

自動で行うこと:

- 無音が続くか最大録音時間に達すると録音を止める
- 発話が無かった録音はノートを作らず音源を消す
- 録音開始時にカレンダーの予定を拾い、ノートのタイトルを「予定名 - 内容の要約」にする
- カレンダーの予定が始まる 2 分前から 5 分後の間に、録音していなければ通知で知らせる
- `INBOX_DIR` に置かれた音声を取り込み、文字起こししてノートにする

ライブパネルはフォーカスを奪わず、遡って読んでいる間は自動スクロールしない。
自分で閉じると次の録音でも開かない。ライブで欠けた発言も、最終ノートでは録音全体から起こし直す。

## スマホの録音

iPhone のボイスメモなどで録った音声を iCloud Drive の `INBOX_DIR` に置くと、アプリが取り込んでノートにする。
録音中・文字起こし中は待ち、1 件ずつ処理する。取り込んだ元ファイルは消える。

- ノートの日時はファイルの作成日時。ボイスメモは共有した時刻になるので、録音後すぐ送る
- ステレオでもモノラルに変換し、左右ではなく声で話者を分ける
- 取り込みに失敗したファイルは受け取りフォルダに残り、アプリを再起動するまで再試行しない

共有シートから送るショートカットを作っておくと手早い。

1. ショートカットを新規作成し、詳細で「共有シートに表示」をオンにする
2. 先頭の「共有シートから受け取る」の入力をファイルとメディアに絞る
3. 「ファイルを保存」を追加し、保存先を尋ねずに `MeetingScribe/Inbox` へ保存する

## ノート

`YYYY-MM-DD-HHMMSS <タイトル>.md` の名前で Vault に保存する。日時は録音開始時刻。

```markdown
---
date / recording / title / tags / event / attendees
---
## 要約
## 主な論点
## 決定事項とアクション
## 前回からの持ち越し     同じ案件の過去ノートのアクションが今どうなったか
## 関連ノート             過去ノートへの [[リンク]]
## 話者の推定             話者ラベルと、文脈から推定した名前
## 文字起こし             折りたたみで既定は閉じている
```

- 中身の無い節は省く。event と attendees はカレンダーの予定があるときだけ付く
- 誤認識された固有名詞は codex が文脈から推測し、文字起こしでも直す
- 対面会議やスマホの録音は声で話者を分け、話者A・話者B… のラベルを付ける。リモート会議の相手が複数いれば相手A・相手B… になる
- 文字起こしの発言には話者ごとに 🔵🟠🟢 のような色の丸が付く
- 話者の分け方は完璧ではなく、同じ人が別ラベルになることもある。人数はカレンダーの参加者数を上限にして推定する
- 話者分離を使うと、ノートができるまでが 30 分の録音あたり 2〜3 分延びる
- codex が使えないときは `会議メモ <日時>` という名前の、文字起こしだけのノートになる
- 「過去の会議に質問する」の回答は `質問/` サブフォルダに入り、会議ノートの一覧や過去ノートの候補には混ざらない

## 設定

`config.sh` で変える。反映にはアプリの再起動だけでよく、再ビルドは要らない。

| 変数 | 意味 | 例 |
|---|---|---|
| `RECORDINGS_DIR` | 録音ファイルの保存先 | `~/MeetingRecordings` |
| `VAULT_MEETINGS_DIR` | ノートの保存先 | Vault 内の `Meetings` |
| `CODEX_BIN` | codex の絶対パス | |
| `DIARIZE` | 0 で話者分離を止める | `1` |
| `REMIND_MEETINGS` | 0 で予定開始の通知を止める | `1` |
| `LIVE_TRANSCRIBE` | 0 でライブ文字起こしを止める。バッテリー節約に | `1` |
| `LIVE_INTERVAL_SECS` | ライブの更新間隔の秒数 | `30` |
| `SILENCE_STOP_MINS` | この分数だけ無音が続いたら止める。0 で無効 | `10` |
| `SILENCE_THRESHOLD_DB` | 無音とみなす音量の dBFS | `-50` |
| `MAX_RECORD_MINS` | この分数で止める。0 で無効 | `480` |
| `RECORDINGS_KEEP_DAYS` | ノート化済みの録音をこの日数で消す。0 で消さない | `0` |
| `INBOX_DIR` | スマホの録音を受け取るフォルダ。空なら無効 | iCloud Drive の `MeetingScribe/Inbox` |

ログは `state/record.log` に出る。無音停止を使うと 1 分ごとの最大音量が `level:` 行に出るので、閾値の目安にできる。

## アイコンがメニューバーに出ないとき

項目が多いとノッチの裏に隠れる。見えていれば ⌘ を押しながらドラッグして並べ替えられる。
見えない場合は、画面右端からの距離を指定して置き直す。

```sh
pkill -x MeetingScribe
defaults write local.meetingscribe "NSStatusItem Preferred Position MeetingScribe" -float 400
killall cfprefsd
open MeetingScribe.app
```

## 構成

```
app/MeetingScribe/          メニューバーアプリの Swift ソース
app/MeetingScribeRecorder/  録音 CLI の Swift ソース
app/Shared/                 アプリと録音 CLI で共有する定義
scripts/                    録音ファイルからノートを作るスクリプト、質問に答えるスクリプト、codex のプロンプトとスキーマ
models/                     whisper と VAD のモデル
state/                      ログと実行中の状態ファイル
build.sh                    .app バンドルを作る
config.sh                   個人設定。config.example.sh から作る
pyproject.toml              話者分離の Python 依存。uv sync で .venv を作る
```

## ライセンス

MIT License。外部ツールは別プロセスとして呼び出している。
whisper.cpp、whisper モデル、Silero VAD、pyannote.audio は MIT、ffmpeg は GPL-3.0。
話者分離のモデル pyannote/speaker-diarization-community-1 は CC-BY-4.0。
