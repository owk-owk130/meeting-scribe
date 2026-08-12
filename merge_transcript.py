#!/usr/bin/env python3
import argparse
import json


def load(path, label):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError:
        return []
    segments = []
    for seg in data.get("transcription", []):
        text = seg["text"].strip()
        if text:
            segments.append((seg["offsets"]["from"], label, text))
    return segments


parser = argparse.ArgumentParser()
parser.add_argument("self_json")
parser.add_argument("others_json")
parser.add_argument("--offset-ms", type=int, default=0)
parser.add_argument("--labels", choices=["auto", "always"], default="auto")
args = parser.parse_args()

mine = load(args.self_json, "自分")
others = load(args.others_json, "相手")
if args.labels == "always":
    for offset_ms, label, text in sorted(mine + others):
        minutes, seconds = divmod((offset_ms + args.offset_ms) // 1000, 60)
        print(f"[{minutes:02d}:{seconds:02d}] {label}: {text}")
elif others:
    for offset_ms, label, text in sorted(mine + others):
        minutes, seconds = divmod((offset_ms + args.offset_ms) // 1000, 60)
        print(f"- [{minutes:02d}:{seconds:02d}] **{label}**: {text}")
else:
    for _, _, text in sorted(mine):
        print(text)
