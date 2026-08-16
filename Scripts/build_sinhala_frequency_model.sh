#!/bin/zsh
set -euo pipefail

# Builds the compact, extension-safe frequency model from the University of
# Moratuwa `word_frequency_list_2M.zip` download. The upstream source format is
# `word POS frequency`; this emits stable `word<TAB>frequency` rows.
#
# Usage:
#   Scripts/build_sinhala_frequency_model.sh /path/to/word_frequency_list_2M.zip

if (( $# != 1 )); then
  print -u2 "Usage: $0 /path/to/word_frequency_list_2M.zip"
  exit 64
fi

source_archive="$1"
output_file="AksharaKeyboard/Resources/SinhalaFrequencyModel.tsv"
temporary_file="${output_file}.tmp"

# Exclude malformed/merged corpus tokens before taking the compact top slice.
unzip -p "$source_archive" | perl -CSDA -ne '
  if (/^([\x{0D80}-\x{0DFF}]+)\s+\S+\s+(\d+)/) {
    next if length($1) > 24;
    print "$1\t$2\n";
  }
' | \
  head -n 40000 | LC_ALL=C sort -u > "$temporary_file"
mv "$temporary_file" "$output_file"
