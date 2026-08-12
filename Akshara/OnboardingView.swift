import SwiftUI

struct OnboardingView: View {
    @State private var mode = KeyboardPreferences.selectedMode()
    @State private var emojiEnabled = KeyboardPreferences.emojiEnabled()
    @State private var hapticsEnabled = KeyboardPreferences.hapticsEnabled()

    var body: some View {
        NavigationStack {
            Form {
                Section("Akshara Keyboard") {
                    Text("A private, on-device Sinhala keyboard.")
                    Text("To enable: Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Installed Keyboard Layout") {
                    Picker("Layout", selection: $mode) {
                        ForEach(SinhalaEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    Text("This choice is used by the system keyboard the next time it appears.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Keyboard Features") {
                    Toggle("Emoji", isOn: $emojiEnabled)
                    Toggle("Haptics", isOn: $hapticsEnabled)
                    Toggle("Suggestions", isOn: .constant(false))
                        .disabled(true)
                    Text("Suggestions are temporarily disabled while the full Sinhala prediction dictionary is added.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Akshara")
            .onChange(of: mode) { newMode in
                KeyboardPreferences.setSelectedMode(newMode)
            }
            .onChange(of: emojiEnabled) { newValue in
                KeyboardPreferences.setEmojiEnabled(newValue)
            }
            .onChange(of: hapticsEnabled) { newValue in
                KeyboardPreferences.setHapticsEnabled(newValue)
            }
        }
    }
}
