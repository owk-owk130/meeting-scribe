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
        return {key: data[key] for key in ("title", "tags", "summary", "topics", "actions")}
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"warn: 要約が得られなかったため文字起こしのみのノートを作ります ({e})", file=sys.stderr)
        return None


def one_line(text):
    return re.sub(r"\s+", " ", text).strip()


def sections_markdown(meta):
    lines = ["## 要約", "", meta["summary"].strip()]
    for heading, items in (("主な論点", meta["topics"]), ("決定事項とアクション", meta["actions"])):
        if not items:
            continue
        lines += ["", f"## {heading}", ""]
        lines += [f"- {item.strip()}" for item in items]
    return "\n".join(lines)


parser = argparse.ArgumentParser()
parser.add_argument("--body", required=True)
parser.add_argument("--recording", required=True)
parser.add_argument("--out-dir", required=True)
parser.add_argument("--meta", required=True)
args = parser.parse_args()

now = datetime.now()
stamp = now.strftime("%Y-%m-%d-%H%M%S")
title = f"会議メモ {stamp}"
tags = ["meeting"]
sections = ""

meta = load_meta(args.meta)
if meta:
    # タイトルはファイル名に使うのでパス区切りを落とし、改行は空白にする
    meta_title = one_line(re.sub(r'[/:*?"<>|\\]', "", meta["title"]))
    if meta_title:
        title = meta_title
    # タグは frontmatter の [a, b] 形式に入れるので区切りと衝突する文字を落とす
    tags += [t for t in (one_line(re.sub(r"[,\[\]]", "", tag)) for tag in meta["tags"]) if t]
    sections = sections_markdown(meta)

body = Path(args.body).read_text(encoding="utf-8")
note = Path(args.out_dir) / f"{stamp} {title}.md"
note.write_text(
    "\n".join(
        [
            "---",
            f"date: {now.strftime('%Y-%m-%dT%H:%M:%S')}",
            f"recording: {args.recording}",
            f"title: {title}",
            f"tags: [{','.join(tags)}]",
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
