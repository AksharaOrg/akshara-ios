#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
cp "$root/Scripts/BenchmarkKeyboardRuntime.swift" "$temporary_directory/main.swift"
cat > "$temporary_directory/ClipboardHistoryStoreStub.swift" <<'EOF'
enum ClipboardHistoryStore {
    static func clearAll() {}
}
EOF

swiftc -module-cache-path "$temporary_directory/module-cache" -O \
  "$root/Shared/KeyboardRuntime.swift" \
  "$root/Shared/SinhalaEngine.swift" \
  "$root/Shared/SmartPhoneticV2.swift" \
  "$root/Shared/SinhalaSoundLexicon.swift" \
  "$root/Shared/KeyboardPreferences.swift" \
  "$root/Shared/SinhalaPrediction.swift" \
  "$root/Shared/EnglishPrediction.swift" \
  "$root/Shared/KeyboardBottomRow.swift" \
  "$root/Shared/SinhalaAutocorrection.swift" \
  "$root/Shared/KeyboardCompositionSession.swift" \
  "$root/Shared/SinhalaEmojiSuggestions.swift" \
  "$root/Shared/EmojiSkinTone.swift" \
  "$temporary_directory/ClipboardHistoryStoreStub.swift" \
  "$temporary_directory/main.swift" \
  -o "$temporary_directory/BenchmarkKeyboardRuntime"

"$temporary_directory/BenchmarkKeyboardRuntime" "$root"
