import SwiftUI

struct OnboardingView: View {
    @State private var source = "amma"
    @State private var mode = KeyboardPreferences.selectedMode()

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
                Section("Try the selected layout") {
                    TextField("Roman input", text: $source)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Sinhala output", value: SinhalaEngine.transliterate(source, mode: mode))
                }
            }
            .navigationTitle("Akshara")
            .onChange(of: mode) { newMode in
                KeyboardPreferences.setSelectedMode(newMode)
            }
        }
    }
}
