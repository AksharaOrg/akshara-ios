#!/bin/zsh
set -euo pipefail

# Determinism smoke test for release automation. Pass any prepared, full
# redistributable export directory and the matching upstream revision.
if (( $# != 2 )); then
  print -u2 "Usage: $0 /path/to/redistributable-export <upstream-git-revision>"
  exit 64
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

for suffix in first second; do
  python3 "$root/Scripts/build_sinhala_autocorrect_index.py" \
    --export-dir "$1" \
    --source-revision "$2" \
    --lock "$root/Scripts/SinhalaDictionary.lock" \
    --output "$temporary_directory/$suffix.lexicon" \
    --metadata "$temporary_directory/$suffix.json" >/dev/null
done

cmp "$temporary_directory/first.lexicon" "$temporary_directory/second.lexicon"
cmp "$temporary_directory/first.json" "$temporary_directory/second.json"
print "Sinhala autocorrect artifact is deterministic"
