#!/usr/bin/env python3
import argparse
import json

MERGE_GAP_MS = 2000
MERGE_SPAN_MS = 60000


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
            segments.append([seg["offsets"]["from"], seg["offsets"]["to"], label, text])
    return segments


def join_texts(left, right):
    if left[-1].isascii() and left[-1].isalnum() and right[0].isascii() and right[0].isalnum():
        return f"{left} {right}"
    return left + right


def merge_adjacent(segments):
    merged = []
    for start, end, label, text in sorted(segments):
        if merged:
            prev = merged[-1]
            if prev[2] == label and start - prev[1] <= MERGE_GAP_MS and end - prev[0] <= MERGE_SPAN_MS:
                prev[1] = end
                prev[3] = join_texts(prev[3], text)
                continue
        merged.append([start, end, label, text])
    return merged


def timestamp(offset_ms):
    minutes, seconds = divmod(offset_ms // 1000, 60)
    return f"{minutes:02d}:{seconds:02d}"


parser = argparse.ArgumentParser()
parser.add_argument("self_json")
parser.add_argument("others_json")
parser.add_argument("--offset-ms", type=int, default=0)
parser.add_argument("--labels", choices=["auto", "always"], default="auto")
args = parser.parse_args()

mine = load(args.self_json, "自分")
others = load(args.others_json, "相手")
segments = merge_adjacent(mine + others)
if args.labels == "always":
    for start, _, label, text in segments:
        print(f"[{timestamp(start + args.offset_ms)}] {label}: {text}")
elif others:
    for start, _, label, text in segments:
        print(f"- [{timestamp(start + args.offset_ms)}] **{label}**: {text}")
else:
    for _, _, _, text in segments:
        print(text)
