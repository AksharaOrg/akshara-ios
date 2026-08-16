#!/bin/zsh
set -euo pipefail

# Builds a compact next-word model from a UTF-8 Sinhala sentence corpus. The
# source corpus is never included in the app: this emits only aggregate word
# pair counts.
#
# Usage:
#   Scripts/build_sinhala_next_word_model.sh /path/to/sinhala-sentences.txt

if (( $# != 1 )); then
  print -u2 "Usage: $0 /path/to/sinhala-sentences.txt"
  exit 64
fi

source_corpus="$1"
output_file="AksharaKeyboard/Resources/SinhalaNextWordModel.tsv"
temporary_file="${output_file}.tmp"

# Keep the strongest 512 pairs. This is intentionally small enough for an
# input extension, while retaining several continuations for common contexts.
perl -CSDA -ne '
  @words = /[\x{0D80}-\x{0DFF}]+/g;
  for ($index = 0; $index + 1 < @words; $index++) {
    print "$words[$index]\t$words[$index + 1]\n";
  }
' "$source_corpus" | LC_ALL=C sort | uniq -c | sort -rn | head -n 512 | \
  awk '{
    count = $1
    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
    fields = split($0, pair, "\t")
    if (fields == 2) print pair[1] "\t" pair[2] "\t" count
  }' | LC_ALL=C sort > "$temporary_file"

mv "$temporary_file" "$output_file"
