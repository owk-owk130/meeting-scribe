# CLAUDE.md

## 検証

テストは merge_transcript の単体テストだけ。変更したら以下を通す。

```sh
bash -n scripts/*.sh build.sh config.sh config.example.sh
swiftc -O app/MeetingScribe/*.swift app/Shared/*.swift -o /tmp/check     # 稼働中の .app を壊さないよう出力先を分ける
swiftc -O app/MeetingScribeRecorder/*.swift app/Shared/*.swift -o /tmp/check-recorder
(cd scripts && /usr/bin/python3 -m unittest test_merge_transcript)
scripts/transcribe.sh ~/MeetingRecordings/<file>.m4a    # パイプライン全体（whisper + codex で数分）
```

## 実行環境

recorder・whisper・ffmpeg と `scripts/transcribe.sh` はアプリが `Process` で起動するため **PATH が最小**になる。
外部コマンドは絶対パスで呼ぶ。既定パスは `scripts/common.sh` に置いて `config.sh` で上書きできるようにする（`WHISPER_BIN`）か、`config.sh` だけに持たせる（`CODEX_BIN`）。

## 設定

パス設定は `config.sh` が単一の真実源で、shell スクリプトとアプリの両方が読む。
`config.sh` は git 管理外なので、項目を追加したら `config.example.sh` も更新する。

## Git

main に直接コミットする。
