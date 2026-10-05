#!/usr/bin/env python3
import argparse
import json

MERGE_GAP_MS = 2000
MERGE_SPAN_MS = 60000
SPEAKER_COLORS = "🔵🟠🟢🟣🔴🟡🟤⚫⚪"


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


def load_turns(path):
    if not path:
        return []
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def closest_speaker(start, end, turns):
    def score(turn):
        overlap = min(end, turn[1]) - max(start, turn[0])
        return (max(overlap, 0), -max(-overlap, 0))

    return max(turns, key=score)[2]


def label_speakers(segments, turns, prefix):
    if not turns:
        return segments
    speakers = [closest_speaker(start, end, turns) for start, end, _, _ in segments]
    order = list(dict.fromkeys(speakers))
    if len(order) < 2:
        return segments
    return [
        [start, end, prefix + chr(ord("A") + order.index(speaker)), text]
        for (start, end, _, text), speaker in zip(segments, speakers)
    ]


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


def render(mine, others, offset_ms, labels):
    segments = merge_adjacent(mine + others)
    if labels == "always":
        return [f"[{timestamp(start + offset_ms)}] {label}: {text}" for start, _, label, text in segments]
    if others or len({label for _, _, label, _ in mine}) > 1:
        order = list(dict.fromkeys(label for _, _, label, _ in segments))
        return [
            f"- [{timestamp(start + offset_ms)}] {SPEAKER_COLORS[order.index(label) % len(SPEAKER_COLORS)]} **{label}**: {text}"
            for start, _, label, text in segments
        ]
    return [text for _, _, _, text in segments]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("self_json")
    parser.add_argument("others_json", nargs="?")
    parser.add_argument("--self-speakers", help="モノラル録音の話者分離結果。話者A・B… に分ける")
    parser.add_argument("--others-speakers", help="相手側の話者分離結果。相手A・B… に分ける")
    parser.add_argument("--offset-ms", type=int, default=0)
    parser.add_argument("--labels", choices=["auto", "always"], default="auto")
    args = parser.parse_args()

    mine = label_speakers(load(args.self_json, "自分"), load_turns(args.self_speakers), "話者")
    others = load(args.others_json, "相手") if args.others_json else []
    others = label_speakers(others, load_turns(args.others_speakers), "相手")
    for line in render(mine, others, args.offset_ms, args.labels):
        print(line)
