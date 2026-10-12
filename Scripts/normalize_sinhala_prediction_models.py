#!/usr/bin/env python3
"""Repair models with stripped ZWJ using the PR #7 reference's normalize().
Keeps line order unless normalization merges keys; counts are summed then.
Already-joined sources are taken as written to preserve intentional word boundaries.
"""
import argparse
import re
from pathlib import Path

JOIN = re.compile("([ක-ෆ])්(?!\u200d)(?=([යර]))")
def normalize(word):
    return JOIN.sub(lambda m: m[1] + "්" + (
        "\u200d" if m[1] != "ර" and not (m[2] == "ර" and m[1] in "මනල") else ""), word)

def repair(path, check):
    text = path.read_text(encoding="utf-8")
    if "\u200d" in text:
        return
    counts = {}
    comments = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            comments.append(line)
            continue
        fields = line.split("\t")
        if len(fields) < 2 or not fields[-1].isdigit():
            raise ValueError(f"Invalid model row: {path}")
        key = tuple(normalize(w) for w in fields[:-1])
        counts[key] = counts.get(key, 0) + int(fields[-1])
    output = "\n".join(comments + ["\t".join((*key, str(n))) for key, n in counts.items()]) + "\n"
    if output != text:
        if check:
            raise SystemExit(f"Missing orthographic joins: {path}")
        path.write_text(output, encoding="utf-8")
        print(f"Repaired {path.name}: {output.count(chr(0x200d))} ZWJ, {len(counts)} rows")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name in ["SinhalaFrequencyModel.tsv", "SinhalaNextWordModel.tsv",
                 "SinhalaTrigramModel.tsv", "SinhalaSentenceStartModel.tsv"]:
        path = args.directory / name
        if path.exists():
            repair(path, args.check)

