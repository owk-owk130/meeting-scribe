# MeetingScribe

会議の録音 → whisper-cpp での文字起こし → Obsidian ノート作成までを行う macOS メニューバーアプリ。

自分の声（マイク）と相手の声（システム音声）を別チャンネルで録音するので、
リモート会議では **話者ラベル付き**（自分/相手）の文字起こしノートができる。
AirPods などの出力デバイス設定はそのままでよい（BlackHole や複数出力装置は不要）。

## 構成

| ファイル | 役割 |
|---|---|
| `MeetingScribe.swift` | メニューバーアプリ本体（AppKit、1ファイル） |
| `AudioTapRecorder.swift` | 録音 CLI。L=デフォルト入力（自分）/ R=システム音声タップ（相手）のステレオ m4a を書く |
| `build.sh` | ビルド + `.app` バンドル生成 |
| `config.sh` | 共有設定（保存先パス） |
| `record.sh` | 録音の開始/停止/状態確認（録音 CLI の起動・停止を管理） |
| `transcribe.sh` | 文字起こし（whisper-cpp）と Obsidian ノート生成 |
| `models/` | whisper モデル（ggml-large-v3-turbo.bin） |

## 必要なもの

- macOS 14.4+ / Apple Silicon（システム音声の取得に Core Audio process tap API を使用）
- Xcode Command Line Tools（swiftc）

## セットアップ

```sh
git clone https://github.com/owk-owk130/meeting-scribe.git
cd meeting-scribe

# 依存ツール
brew install ffmpeg whisper-cpp

# whisper モデル（約1.5GB）
curl -L -o models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# VAD モデル（約900KB）。無音区間での幻聴を防ぐために必須
curl -L -o models/ggml-silero-v5.1.2.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

# 設定（ノートの出力先などを編集する）
cp config.example.sh config.sh
$EDITOR config.sh

# ビルドと起動
./build.sh
open MeetingScribe.app
```

初回録音時に「マイク」と「システム音声の録音」の許可ダイアログが出るので、どちらも許可する。

アプリはバンドルの隣にあるスクリプト群（record.sh 等）を参照するため、
**MeetingScribe.app を単体で別の場所へ移動しない**こと（起動時にアラートが出る）。
プロジェクトディレクトリごとの移動は再ビルドすれば追従する。

## 使い方

- メニューバーの 🎙 をクリック → 「録音開始」（⌘R）
- 録音中は 🔴 と経過時間が表示される
- 「録音停止」で録音を終了すると、バックグラウンドで文字起こしが走り、完了すると通知が出て Vault の `Meetings/` にノートが作られる
- 「最近のノート」から直近 5 件のノートを開ける

### ノートの形式

- **リモート会議**（システム音声に相手の声がある場合）: タイムスタンプ + 話者ラベル付き

  ```
  - [00:12] **自分**: では始めましょうか
  - [00:15] **相手**: お願いします
  ```

- **対面会議など**（システム音声が無音の場合）: プレーンな文字起こし。
  マイクが部屋全体を拾うため全員の発言が入るが、話者の区別はされない

### マイクについて

録音にはシステムの**デフォルト入力デバイス**を使う（AirPods 接続中は AirPods のマイク）。
会議アプリと同じマイクが自動的に使われるので設定は不要。

## 設定の変更

保存先パスは `config.sh` に集約されている。シェルスクリプトとアプリの両方がここを読むため、
編集は 1 箇所で済む。変更後は再ビルド不要で、アプリの再起動だけでよい。

## アイコンがメニューバーに出ないとき

メニューバーの項目が多い（特にノッチ付きの MacBook）と、位置を持たない項目は
最左＝ノッチの裏に追いやられて見えなくなる。表示されている状態なら **⌘ を押しながらドラッグ**
すれば並べ替えでき、その位置は保存される。

隠れていてドラッグできない場合は、位置を直接指定してから起動する。
値は**画面右端からの距離**で、小さいほど右（＝優先度が高い）:

```sh
pkill -x MeetingScribe
defaults write local.meetingscribe "NSStatusItem Preferred Position MeetingScribe" -float 400
killall cfprefsd
open MeetingScribe.app
```

他の項目の値は `defaults read <ドメイン> | grep 'Preferred Position'` で確認できる
（参考: コントロールセンター 143 / Wi-Fi 177 / バッテリー 215）。

## ログイン時に自動起動したい場合

「システム設定 > 一般 > ログイン項目」に `MeetingScribe.app` を手動で追加する。
