# Sinhala emoji suggestion index

`SinhalaEmojiIndex.json` is compiled from Unicode CLDR Sinhala emoji
annotations (`common/annotations/si.xml` and
`common/annotationsDerived/si.xml`) plus a small colloquial overlay in
`Scripts/SinhalaEmojiOverlay.tsv`.

Regenerate with:

```bash
python3 Scripts/build_sinhala_emoji_index.py \
  .corpus-cache/cldr/si.xml \
  .corpus-cache/cldr/si-derived.xml \
  Scripts/SinhalaEmojiOverlay.tsv \
  AksharaKeyboard/Resources/SinhalaEmojiIndex.json
```

CLDR data © Unicode, Inc. Licensed under the [Unicode License V3](https://www.unicode.org/license.txt).
