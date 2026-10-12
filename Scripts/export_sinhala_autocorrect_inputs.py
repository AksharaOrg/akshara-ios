#!/usr/bin/env python3
"""Export verified spellings, including verified surface forms, from the pinned DB.

Run with the dictionary repository's Python environment. This is read-only;
the destination must be explicit. Licence eligibility comes from upstream's
exporter. Corpus observations supply ranking, never spelling acceptance.
"""
import argparse
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

from build_sinhala_autocorrect_index import read_lock


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dictionary-repo", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    repo = args.dictionary_repo.resolve()
    lock = read_lock(Path(__file__).with_name("SinhalaDictionary.lock"))
    revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    if revision != lock["revision"]:
        raise ValueError("dictionary checkout does not match the locked revision")
    sys.path.insert(0, str(repo / "src"))
    from sinhala_dictionary.export import allowed_sources, PROFILE_LICENCE
    db = sqlite3.connect((repo / "data/generated/lexicon.sqlite").as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    allowed = sorted(allowed_sources(db, lock["profile"]))
    marks = ",".join("?" for _ in allowed)
    # Some upstream lemma analyses retain a literal JSON escape in the lemma.
    # Only decode the two known joiner escapes; never interpret arbitrary text.
    def spelling(text):
        return text.replace("\\u200d", "\u200d").replace("\\u200c", "\u200c")
    words = {}
    for row in db.execute(f"""
        SELECT DISTINCT l.lemma,l.spelling_confidence FROM lexemes l JOIN evidence e ON e.lexeme_id=l.id
        WHERE l.language='si' AND l.spelling_status='accepted' AND l.spelling_confidence>=0.8
          AND l.spelling_tags_json LIKE '%"verified"%' AND e.source_id IN ({marks})
        """, allowed):
        word = spelling(row[0])
        words[word] = max(words.get(word, 0), row[1])
    # Inflected words may share a lexeme with an escaped or different lemma.
    # Keep only the surface itself attested as a verified word, not every form
    # attached to that lexeme by a corpus or morphology analyser.
    for row in db.execute(f"""
        SELECT DISTINCT e.original_form,l.spelling_confidence FROM evidence e JOIN lexemes l ON l.id=e.lexeme_id
        WHERE l.language='si' AND l.spelling_status='accepted' AND l.spelling_confidence>=0.8
          AND l.spelling_tags_json LIKE '%"verified"%' AND e.type='verified_word'
          AND e.source_id IN ({marks})
        """, allowed):
        if row[0]:
            word = spelling(row[0])
            words[word] = max(words.get(word, 0), row[1])
    dest = args.output_dir
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "sinhala-spelling.tsv").write_text("lemma\tstatus\tconfidence\ttags\n" +
        "".join(f"{word}\taccepted\t{words[word]}\tverified\n" for word in sorted(words)), encoding="utf-8")
    with (dest / "sinhala-frequency.tsv").open("w", encoding="utf-8") as stream:
        stream.write("normalized\tsource\traw_count\trank\n")
        for row in db.execute(f"""
            SELECT normalized,source_id,raw_count,rank FROM frequency
            WHERE language='si' AND rank>0 AND source_id IN ({marks})
            ORDER BY normalized,source_id
            """, allowed):
            word = spelling(row[0])
            if word in words:
                stream.write(f"{word}\t{row[1]}\t{row[2]}\t{row[3]}\n")
    sources = [dict(row) for row in db.execute(f"SELECT * FROM sources WHERE id IN ({marks}) ORDER BY id", allowed)]
    (dest / "manifest.json").write_text(json.dumps({"profile": lock["profile"],
        "licence": PROFILE_LICENCE[lock["profile"]], "sources": sources,
        "revision": revision, "spellingSelection": "accepted verified lemmas and verified surface evidence"},
        ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Exported {len(words)} verified spellings to {dest}")


if __name__ == "__main__":
    main()
