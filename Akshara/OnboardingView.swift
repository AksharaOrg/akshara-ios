import SwiftUI
import UIKit

private enum AksharaLinks {
    static let github = URL(string: "https://github.com/AksharaOrg/akshara-ios")!
    static let website = URL(string: "https://akshara.org.lk")!
    static let appleKeyboardGuide = URL(string: "https://support.apple.com/guide/iphone/add-or-change-keyboards-iph73b71eb/ios")!
}

struct OnboardingView: View {
    @State private var mode = KeyboardPreferences.selectedMode()

    var body: some View {
        NavigationStack {
            Form {
                Section("Installed Keyboard Layout") {
                    Picker("Layout", selection: $mode) {
                        ForEach(SinhalaEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    Text("This choice is used by the system keyboard the next time it appears.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Akshara Keyboard") {
                    Text("A private, on-device Sinhala keyboard.")
                    Text("To enable: Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Apple: Add a third-party keyboard", destination: AksharaLinks.appleKeyboardGuide)
                }

                Section {
                    NavigationLink("Keyboard Settings") {
                        KeyboardSettingsView()
                    }
                }

                Section {
                    Link("Visit Website", destination: AksharaLinks.website)
                    Link("View on GitHub", destination: AksharaLinks.github)
                    Text("© 2026 Lahiru Himesh Madusanka · MIT License")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Akshara")
            .onChange(of: mode) { KeyboardPreferences.setSelectedMode($0) }
        }
    }
}

private struct KeyboardSettingsView: View {
    @State private var emojiEnabled = KeyboardPreferences.emojiEnabled()
    @State private var suggestionsEnabled = KeyboardPreferences.suggestionsEnabled()
    @State private var doubleSpacePeriodEnabled = KeyboardPreferences.doubleSpacePeriodEnabled()
    @State private var numberRowEnabled = KeyboardPreferences.numberRowEnabled()
    @State private var longPressPunctuationEnabled = KeyboardPreferences.longPressPunctuationEnabled()
    @State private var smartQuotesEnabled = KeyboardPreferences.smartQuotesEnabled()
    @State private var characterPreviewEnabled = KeyboardPreferences.characterPreviewEnabled()

    var body: some View {
        Form {
            Section("Keyboard Features") {
                Toggle("Emoji", isOn: $emojiEnabled)
                Toggle("Suggestions", isOn: $suggestionsEnabled)
                Text("On-device word completion and next-word suggestions. Your text never leaves the device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Haptics") {
                    HapticsSettingsView()
                }
            }

            Section("Typing") {
                Toggle("Character Preview", isOn: $characterPreviewEnabled)
                Toggle("Number Row", isOn: $numberRowEnabled)
                Toggle("Double-Space Period", isOn: $doubleSpacePeriodEnabled)
                Toggle("Long-Press Punctuation", isOn: $longPressPunctuationEnabled)
                Toggle("Smart Quotes", isOn: $smartQuotesEnabled)
                Text("Character Preview enlarges a pressed character. Hold punctuation keys for related marks. Smart Quotes changes straight quotes to typographic opening and closing quotes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Learn") {
                NavigationLink("Layout Quick Reference") {
                    LayoutReferenceView()
                }
            }
        }
        .navigationTitle("Keyboard Settings")
        .onChange(of: emojiEnabled) { KeyboardPreferences.setEmojiEnabled($0) }
        .onChange(of: suggestionsEnabled) { KeyboardPreferences.setSuggestionsEnabled($0) }
        .onChange(of: doubleSpacePeriodEnabled) { KeyboardPreferences.setDoubleSpacePeriodEnabled($0) }
        .onChange(of: numberRowEnabled) { KeyboardPreferences.setNumberRowEnabled($0) }
        .onChange(of: longPressPunctuationEnabled) { KeyboardPreferences.setLongPressPunctuationEnabled($0) }
        .onChange(of: smartQuotesEnabled) { KeyboardPreferences.setSmartQuotesEnabled($0) }
        .onChange(of: characterPreviewEnabled) { KeyboardPreferences.setCharacterPreviewEnabled($0) }
    }
}

private struct LayoutReferenceView: View {
    @State private var mode = KeyboardPreferences.selectedMode()

    private var entries: [(String, String)] {
        switch mode {
        case .sls:
            return [("q", "ු"), ("w", "අ"), ("e", "ැ"), ("r", "ර"), ("t", "එ"),
                    ("y", "හ"), ("u", "ම"), ("i", "ස"), ("o", "ද"), ("p", "ච"),
                    ("a", "්"), ("s", "ි"), ("d", "ා"), ("f", "ෙ"), ("g", "ට"),
                    ("h", "ය"), ("j", "ව"), ("k", "න"), ("l", "ක"), (";", "ත"),
                    ("Long press . c v o", "ඟ  ඦ  ඬ  ඳ")]
        case .phonetic:
            return [("k / g / t / d", "ක / ග / ට / ඩ"), ("th / dh", "ත / ද"),
                    ("sh / Sh", "ශ / ෂ"), ("aa / ii / uu", "ා / ී / ූ"),
                    ("ee / ai / oo", "ේ / ෛ / ෝ"), ("M / H", "ං / ඃ"),
                    ("y / r after a consonant", "්‍ය / ්‍ර")]
        case .smartPhonetic:
            return [("k / g / q", "ක / ග / ද"), ("t / T / th / thh", "ට / ට / ත / ථ"),
                    ("z + g/j/d/q", "ඟ / ඦ / ඬ / ඳ"), ("aa / Aa", "ා /ෑ"),
                    ("ru / ruu", "ෘ / ෲ"), ("M, x, or zn", "ං"),
                    ("S / Sh", "ෂ / ෂ")]
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Layout", selection: $mode) {
                    ForEach(SinhalaEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(mode.rawValue) {
                ForEach(entries, id: \.0) { key, result in
                    HStack {
                        Text(key).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(result).font(.title3)
                    }
                }
            }
            Section("Tips") {
                Text("Use Shift for the alternate layer. Hold punctuation keys for related marks, and hold Space to move the cursor.")
            }
        }
        .navigationTitle("Quick Reference")
    }
}

private struct HapticsSettingsView: View {
    @State private var hapticsEnabled = KeyboardPreferences.hapticsEnabled()
    @State private var fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()

    var body: some View {
        Form {
            Section("Haptics") {
                Toggle("Key Haptics", isOn: $hapticsEnabled)
                    .disabled(!fullAccessConfirmed)
                Text(fullAccessConfirmed
                    ? "Light haptic feedback plays when you touch a key."
                    : "Full Access must be enabled before key haptics can be used.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Full Access") {
                Label(
                    fullAccessConfirmed ? "Full Access confirmed" : "Full Access required",
                    systemImage: fullAccessConfirmed ? "checkmark.circle.fill" : "lock.fill"
                )
                .foregroundStyle(fullAccessConfirmed ? .green : .secondary)
                Text("Settings → General → Keyboard → Keyboards → Akshara → Allow Full Access. Then open the Akshara keyboard once and return here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Akshara Settings") {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(settingsURL)
                }
            }
        }
        .navigationTitle("Haptics")
        .onChange(of: hapticsEnabled) { KeyboardPreferences.setHapticsEnabled($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
        }
    }
}

#Preview {
    NavigationStack { OnboardingView() }
}
