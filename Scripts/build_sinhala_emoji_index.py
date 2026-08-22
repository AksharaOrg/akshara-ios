#!/usr/bin/env python3
"""Compile Unicode CLDR Sinhala emoji annotations into an inverted token index.

Usage:
  python3 Scripts/build_sinhala_emoji_index.py \\
    .corpus-cache/cldr/si.xml \\
    .corpus-cache/cldr/si-derived.xml \\
    Scripts/SinhalaEmojiOverlay.tsv \\
    AksharaKeyboard/Resources/SinhalaEmojiIndex.json

The keyboard stays offline at runtime; this only regenerates the bundled index.
"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

# Generic words that appear on almost every annotation and would light up the
# suggestion rail for ordinary typing. Keep this list tight.
STOP_TOKENS = {
    "අත",
    "ඇස",
    "ඇස්",
    "ඉමෝජි",
    "උපකරණය",
    "කට",
    "කාන්තාව",
    "ගස",
    "තිත්",
    "නිල්",
    "පිරිමියා",
    "මිනිහා",
    "මුහුණ",
    "ලකුණ",
    "වර්ණය",
    "සම",
    "ස්ත්‍රිය",
    "ෆ්ට්ස්පැට්‍රික්",
}

# Prefer chat-friendly emoji when a token maps to many candidates.
CATEGORY_RANK = {
    "smileys": 0,
    "people": 1,
    "hearts": 2,
    "animals": 3,
    "food": 4,
    "activity": 5,
    "travel": 6,
    "objects": 7,
    "symbols": 8,
    "flags": 9,
    "other": 10,
}

ANNOTATION_RE = re.compile(
    r'<annotation\s+cp="([^"]+)"(?:\s+type="([^"]+)")?\s*>([^<]*)</annotation>'
)
MAX_PER_TOKEN = 8


def codepoint_key(emoji: str) -> tuple[int, ...]:
    return tuple(ord(ch) for ch in emoji)


def emoji_category(emoji: str) -> str:
    """Coarse Unicode-range ranking so 👍 beats ✅ for tokens like හරි."""
    if not emoji:
        return "other"
    first = ord(emoji[0])
    # Variation selectors / ZWJ sequences: look at the first emoji scalar.
    for ch in emoji:
        value = ord(ch)
        if value in (0x200D, 0xFE0F) or 0x1F3FB <= value <= 0x1F3FF:
            continue
        first = value
        break

    if first in (0x2764, 0x2665) or 0x1F49C <= first <= 0x1F5A4 or first in (
        0x1F90D,
        0x1F90E,
        0x1F9E1,
        0x1FA75,
        0x1FA76,
        0x1FA77,
    ):
        return "hearts"
    if 0x1F600 <= first <= 0x1F64F or 0x1F910 <= first <= 0x1F92F or 0x1F970 <= first <= 0x1F97F:
        return "smileys"
    if 0x1F44C <= first <= 0x1F44F or 0x1F64C <= first <= 0x1F64F or 0x1F90C <= first <= 0x1F91F:
        return "people"
    if 0x1F400 <= first <= 0x1F4D3 or 0x1F980 <= first <= 0x1F9AE:
        return "animals"
    if 0x1F32D <= first <= 0x1F37F or 0x1F950 <= first <= 0x1F96F or 0x1F9C0 <= first <= 0x1F9CB:
        return "food"
    if 0x1F3A0 <= first <= 0x1F3FF or 0x26BD <= first <= 0x26BE:
        return "activity"
    if 0x1F680 <= first <= 0x1F6FF or 0x1F3E0 <= first <= 0x1F3F0:
        return "travel"
    if 0x1F1E6 <= first <= 0x1F1FF:
        return "flags"
    if 0x1F300 <= first <= 0x1F5FF or 0x1F900 <= first <= 0x1F9FF:
        return "objects"
    if first < 0x1F000:
        return "symbols"
    return "other"


def is_skin_tone_only(emoji: str) -> bool:
    return all(
        0x1F3FB <= ord(ch) <= 0x1F3FF or ord(ch) == 0xFE0F
        for ch in emoji
    )


def contains_skin_tone(emoji: str) -> bool:
    return any(0x1F3FB <= ord(ch) <= 0x1F3FF for ch in emoji)


def tokenize(text: str) -> list[str]:
    """Index whole | -separated keywords. Do not split multi-word phrases so
    compounds like 'හරි නැහැ' never pollute the standalone token 'හරි'."""
    tokens = []
    for part in text.split("|"):
        keyword = part.strip().strip(".")
        if not keyword:
            continue
        # Multi-word descriptive phrases stay out of the inverted index.
        if any(ch.isspace() for ch in keyword):
            continue
        if len(keyword) < 2 or keyword in STOP_TOKENS or keyword.isdigit():
            continue
        tokens.append(keyword)
    return tokens


def parse_annotations(path: str) -> dict[str, set[str]]:
    """Return emoji → set of Sinhala keyword tokens."""
    with open(path, encoding="utf-8") as source:
        content = source.read()
    result: dict[str, set[str]] = defaultdict(set)
    for match in ANNOTATION_RE.finditer(content):
        emoji, _atype, text = match.group(1), match.group(2), match.group(3)
        if is_skin_tone_only(emoji) or contains_skin_tone(emoji):
            # Prefer base emoji; skin tone is applied at runtime.
            continue
        for token in tokenize(text):
            result[emoji].add(token)
    return result


def parse_overlay(path: str) -> list[tuple[str, str]]:
    """TSV rows: sinhala_token\\temoji (overlay prepends, so chat terms win)."""
    rows: list[tuple[str, str]] = []
    with open(path, encoding="utf-8") as source:
        for line in source:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 2:
                raise SystemExit(f"Malformed overlay line: {line!r}")
            token, emoji = fields[0].strip(), fields[1].strip()
            if token and emoji:
                rows.append((token, emoji))
    return rows


def rank_emoji(candidates: list[str]) -> list[str]:
    return sorted(
        candidates,
        key=lambda emoji: (
            CATEGORY_RANK.get(emoji_category(emoji), 99),
            codepoint_key(emoji),
        ),
    )


def build_index(annotation_paths: list[str], overlay_path: str) -> dict[str, list[str]]:
    emoji_tokens: dict[str, set[str]] = defaultdict(set)
    for path in annotation_paths:
        for emoji, tokens in parse_annotations(path).items():
            emoji_tokens[emoji].update(tokens)

    inverted: dict[str, list[str]] = defaultdict(list)
    for emoji, tokens in emoji_tokens.items():
        for token in tokens:
            inverted[token].append(emoji)

    # Overlay first so colloquial chat spellings win the ranking slots.
    overlay_first: dict[str, list[str]] = defaultdict(list)
    for token, emoji in parse_overlay(overlay_path):
        if emoji not in overlay_first[token]:
            overlay_first[token].append(emoji)

    final: dict[str, list[str]] = {}
    all_tokens = set(inverted) | set(overlay_first)
    for token in all_tokens:
        ordered: list[str] = []
        for emoji in overlay_first.get(token, []):
            if emoji not in ordered:
                ordered.append(emoji)
        for emoji in rank_emoji(inverted.get(token, [])):
            if emoji not in ordered:
                ordered.append(emoji)
        final[token] = ordered[:MAX_PER_TOKEN]
    return dict(sorted(final.items()))


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: build_sinhala_emoji_index.py si.xml si-derived.xml overlay.tsv out.json"
        )
    si_path, derived_path, overlay_path, out_path = sys.argv[1:5]
    index = build_index([si_path, derived_path], overlay_path)
    unique_emoji = {emoji for values in index.values() for emoji in values}
    with open(out_path, "w", encoding="utf-8") as output:
        json.dump(index, output, ensure_ascii=False, separators=(",", ":"))
    print(
        f"Wrote {out_path}: {len(index)} tokens, {len(unique_emoji)} unique emoji",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
