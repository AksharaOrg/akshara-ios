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

unzip -p "$source_archive" | awk 'NF >= 3 { print $1 "\t" $3 }' | \
  head -n 40000 | LC_ALL=C sort -u > "$temporary_file"
mv "$temporary_file" "$output_file"
