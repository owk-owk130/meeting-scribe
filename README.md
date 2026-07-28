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
- 「録音停止」で文字起こしが走り、完了すると `Meetings/` にノートができる
- 「最近のノート」から直近 5 件を Obsidian で開ける
- 進行状況は通知で知らせる

### ノートの形式

ファイル名は `YYYY-MM-DD-HHMMSS <タイトル>.md`。frontmatter に date / recording / title / tags、
本文に要約と文字起こしが入る。

- **リモート会議**（システム音声に相手の声がある場合）: タイムスタンプ + 話者ラベル（自分/相手）付き
- **対面会議など**（システム音声が無音の場合）: プレーンな文字起こし。
  マイクが部屋全体を拾うため全員の発言が入るが、話者の区別はされない

codex が使えないときは `会議メモ <日時>` と `tags: [meeting]` だけのノートになる。

## 設定の変更

保存先パスと `CODEX_BIN` は `config.sh` にある。変更後は再ビルド不要、アプリの再起動だけでよい。

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
| `MeetingScribe.swift` | メニューバーアプリ本体（AppKit、1ファイル） |
| `AudioTapRecorder.swift` | 録音 CLI。L=デフォルト入力（自分）/ R=システム音声タップ（相手）のステレオ m4a を書く |
| `build.sh` | ビルド + `.app` バンドル生成 |
| `config.sh` | 共有設定（保存先パス、codex のパス） |
| `record.sh` | 録音の開始/停止/状態確認 |
| `transcribe.sh` | 文字起こし、要約・タイトル・タグ生成、ノート生成 |
| `models/` | whisper モデル |

## ライセンス

MIT License（[LICENSE](LICENSE)）

外部依存は別プロセスとして呼び出している:
whisper.cpp（MIT）/ whisper モデル（MIT）/ Silero VAD（MIT）/ ffmpeg（GPL-3.0）
