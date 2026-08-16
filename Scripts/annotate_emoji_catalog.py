#!/usr/bin/env python3
"""Annotate the bundled emoji search index with Unicode Emoji group/order data.

Usage:
  python3 Scripts/annotate_emoji_catalog.py \
    /path/to/emoji-test.txt AksharaKeyboard/EmojiSearchIndex.json

The input is Unicode's released emoji-test.txt file. The app remains fully
offline at runtime; this only refreshes the bundled catalog metadata.
"""

import json
import sys


GROUPS = {
    "Smileys & Emotion": "smileys",
    "People & Body": "smileys",
    "Animals & Nature": "animals",
    "Food & Drink": "food",
    "Travel & Places": "travel",
    "Activities": "activity",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "flags",
}
GROUP_PREFIX = "akshara-emoji-group:"
ORDER_PREFIX = "akshara-emoji-order:"


def parse_emoji_test(path):
    current_group = None
    records = {}
    order = 0
    with open(path, encoding="utf-8") as source:
        for line in source:
            if line.startswith("# group: "):
                current_group = GROUPS.get(line.removeprefix("# group: ").strip())
                continue
            if not current_group or "; fully-qualified" not in line:
                continue
            code_points = line.split(";", 1)[0].strip().split()
            if not code_points:
                continue
            emoji = "".join(chr(int(value, 16)) for value in code_points)
            records[emoji] = (current_group, order)
            order += 1
    return records


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: annotate_emoji_catalog.py emoji-test.txt EmojiSearchIndex.json")
    records = parse_emoji_test(sys.argv[1])
    destination = sys.argv[2]
    with open(destination, encoding="utf-8") as source:
        index = json.load(source)

    for emoji, terms in index.items():
        terms[:] = [term for term in terms if not term.startswith((GROUP_PREFIX, ORDER_PREFIX))]
        if record := records.get(emoji):
            group, order = record
            terms.extend((f"{GROUP_PREFIX}{group}", f"{ORDER_PREFIX}{order:05d}"))

    with open(destination, "w", encoding="utf-8") as output:
        json.dump(index, output, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()
