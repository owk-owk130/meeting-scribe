# CLAUDE.md

## 検証

テスト基盤はない。変更したら以下を通す。

```sh
bash -n record.sh transcribe.sh build.sh config.sh config.example.sh
swiftc -O MeetingScribe.swift -o /tmp/check        # 稼働中の .app を壊さないよう出力先を分ける
./transcribe.sh ~/MeetingRecordings/<file>.m4a     # パイプライン全体（whisper + codex で数分）
```

## 実行環境

`record.sh` / `transcribe.sh` はアプリから `nohup` で起動されるため **PATH が最小**になる。
外部コマンドは絶対パスで呼ぶか、`config.sh` にパスを持たせる（`WHISPER_BIN` / `CODEX_BIN` がその例）。

## 設定

パス設定は `config.sh` が単一の真実源で、shell スクリプトとアプリの両方が読む。
`config.sh` は git 管理外なので、項目を追加したら `config.example.sh` も更新する。

## Git

main に直接コミットする。
