#!/usr/bin/env python3
import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path


def load_meta(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        meta = {key: data[key] for key in ("title", "tags", "summary", "topics", "actions")}
        for key in ("corrections", "carried_over", "related_notes"):
            meta[key] = data.get(key, [])
        return meta
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"warn: 要約が得られなかったため文字起こしのみのノートを作ります ({e})", file=sys.stderr)
        return None


def one_line(text):
    return re.sub(r"\s+", " ", text).strip()


def filename_safe(title):
    return one_line(re.sub(r'[/:*?"<>|\\]', "", title))


def sections_markdown(meta, notes_dir):
    related = [f"[[{name}]]" for name in meta["related_notes"] if (notes_dir / f"{name}.md").exists()]
    lines = ["## 要約", "", meta["summary"].strip()]
    for heading, items in (
        ("主な論点", meta["topics"]),
        ("決定事項とアクション", meta["actions"]),
        ("前回からの持ち越し", meta["carried_over"]),
        ("関連ノート", related),
    ):
        if not items:
            continue
        lines += ["", f"## {heading}", ""]
        lines += [f"- {item.strip()}" for item in items]
    return "\n".join(lines)


def apply_corrections(body, corrections):
    pairs = [(c["from"], c["to"]) for c in corrections if len(c["from"]) >= 2 and c["from"] != c["to"]]
    for src, dst in sorted(pairs, key=lambda p: -len(p[0])):
        body = body.replace(src, dst)
    return body


def load_event(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)[0]
    except (OSError, ValueError, IndexError, TypeError):
        return None


def recorded_at(recording):
    m = re.search(r"(\d{8})-(\d{6})", recording)
    if not m:
        return datetime.now()
    return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")


def unused_path(directory, stamp, title):
    note = directory / f"{stamp} {title}.md"
    n = 2
    while note.exists():
        note = directory / f"{stamp} {title} ({n}).md"
        n += 1
    return note


parser = argparse.ArgumentParser()
parser.add_argument("--body", required=True)
parser.add_argument("--recording", required=True)
parser.add_argument("--out-dir", required=True)
parser.add_argument("--event")
parser.add_argument("--meta", required=True)
args = parser.parse_args()

recorded = recorded_at(args.recording)
stamp = recorded.strftime("%Y-%m-%d-%H%M%S")
title = f"会議メモ {stamp}"
tags = ["meeting"]
sections = ""
body = Path(args.body).read_text(encoding="utf-8")

meta = load_meta(args.meta)
if meta:
    meta_title = filename_safe(meta["title"])
    if meta_title:
        title = meta_title
    # タグは frontmatter の [a, b] 形式に入れるので区切りと衝突する文字を落とす
    tags += [t for t in (one_line(re.sub(r"[,\[\]]", "", tag)) for tag in meta["tags"]) if t]
    sections = sections_markdown(meta, Path(args.out_dir))
    body = apply_corrections(body, meta["corrections"])

event = load_event(args.event) if args.event else None
event_lines = []
if event:
    event_title = filename_safe(event["title"])
    if event_title:
        title = event_title
    event_lines.append(f"event: {one_line(event['title'])}")
    attendees = [one_line(re.sub(r"[,\[\]]", "", a)) for a in event["attendees"]]
    event_lines.append(f"attendees: [{','.join(a for a in attendees if a)}]")

note = unused_path(Path(args.out_dir), stamp, title)
note.write_text(
    "\n".join(
        [
            "---",
            f"date: {recorded.strftime('%Y-%m-%dT%H:%M:%S')}",
            f"recording: {args.recording}",
            f"title: {title}",
            f"tags: [{','.join(tags)}]",
        ]
        + event_lines
        + [
            "---",
            "",
            f"# {title}",
            "",
        ]
        + ([sections, ""] if sections else [])
        + ["## 文字起こし", "", body]
    ),
    encoding="utf-8",
)
print(note)
