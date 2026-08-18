#!/bin/zsh
set -euo pipefail

# Builds compact next-word, trigram, and sentence-start models from a UTF-8
# Sinhala sentence corpus. The source corpus is never included in the app:
# this emits only aggregate counts.
#
# Spoken-looking lines (chat verbs, pronouns, particles) are counted extra
# so conversational continuations outrank news-style function-word soup.
#
# Usage:
#   Scripts/build_sinhala_next_word_model.sh corpus_part_0.gz [corpus_part_1.gz ...]

if (( $# < 1 )); then
  print -u2 "Usage: $0 /path/to/sinhala-sentences.txt[.gz] [...]"
  exit 64
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$root/AksharaKeyboard/Resources"
bigram_output="$output_dir/SinhalaNextWordModel.tsv"
trigram_output="$output_dir/SinhalaTrigramModel.tsv"
sentence_output="$output_dir/SinhalaSentenceStartModel.tsv"
work_directory="${TMPDIR:-/tmp}/akshara-ngrams-$$"
mkdir -p "$work_directory"
trap 'rm -rf "$work_directory"' EXIT

maximum_contexts="${MAX_CONTEXTS:-30000}"
maximum_followers="${MAX_FOLLOWERS_PER_CONTEXT:-16}"
maximum_trigram_contexts="${MAX_TRIGRAM_CONTEXTS:-768}"
maximum_trigram_followers="${MAX_TRIGRAM_FOLLOWERS_PER_CONTEXT:-6}"
spoken_weight="${SPOKEN_WEIGHT:-4}"
max_input_bytes_per_file="${MAX_INPUT_BYTES:-0}"

raw_bigrams="$work_directory/bigrams.raw"
raw_trigrams="$work_directory/trigrams.raw"

export SPOKEN_WEIGHT="$spoken_weight"
export RAW_BIGRAMS="$raw_bigrams"
export RAW_TRIGRAMS="$raw_trigrams"

# Concatenate every argument, gunzipping as needed. An optional per-file byte
# cap keeps a rebuild bounded; 0 means "consume the whole file".
{
  for source_corpus in "$@"; do
    if [[ "$source_corpus" == *.gz ]]; then
      if (( max_input_bytes_per_file > 0 )); then
        gzip -dc -- "$source_corpus" | head -c "$max_input_bytes_per_file" || true
      else
        gzip -dc -- "$source_corpus"
      fi
    else
      if (( max_input_bytes_per_file > 0 )); then
        head -c "$max_input_bytes_per_file" -- "$source_corpus"
      else
        cat -- "$source_corpus"
      fi
    fi
  done
} | iconv -f UTF-8 -t UTF-8 -c | perl -CSDA -e '
  use strict;
  use warnings;
  my $spoken_weight = int($ENV{SPOKEN_WEIGHT} // 4);
  $spoken_weight = 1 if $spoken_weight < 1;
  open my $bigrams, ">:encoding(UTF-8)", $ENV{RAW_BIGRAMS} or die $!;
  open my $trigrams, ">:encoding(UTF-8)", $ENV{RAW_TRIGRAMS} or die $!;
  while (my $line = <STDIN>) {
    my @words = grep { length($_) <= 24 } $line =~ /[\x{0D80}-\x{0DFF}]+/g;
    next unless @words;
    my $spoken = (
      $line =~ /තියෙනවා|තියෙන්නේ|තිබුණා|නේද|ඕනේ|ඔයා|ඒක|මං|කරන්න|කියන්න|බලන්න|දෙන්න|ගන්න|එන්න|යන්න|වගේ|කොහොමද|මොකද|කියලා|හරි|දැන්/
      || grep { $_ =~ /නවා$/ } @words
    ) ? 1 : 0;
    my $weight = $spoken ? $spoken_weight : 1;
    for (my $index = 0; $index + 1 < @words; $index++) {
      print {$bigrams} "$weight\t$words[$index]\t$words[$index + 1]\n";
    }
    for (my $index = 0; $index + 2 < @words; $index++) {
      print {$trigrams} "$weight\t$words[$index]\t$words[$index + 1]\t$words[$index + 2]\n";
    }
  }
  close $bigrams;
  close $trigrams;
'

cap_followers() {
  local maximum_contexts="$1"
  local maximum_followers="$2"
  local field_count="$3"
  awk -v maximum_contexts="$maximum_contexts" -v maximum_followers="$maximum_followers" -v field_count="$field_count" '
  {
    count = $1
    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
    n = split($0, parts, "\t")
    if (n != field_count) next
    if (field_count == 2) {
      key = parts[1]
      rest = parts[1] "\t" parts[2] "\t" count
    } else {
      key = parts[1] "\t" parts[2]
      rest = parts[1] "\t" parts[2] "\t" parts[3] "\t" count
    }
    if (!(key in contexts)) {
      if (context_count >= maximum_contexts) next
      contexts[key] = 1
      context_count++
    }
    if (followers[key] >= maximum_followers) next
    followers[key]++
    print rest
  }'
}

sum_weighted() {
  local key_fields="$1"
  # Input: weight \t key fields...  Sum weights for identical keys, then
  # emit `count key` so the follower-cap awk can reuse the uniq -c shape.
  LC_ALL=C sort -t $'\t' -k2 -S 50% | awk -F '\t' -v key_fields="$key_fields" '
  {
    key = $2
    for (i = 3; i <= key_fields + 1; i++) key = key "\t" $i
    if (NR == 1) { prev = key; total = $1; next }
    if (key == prev) { total += $1; next }
    print total " " prev
    prev = key
    total = $1
  }
  END {
    if (NR > 0) print total " " prev
  }' | sort -rn
}

sum_weighted 2 < "$raw_bigrams" | \
  cap_followers "$maximum_contexts" "$maximum_followers" 2 | \
  LC_ALL=C sort > "$bigram_output.tmp"
mv "$bigram_output.tmp" "$bigram_output"

sum_weighted 3 < "$raw_trigrams" | \
  cap_followers "$maximum_trigram_contexts" "$maximum_trigram_followers" 3 | \
  LC_ALL=C sort > "$trigram_output.tmp"
mv "$trigram_output.tmp" "$trigram_output"

# Line-initial words in this corpus are dominated by exam templates, so empty
# context uses a curated spoken-opener list instead of raw first-of-line counts.
grep -v '^#' "$root/Scripts/SinhalaSentenceStartSeeds.tsv" | grep -v '^$' > "$sentence_output"

python3 - "$bigram_output" "$trigram_output" "$sentence_output" <<'PY'
import os
import sys

bigram_path, trigram_path, sentence_path = sys.argv[1:]
words = set()
contexts = set()
pairs = 0
with open(bigram_path, encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        contexts.add(parts[0])
        words.update(parts[:2])
        pairs += 1
trigrams = 0
trigram_contexts = set()
with open(trigram_path, encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 4:
            continue
        trigram_contexts.add((parts[0], parts[1]))
        words.update(parts[:3])
        trigrams += 1
starts = sum(1 for _ in open(sentence_path, encoding="utf-8"))
print(f"next-word pairs={pairs} contexts={len(contexts)} unique-words={len(words)}")
print(f"trigrams={trigrams} pair-contexts={len(trigram_contexts)}")
print(f"sentence-starts={starts}")
print(f"files: {os.path.getsize(bigram_path)} {os.path.getsize(trigram_path)} {os.path.getsize(sentence_path)} bytes")
if len(words) < 30000:
    print(f"warning: unique next-word vocabulary is {len(words)} (< 30000)", file=sys.stderr)
PY
