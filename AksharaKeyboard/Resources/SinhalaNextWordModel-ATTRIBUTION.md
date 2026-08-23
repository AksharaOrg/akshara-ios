# Sinhala n-gram model attribution

`SinhalaNextWordModel.tsv`, `SinhalaTrigramModel.tsv`, and
`SinhalaSentenceStartModel.tsv` are compact, count-only models used by Akshara.

The next-word and trigram tables are derived from the full `corpus_part_0.gz`
(~1.0 GiB decompressed) in **CleanSinhalaTextCorpus** by Remeinium AI and
Kusal Darshana (2025), distributed under CC BY 4.0.

- Dataset: https://huggingface.co/datasets/Remeinium/CleanSinhalaTextCorpus
- DOI: https://doi.org/10.57967/hf/6460
- License: https://creativecommons.org/licenses/by/4.0/

The source text is not distributed with Akshara. Tokens in
`Scripts/SinhalaBlockedWords.txt` are dropped during counting. Conversational lines are
up-weighted during counting so chat-like continuations outrank news-style
function words. The next-word table keeps up to sixteen continuations for
30,000 preceding-word contexts (about 52,000 unique words). A smaller trigram
table supplies two-word backoff. Empty-context suggestions use a curated
spoken-opener list rather than line-initial corpus counts, which in this
dataset are dominated by exam templates.
