# Sinhala next-word model attribution

SinhalaNextWordModel.tsv is a compact, count-only bigram model derived from
the first 256 MiB (decompressed) of `corpus_part_0.gz` in **CleanSinhalaTextCorpus** by Remeinium AI
and Kusal Darshana (2025), distributed under CC BY 4.0.

- Dataset: https://huggingface.co/datasets/Remeinium/CleanSinhalaTextCorpus
- DOI: https://doi.org/10.57967/hf/6460
- License: https://creativecommons.org/licenses/by/4.0/

The source text is not distributed with Akshara. The model retains up to six
high-frequency continuations across 1,024 common preceding-word contexts,
after filtering malformed or overlong tokens.
