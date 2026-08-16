#!/bin/zsh
set -euo pipefail

# Builds a compact next-word model from a UTF-8 Sinhala sentence corpus. The
# source corpus is never included in the app: this emits only aggregate word
# pair counts.
#
# Usage:
#   MAX_INPUT_BYTES=268435456 Scripts/build_sinhala_next_word_model.sh /path/to/sinhala-sentences.txt[.gz]

if (( $# != 1 )); then
  print -u2 "Usage: $0 /path/to/sinhala-sentences.txt"
  exit 64
fi

source_corpus="$1"
output_file="AksharaKeyboard/Resources/SinhalaNextWordModel.tsv"
temporary_file="${output_file}.tmp"
max_input_bytes="${MAX_INPUT_BYTES:-268435456}"
maximum_contexts="${MAX_CONTEXTS:-1024}"
maximum_followers="${MAX_FOLLOWERS_PER_CONTEXT:-6}"

# Keep several continuations for many common contexts, rather than only the
# globally strongest pairs. The result remains small enough for an input
# extension while making contextual prediction materially less sparse.
{
  if [[ "$source_corpus" == *.gz ]]; then
    # `head` intentionally closes the stream after the sample limit; ignore
    # gzip's resulting SIGPIPE while preserving decompression failures before
    # any output is produced.
    gzip -dc -- "$source_corpus" | head -c "$max_input_bytes" || true
  else
    head -c "$max_input_bytes" -- "$source_corpus"
  fi
} | iconv -f UTF-8 -t UTF-8 -c | perl -CSDA -ne '
  @words = grep { length($_) <= 24 } /[\x{0D80}-\x{0DFF}]+/g;
  for ($index = 0; $index + 1 < @words; $index++) {
    print "$words[$index]\t$words[$index + 1]\n";
  }
' | LC_ALL=C sort | uniq -c | sort -rn | \
  awk -v maximum_contexts="$maximum_contexts" -v maximum_followers="$maximum_followers" '
  {
    count = $1
    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
    fields = split($0, pair, "\t")
    if (fields != 2) next
    preceding = pair[1]
    if (!(preceding in contexts)) {
      if (context_count >= maximum_contexts) next
      contexts[preceding] = 1
      context_count++
    }
    if (followers[preceding] >= maximum_followers) next
    followers[preceding]++
    print preceding "\t" pair[2] "\t" count
  }' | LC_ALL=C sort > "$temporary_file"

mv "$temporary_file" "$output_file"
