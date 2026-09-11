#!/bin/zsh
set -euo pipefail

# Build from a generated public export, never from raw corpus data. CI should
# check out the revision in SinhalaDictionary.lock, run the upstream imports and
# `dictionary export redistributable`, then pass that export directory here.
if (( $# != 2 )); then
  print -u2 "Usage: $0 /path/to/redistributable-export <upstream-git-revision>"
  exit 64
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$root/Scripts/build_sinhala_autocorrect_index.py" \
  --export-dir "$1" \
  --source-revision "$2" \
  --lock "$root/Scripts/SinhalaDictionary.lock" \
  --output "$root/AksharaKeyboard/Resources/SinhalaAutocorrect.lexicon" \
  --metadata "$root/AksharaKeyboard/Resources/SinhalaAutocorrectMetadata.json"
