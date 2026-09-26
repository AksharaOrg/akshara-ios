#!/usr/bin/env python3
"""Build the read-only English prediction database bundled with the keyboard."""

import argparse
import json
import sqlite3
from pathlib import Path


CONVERSATION = {
    "hello": {"how": 50_000, "there": 42_000, "everyone": 16_000},
    "hi": {"how": 45_000, "there": 38_000},
    "how": {"are": 55_000, "do": 40_000},
    "thank": {"you": 60_000},
    "good": {"morning": 30_000, "night": 30_000, "afternoon": 18_000},
}


def deletion_keys(word: str) -> set[str]:
    return {word[:index] + word[index + 1 :] for index in range(len(word))}


def is_ascii_word(word: str) -> bool:
    return bool(word) and word.isascii() and word.isalpha()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--words", type=Path, required=True)
    parser.add_argument("--next-words", type=Path)
    parser.add_argument("--emoji", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    rows = json.loads(args.words.read_text(encoding="utf-8"))
    words: list[tuple[str, int]] = []
    seen: set[str] = set()
    for rank, row in enumerate(rows):
        word = str(row[0]).lower()
        if is_ascii_word(word) and word not in seen:
            seen.add(word)
            words.append((word, rank))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.unlink(missing_ok=True)
    connection = sqlite3.connect(args.output)
    connection.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = MEMORY;
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE words(word TEXT PRIMARY KEY, rank INTEGER NOT NULL) WITHOUT ROWID;
        CREATE INDEX words_rank ON words(rank);
        CREATE TABLE bigrams(
            previous TEXT NOT NULL,
            next TEXT NOT NULL,
            count INTEGER NOT NULL,
            PRIMARY KEY(previous, next)
        ) WITHOUT ROWID;
        CREATE TABLE deletions(
            deletion TEXT NOT NULL,
            word TEXT NOT NULL,
            PRIMARY KEY(deletion, word)
        ) WITHOUT ROWID;
        CREATE TABLE emoji(
            token TEXT NOT NULL,
            emoji TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            PRIMARY KEY(token, emoji)
        ) WITHOUT ROWID;
        """
    )
    connection.execute("INSERT INTO metadata VALUES('schema_version', '1')")
    connection.executemany("INSERT INTO words VALUES(?, ?)", words)
    connection.executemany(
        "INSERT INTO deletions VALUES(?, ?)",
        ((key, word) for word, _ in words if len(word) >= 2 for key in deletion_keys(word)),
    )

    bigrams: dict[tuple[str, str], int] = {}
    if args.next_words:
        for line in args.next_words.read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            if len(fields) != 3:
                continue
            previous, next_word = fields[0].lower(), fields[1].lower()
            if not is_ascii_word(previous) or not is_ascii_word(next_word):
                continue
            key = (previous, next_word)
            bigrams[key] = max(bigrams.get(key, 0), int(fields[2]))
    for previous, values in CONVERSATION.items():
        for next_word, count in values.items():
            bigrams.setdefault((previous, next_word), count)
    connection.executemany(
        "INSERT INTO bigrams VALUES(?, ?, ?)",
        ((previous, next_word, count) for (previous, next_word), count in bigrams.items()),
    )

    if args.emoji:
        entries = json.loads(args.emoji.read_text(encoding="utf-8"))
        token_emoji: dict[str, list[str]] = {}
        for emoji in sorted(entries):
            for phrase in entries[emoji]:
                if phrase.startswith("akshara-"):
                    continue
                tokens = "".join(character.lower() if character.isalpha() else " " for character in phrase).split()
                for token in tokens:
                    if len(token) < 2 or not is_ascii_word(token):
                        continue
                    values = token_emoji.setdefault(token, [])
                    if emoji not in values:
                        values.append(emoji)
        connection.executemany(
            "INSERT INTO emoji VALUES(?, ?, ?)",
            ((token, emoji, ordinal) for token, values in token_emoji.items() for ordinal, emoji in enumerate(values)),
        )

    connection.commit()
    connection.execute("VACUUM")
    connection.close()


if __name__ == "__main__":
    main()
