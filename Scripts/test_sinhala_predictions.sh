#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
cp "$root/Scripts/TestSinhalaPrediction.swift" "$temporary_directory/main.swift"
cat > "$temporary_directory/ClipboardHistoryStoreStub.swift" <<'EOF'
enum ClipboardHistoryStore {
    static func clearAll() {}
}
EOF

swiftc \
  "$root/Shared/SinhalaEngine.swift" \
  "$root/Shared/KeyboardPreferences.swift" \
  "$root/Shared/SinhalaPrediction.swift" \
  "$root/Shared/SinhalaAutocorrection.swift" \
  "$root/Shared/KeyboardCompositionSession.swift" \
  "$root/Shared/SinhalaEmojiSuggestions.swift" \
  "$root/Shared/EmojiSkinTone.swift" \
  "$temporary_directory/ClipboardHistoryStoreStub.swift" \
  "$temporary_directory/main.swift" \
  -o "$temporary_directory/TestSinhalaPrediction"

"$temporary_directory/TestSinhalaPrediction" "$root"
