#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

CARRY_SECTIONS = ("決定事項とアクション", "前回からの持ち越し")


def frontmatter(text):
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    fields = {}
    for line in (m.group(1).splitlines() if m else []):
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def section_items(text, heading):
    m = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not m:
        return []
    return [line[2:].strip() for line in m.group(1).splitlines() if line.startswith("- ")]


parser = argparse.ArgumentParser()
parser.add_argument("--dir", required=True)
parser.add_argument("--exclude-recording", default="")
parser.add_argument("--limit", type=int, default=15)
args = parser.parse_args()

notes = sorted((p for p in Path(args.dir).glob("*.md") if not p.name.startswith(".")), reverse=True)
shown = 0
for note in notes:
    if shown >= args.limit:
        break
    text = note.read_text(encoding="utf-8")
    fields = frontmatter(text)
    if args.exclude_recording and args.exclude_recording in fields.get("recording", ""):
        continue
    items = [item for heading in CARRY_SECTIONS for item in section_items(text, heading)]
    print(f"### {note.stem}")
    print(f"tags: {fields.get('tags', '')}")
    for item in items:
        print(f"- {item}")
    print()
    shown += 1
