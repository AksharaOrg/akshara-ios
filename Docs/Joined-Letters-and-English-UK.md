# Joined Sinhala letters and English (UK)

Audit and implementation: 12 October 2026. All changes remain local.

## Sinhala findings

The spelling compiler accepted only scalars in the Sinhala Unicode block.
ZWJ (U+200D) and ZWNJ (U+200C) are outside that block, so it discarded
joined spellings. The shipped 8,000-word lexicon contained **zero joiners**.
Some pinned upstream lemma analyses also contained literal `\u200d` text,
while their verified surface evidence contained the actual Unicode joiner.
Exporting only those lemmas missed common spellings and inflected forms.

The new read-only exporter uses the pinned repository's licence-profile
filter, accepted verified lemmas and accepted verified surface evidence.
Corpus observations rank those words; they cannot make a spelling accepted.
It decodes only the two known joiner escapes and preserves actual spelling
confidence. The rebuilt lexicon retains the 8,000-word size limit and lowest
frequency-rank rule, and contains **477 joined spellings**. Its SHA-256 is
`8af0034b9c9828d8fff1bca04a9deb131ee0f74647dc243440118f1abdfb5c14`.
The upstream revision remains `83ba4423ca20784857563cf76ff4648411e3db76`.

Wijesekara previously appended a complete join suffix after an existing hal,
producing a duplicate hal. It now recomposes the last owned syllable. Yansaya,
rakaransaya, repaya and touching/conjunct tokens preserve vowel placement.
Short verified words such as `ශ්‍රී` remain recognised, while general typo
correction still requires three graphemes. Join-only equivalents can restore
a missing join when the verified spelling is unique. Valid optional repaya
and classical joins remain as typed. Deletion postings retain all candidates;
truncation can no longer make an ambiguous typo appear unique.

This fixes encoding, missing verified forms and composition defects. The
verified upstream research list remains the spelling source; this audit is
not a linguistic review of every rare or borrowed word in that source.

## English changes

The iOS extension uses public `UITextChecker` APIs with `en_GB` for spelling,
guesses and completions. The existing frequency database still ranks words.
An entry such as corpus `teh` no longer establishes correct spelling. Native
automatic guesses must still be one edit or one adjacent swap away, and must
be a single valid word. Protected literals, mixed-case identifiers, selection,
mid-word cursor positions and stale requests retain their existing guards.

Contractions, Latin accented words, capital `I`, immediate correction undo,
comma/colon/semicolon correction boundaries, double-tap caps lock, accented
letter long presses and a primary `£` key are supported. Smart Quotes controls
curved apostrophes in suggested/corrected contractions. Natural learning does
not promote a system-rejected misspelling. Caps lock also applies to the rail.
The active keyboard language is `en-GB`.

Apple's public spelling checker does not expose all of the system keyboard's
private contextual prediction model. This brings common typing behaviour
closer to English (UK); it does not reproduce every native prediction.

## Rebuild

Use the dictionary checkout's Python environment (which supplies PyYAML):

```sh
/path/to/akshara-dictionary/.venv/bin/python Scripts/export_sinhala_autocorrect_inputs.py \
  --dictionary-repo /path/to/akshara-dictionary \
  --output-dir /tmp/akshara-spelling-export
zsh Scripts/build_sinhala_autocorrect_index.sh /tmp/akshara-spelling-export \
  83ba4423ca20784857563cf76ff4648411e3db76
```

The exporter does not modify the dictionary checkout or its database. Existing
official spelling exports remain accepted by the compiler; the surface-aware
exporter is needed to retain the verified forms described above.

## Validation

- Compiler regression covers yansaya, rakaransaya, repaya, conjuncts, ZWNJ,
  and rejection of unverified, low-confidence and foreign tokens.
- Shared Swift regressions cover joined spelling acceptance/correction,
  optional join preservation, hal deduplication, late vowel/join ordering,
  owned-tail limits, UK checker decisions, learning, undo and caps lock.
- Indexed and fallback correction results match. Sidecars are deterministic
  and source-hash checked.
- Android Smart Phonetic V2 golden suite: 96,919 rows, zero differences;
  1,872 incremental checks and all 16 spelling-option combinations pass.
- Existing iPhone 17 Pro simulator, iOS 26.5, actual installed extension:
  `විද්යාව` → Space → `විද්‍යාව`; Backspace restores `විද්යාව`.
  `ක්රියා` → Space → `ක්‍රියා`. Selecting yansaya after a hal produces
  `විද්‍යාව` without a duplicate hal, and Space preserves it.
- Apple's installed English (UK) keyboard produced `the don’t I’m I` from
  `teh dont im i`. Akshara produced `The don’t I’m I` (with sentence
  capitalisation). Immediate Backspace restored lowercase `i`. Double Shift
  produced `HELLO` and stayed locked after Space.
- Final build: a stationary long press on E inserts E, comma corrects `Teh`
  to `The,`, the numeric layer inserts `£`, caps lock produces uppercase
  next-word suggestions, and Space preserves the classical conjunct `අක්‍ෂර`.

Simulator screenshots: [caps lock](Testing/Joined-Letters-English-UK/caps-lock.jpg)
and [classical conjunct](Testing/Joined-Letters-English-UK/classical-conjunct.jpg).

Simulator test preferences are restored after validation; no commit or push
is made.
