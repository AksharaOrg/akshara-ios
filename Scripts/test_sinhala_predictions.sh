#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
cp "$root/Scripts/TestSinhalaPrediction.swift" "$temporary_directory/main.swift"

swiftc \
  "$root/Shared/SinhalaEngine.swift" \
  "$root/Shared/KeyboardPreferences.swift" \
  "$root/Shared/SinhalaPrediction.swift" \
  "$root/Shared/KeyboardCompositionSession.swift" \
  "$temporary_directory/main.swift" \
  -o "$temporary_directory/TestSinhalaPrediction"

"$temporary_directory/TestSinhalaPrediction" "$root"
