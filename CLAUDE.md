# CLAUDE.md

## 検証

テスト基盤はない。変更したら以下を通す。

```sh
bash -n record.sh transcribe.sh transcribe-live.sh common.sh build.sh config.sh config.example.sh
swiftc -O MeetingScribe.swift -o /tmp/check        # 稼働中の .app を壊さないよう出力先を分ける
swiftc -O AudioTapRecorder.swift -o /tmp/check-recorder
./transcribe.sh ~/MeetingRecordings/<file>.m4a     # パイプライン全体（whisper + codex で数分）
```

## 実行環境

`record.sh` / `transcribe.sh` はアプリから `nohup` で起動されるため **PATH が最小**になる。
外部コマンドは絶対パスで呼ぶ。既定パスは `common.sh` に置いて `config.sh` で上書きできるようにする（`WHISPER_BIN`）か、`config.sh` だけに持たせる（`CODEX_BIN`）。

## 設定

パス設定は `config.sh` が単一の真実源で、shell スクリプトとアプリの両方が読む。
`config.sh` は git 管理外なので、項目を追加したら `config.example.sh` も更新する。

## Git

main に直接コミットする。
