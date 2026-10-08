# Sinhala dictionary and correction audit

Investigated 2026-09-29. This is a source and feasibility review. Production
resources and correction behavior have not been changed.

## Where SinhalaUniPro's dictionary came from

Inspected [SinhalaUniPro dictionary_data.js](https://github.com/cdeshapriya912/SinhalaUniPro/blob/ff2af36/dictionary_data.js)
and its full Git history. The file first appears in commit
`fe3eded33474f15cb6d42917a09de7fab0a8b215` on 2026-09-27. It contains:

| Section | Unique entries |
| --- | ---: |
| Correct words | 24,663 |
| Incorrect words | 28,623 |
| Direct correction pairs | 9,734 |

The file is 1,920,476 bytes. The engine names `sinhala_words_dataset.json`
as its input, but that file, a build script, and a dictionary attribution are
absent from the repository. The README credits UCSC LTRL for the
transliteration scheme. That credit does not establish a dictionary source.
There is no explicit repository license in the inspected tree.

A strong vocabulary fingerprint connects it to
[slwdc/Sinhala-Words-List](https://github.com/slwdc/Sinhala-Words-List),
published as the npm package `sinhala-words` by Ayesh Karunaratne. At revision
`2cd4f32b7091c9a0c4eeb043748817d6f5d32a7f`, **all 24,961 words** in `si.txt`
occur in the union of SinhalaUniPro's correct and incorrect arrays after
removing the first word's UTF-8 BOM. Of the unmodified source strings, 11,300
occur in the correct array and 13,707 in the incorrect array, with overlaps.
This is strong evidence of shared underlying vocabulary, not proof that the
author imported this repository directly. The intermediate JSON and its
labeling procedure remain unverified. The older repository's
[LICENSE](https://github.com/slwdc/Sinhala-Words-List/blob/master/LICENSE)
and package metadata identify GPL-3.0.

Also compared NimsaraLiyanage's labeled `data-spell-checker.xlsx` and
TharushaSachinthana's `sorted_sinhala_words.csv`. They share vocabulary but
neither establishes the exact input JSON or transformation. Do not describe
either as the confirmed upstream.

## What its correction engine does

[spellchecker.js](https://github.com/cdeshapriya912/SinhalaUniPro/blob/ff2af36/spellchecker.js)
prioritizes direct fixes, then Sinhala confusion-pair substitutions, then
Damerau-Levenshtein candidates within distance two. It also accepts certain
suffix forms and maintains personal words. The distance search scans nearby
length buckets and uses JavaScript UTF-16 units. Its ranking has no corpus
frequency score. These implementation details matter for a keyboard's
latency and suggestion quality.

Every one of its 9,734 direct pairs can be reproduced by replacing all
occurrences of one side of a confusion pair with the other. The pairs cover
න/ණ, ල/ළ, ස/ශ/ෂ, aspirated consonants, and short/long vowel signs. This proves
that these pairs are mechanically reproducible; it does not establish how
they were originally generated or reviewed.

The raw data labels **96 words both correct and incorrect**, and 62 direct
correction keys also occur in the correct list. The engine's exact-known-word
check takes precedence, so some direct mappings do not take effect through
`checkWord`. These labels should not become our spelling authority.

## What Akshara already supports

`Shared/SinhalaAutocorrection.swift` loads 8,000 verified spellings selected
from our pinned Akshara Dictionary export, whose spelling source is the UoM
verified list. The binary lexicon is 178,941 bytes. It supports one-grapheme
insertion, deletion, and substitution, with frequency-ranked suggestions.
Automatic replacement requires exactly one candidate. Known exact words and
protected user words receive no correction.

Desktop probes against the current production lexicon:

| Input | Current result |
| --- | --- |
| ගෙදරා | Automatically corrects to ගෙදර |
| ආයුබොවන් | Automatically corrects to ආයුබෝවන් |
| ළංකාව | Suggests ලංකාව and නෞකාව; no automatic replacement |
| පාසළ | Suggests පාසල්, පාසලේ, පාසල; no automatic replacement |
| ගදෙර | No suggestion for ගෙදර |
| ලන්කාව | No suggestion for ලංකාව |

The last two expose gaps caused by grapheme segmentation: moving a vowel
sign changes two graphemes, and න් versus ං changes grapheme structure.
Adjacent transpositions are also unsupported. Adding only a transposition
check to the current distance function would be insufficient: candidate
generation must retrieve the transposed word too.

We can add bounded, Sinhala-aware confusion and transposition candidates
using our own verified lexicon. Validate generated candidates against trusted
words and rank them by edit type, frequency, and context. Initially expose
the broader candidates as suggestions, retaining conservative automatic
replacement and undo protection. A tiny curated exception table can cover
errors that rules cannot express. There is no need to bundle a large
incorrect-word list or the 9,734 mechanically reproducible pairs.

Avoid copying broad suffix stripping without linguistic validation. Keep
word-acceptance coverage separate from the smaller set of words eligible as
correction targets: reducing the target list must not make legitimate rare
words look misspelled. The current deletion-index cap of 12 IDs per key also
needs review before extending automatic-replacement guarantees, because
truncated candidates cannot prove a correction is unambiguous.

## Where to reduce dictionary size

Measured source-resource sizes, in decimal MB:

| Resource | Current size |
| --- | ---: |
| Sinhala next-word pairs | 18.489 MB |
| Sinhala frequency words | 0.908 MB |
| Sinhala autocorrect lexicon | 0.179 MB |
| Sinhala trigrams | 0.196 MB |
| English prediction SQLite | 6.066 MB |

The English JSON/TSV source files remain in the repository, but the current
Xcode resource phase ships the SQLite database rather than those source
files. Removing those source files would not reduce the app bundle.

The biggest opportunity is the next-word table: 455,815 pairs, 29,999
contexts, and 52,022 distinct words. A temporary binary prototype stores
each UTF-8 word once, a UInt32 offset table, and UInt32 word-ID/word-ID/count
records. It occupies **6,879,778 bytes versus 18,489,071 bytes**, a **62.79%
reduction**, saving 11.61 MB. Decoding every record reproduced all original
word pairs and counts exactly. This prototype is not wired into the app.
Production work needs a deterministic builder, validated format reader,
context lookup, and prediction-equivalence checks. Its size result is not a
device latency or memory measurement, and App Store compression affects the
download-size saving.

Pruning to six followers per context would instead produce a 7.10 MB TSV,
but lose 278,871 pairs. A small visible suggestion rail does not establish
that these pairs are dispensable: prefix filtering, contextual reranking,
personal learning, and rejected suggestions can use lower-ranked followers.
Prefer lossless encoding before vocabulary or follower pruning.

## Recommended implementation order

1. Replace the repeated-string next-word TSV with a memory-mappable binary
   vocabulary and word-ID table, preserving all pairs and counts.
2. Add bounded Sinhala confusion and transposition suggestions against our
   trusted lexicon, with regressions for missed corrections and valid words.
3. Evaluate optional context/follower pruning against held-out conversational
   text and physical-device measurements before reducing coverage further.

Validation performed: `zsh Scripts/test_sinhala_predictions.sh` passes,
including prediction, autocorrection, composition, learning, English, and
protected-word checks. Additional temporary Swift probes produced the table
above. No production code or data was modified for this investigation.
