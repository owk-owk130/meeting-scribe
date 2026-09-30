# MeetingScribe

会議の録音 → 文字起こし → 要約・タイトル・タグ付け → Obsidian ノート作成までを行う macOS メニューバーアプリ。

## 必要なもの

- macOS 14.4+ / Apple Silicon（システム音声の取得に Core Audio process tap API を使用）
- Xcode Command Line Tools（swiftc）
- ffmpeg / whisper-cpp（文字起こし）
- codex CLI（要約・タイトル・タグの生成。無ければ文字起こしのみ）

## セットアップ

```sh
git clone https://github.com/owk-owk130/meeting-scribe.git
cd meeting-scribe

# 依存ツール
brew install ffmpeg whisper-cpp

# whisper モデル（約1.5GB）
mkdir -p models
curl -L -o models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# VAD モデル（約900KB）。必須
curl -L -o models/ggml-silero-v5.1.2.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

# 設定（ノートの出力先と codex のパス）
cp config.example.sh config.sh
$EDITOR config.sh

# ビルドと起動
./build.sh
open MeetingScribe.app
```

初回録音時に「マイク」と「システム音声の録音」の許可ダイアログが出る。

**MeetingScribe.app を単体で別の場所へ移動しない**こと（隣のスクリプト群を参照している）。

## 使い方

- メニューバーの 🎙 をクリック → 「録音開始」（⌘R）
- 録音中は 🔴 と経過時間が出る
- 録音中はフローティングウィンドウに数十秒遅れで文字起こしが流れる（下記「ライブ文字起こし」）
- 「録音停止」で文字起こしが走り、完了すると `Meetings/` にノートができる
- 無音が一定時間続くか最大録音時間に達すると自動停止し、同じく文字起こしが走る（停止し忘れ対策）
- 発話が検出されなかった録音はノートを作らず音源を削除する
- 「最近のノート」から直近 5 件を Obsidian で開ける
- 進行状況は通知で知らせる
- 文字起こしが失敗・中断した録音は「未完了の文字起こし」に出る。選ぶと文字起こしをやり直す
  （ノートの frontmatter `recording:` に現れない録音を未完了とみなす。要らない録音は録音フォルダから消す）

### ライブ文字起こし

録音を開始すると常に手前に浮くパネルが開き、`LIVE_INTERVAL_SECS`（既定 30 秒）間隔で
発言が追記されていく。面接や会議の最中に相手の発言を遡って確認する用途を想定している。
クリックしてもフォーカスを奪わず、上へスクロール中は自動追従しない。

パネルはメニューの「ライブ文字起こしを表示」（⌘L）か ✕ ボタンでいつでも開閉できる。
自分で閉じた場合は次の録音開始でも自動表示せず、開き直すと自動表示に戻る。

チャンク境界で切れた発話はライブでは欠けることがあるが、停止後の最終ノートは
全体を文字起こしし直すため影響しない。`LIVE_TRANSCRIBE=0` で無効化できる
（whisper が録音中も定期的に走るため、バッテリー駆動時など）。

### ノートの形式

ファイル名は `YYYY-MM-DD-HHMMSS <タイトル>.md` で、日時は録音開始時刻。frontmatter に date / recording / title / tags、
本文に「要約」（議論の概要）「主な論点」「決定事項とアクション」「文字起こし」が入る。
論点・決定事項が無い会議では該当セクションを省く。
codex が文脈から誤認識と判断した固有名詞・専門用語は文字起こし本文でも訂正する。

- **リモート会議**（システム音声に相手の声がある場合）: タイムスタンプ + 話者ラベル（自分/相手）付き
- **対面会議など**（システム音声が無音の場合）: プレーンな文字起こし。
  マイクが部屋全体を拾うため全員の発言が入るが、話者の区別はされない

codex が使えないときは `会議メモ <日時>` と `tags: [meeting]` だけのノートになる。

## 設定の変更

保存先パスと `CODEX_BIN` は `config.sh` にある。変更後は再ビルド不要、アプリの再起動だけでよい。

自動停止も `config.sh` で調整する。いずれも 0 で無効。

| 変数 | 意味 |
|---|---|
| `SILENCE_STOP_MINS` | 無音がこの分数続いたら停止 |
| `SILENCE_THRESHOLD_DB` | 無音とみなす音量（dBFS、RMS）。自分・相手の両チャンネルがこれ以下なら無音 |
| `MAX_RECORD_MINS` | 録音開始からこの分数で停止 |

ノートになった録音は `RECORDINGS_KEEP_DAYS` 日を過ぎると次の録音開始時に削除する。0 で削除しない。
ノートが無い録音は「未完了の文字起こし」に残すため消さない。

閾値の当たりをつけるには `state/record.log` を見る。10MB を超えると録音開始時に `record.log.1` へ退避する。無音停止が有効なとき、1 分ごとの最大音量が `level:` 行に出る。

## アイコンがメニューバーに出ないとき

項目が多いとノッチの裏に隠れる。表示されていれば **⌘ + ドラッグ**で並べ替えでき、位置は保存される。

隠れている場合は位置を直接指定する。値は**画面右端からの距離**:

```sh
pkill -x MeetingScribe
defaults write local.meetingscribe "NSStatusItem Preferred Position MeetingScribe" -float 400
killall cfprefsd
open MeetingScribe.app
```

他の項目の値は `defaults read <ドメイン> | grep 'Preferred Position'` で確認できる。

## ログイン時に自動起動したい場合

「システム設定 > 一般 > ログイン項目」に `MeetingScribe.app` を追加する。

## 構成

| ファイル | 役割 |
|---|---|
| `app/MeetingScribe.swift` | メニューバーアプリ本体（AppKit、1ファイル）。録音の開始/停止、未完了録音の列挙、文字起こしの起動もここが行う |
| `app/AudioTapRecorder.swift` | 録音 CLI。L=デフォルト入力（自分）/ R=システム音声タップ（相手）のステレオ m4a を書く |
| `build.sh` | ビルド + `.app` バンドル生成。recorder もバンドル内に置く |
| `config.sh` | 共有設定（保存先パス、codex のパス、自動停止） |
| `scripts/transcribe.sh` | 文字起こし、要約・タイトル・タグ生成、ノート生成 |
| `scripts/transcribe-live.sh` | 録音中の raw PCM を定期的に文字起こしするウォッチャー |
| `scripts/common.sh` | shell スクリプト共通の定義（ツールのパス、状態ファイル、通知、whisper / ffmpeg 呼び出し） |
| `scripts/merge_transcript.py` | whisper の JSON 出力（自分/相手）を時刻順にマージ |
| `scripts/build_note.py` | 文字起こし本文と codex の要約 JSON から Obsidian ノートを書く |
| `scripts/note-schema.json` / `scripts/note-prompt.md` | codex に渡す要約の出力スキーマとプロンプト |
| `models/` | whisper モデル |
| `state/` | 実行時のログと状態ファイル。git 管理外 |

## ライセンス

MIT License（[LICENSE](LICENSE)）

外部依存は別プロセスとして呼び出している:
whisper.cpp（MIT）/ whisper モデル（MIT）/ Silero VAD（MIT）/ ffmpeg（GPL-3.0）
