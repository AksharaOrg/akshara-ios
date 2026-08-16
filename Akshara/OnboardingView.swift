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
                Section("Keyboard") {
                    Picker(selection: $mode) {
                        ForEach(SinhalaEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
                    } label: {
                        DashboardLabel(title: "Layout", icon: "keyboard", color: .blue)
                    }
                    .pickerStyle(.navigationLink)
                    NavigationLink {
                        KeyboardSettingsView()
                    } label: {
                        DashboardLabel(title: "Keyboard Settings", icon: "slider.horizontal.3", color: .gray)
                    }
                }

                Section("Reference") {
                    NavigationLink {
                        LayoutReferenceView()
                    } label: {
                        DashboardLabel(title: "Layout Quick Reference", icon: "keyboard.badge.ellipsis", color: .purple)
                    }
                }

                Section("Set Up") {
                    Link(destination: AksharaLinks.appleKeyboardGuide) {
                        DashboardLabel(title: "Add Akshara Keyboard", icon: "keyboard", color: .green)
                    }
                }

                Section("Links") {
                    Link(destination: AksharaLinks.website) {
                        DashboardLabel(title: "Website", icon: "globe", color: .blue)
                    }
                    Link(destination: AksharaLinks.github) {
                        DashboardLabel(title: "GitHub", icon: "chevron.left.forwardslash.chevron.right", color: .indigo)
                    }
                }

                Section("About") {
                    LabeledContent("Copyright", value: "© 2026 Lahiru Himesh Madusanka")
                    LabeledContent("License", value: "MIT License")
                }
            }
            .navigationTitle("Akshara")
            .onChange(of: mode) { KeyboardPreferences.setSelectedMode($0) }
        }
    }
}

private struct DashboardLabel: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
        }
    }
}

private struct KeyboardSettingsView: View {
    @State private var emojiEnabled = KeyboardPreferences.emojiEnabled()
    @State private var suggestionsEnabled = KeyboardPreferences.suggestionsEnabled()
    @State private var doubleSpacePeriodEnabled = KeyboardPreferences.doubleSpacePeriodEnabled()
    @State private var topRow = KeyboardPreferences.topRow()
    @State private var longPressPunctuationEnabled = KeyboardPreferences.longPressPunctuationEnabled()
    @State private var smartQuotesEnabled = KeyboardPreferences.smartQuotesEnabled()
    @State private var characterPreviewEnabled = KeyboardPreferences.characterPreviewEnabled()
    @State private var keySpacing = KeyboardPreferences.keySpacing()
    @State private var oneHandedPosition = KeyboardPreferences.oneHandedPosition()
    @State private var appearance = KeyboardPreferences.appearance()
    @State private var highContrastEnabled = KeyboardPreferences.highContrastEnabled()
    @State private var deleteRepeatSpeed = KeyboardPreferences.deleteRepeatSpeed()

    var body: some View {
        Form {
            Section("Keyboard Features") {
                Toggle(isOn: $emojiEnabled) {
                    SettingLabel(title: "Emoji key", detail: "Shows the emoji picker", icon: "face.smiling", color: .orange)
                }
                Toggle(isOn: $suggestionsEnabled) {
                    SettingLabel(title: "Suggestions", detail: "Shows word completions", icon: "text.badge.plus", color: .indigo)
                }
                NavigationLink {
                    HapticsSettingsView()
                } label: {
                    SettingLabel(title: "Haptics", detail: "Sound and haptic feedback", icon: "waveform", color: .red)
                }
            }

            Section("Typing") {
                Toggle(isOn: $characterPreviewEnabled) {
                    SettingLabel(title: "Character Preview", detail: "Enlarges the pressed key", icon: "textformat.size", color: .blue)
                }
                Picker(selection: $topRow) {
                    ForEach(KeyboardPreferences.TopRow.allCases) { row in
                        Text(row.title).tag(row)
                    }
                } label: {
                    SettingLabel(title: "Keyboard top row", detail: "Above the letter keys", icon: "rectangle.topthird.inset.filled", color: .green)
                }
                .accessibilityHint("Choose whether the row above the letters shows emoji, numbers, or nothing.")
                Toggle("Double-space period", isOn: $doubleSpacePeriodEnabled)
                Toggle("Long-press punctuation", isOn: $longPressPunctuationEnabled)
                Toggle("Smart quotes", isOn: $smartQuotesEnabled)
                Picker(selection: $deleteRepeatSpeed) {
                    ForEach(KeyboardPreferences.DeleteRepeatSpeed.allCases) { value in
                        Text(value.title).tag(value)
                    }
                } label: {
                    SettingLabel(title: "Delete repeat", detail: "Speed while holding Delete", icon: "delete.left", color: .red)
                }
            }

            Section("Layout") {
                Picker(selection: $keySpacing) {
                    ForEach(KeyboardPreferences.KeySpacing.allCases) { value in
                        Text(value.title).tag(value)
                    }
                } label: {
                    SettingLabel(title: "Key spacing", detail: "Horizontal and vertical gaps", icon: "arrow.left.and.right", color: .teal)
                }
                Picker(selection: $oneHandedPosition) {
                    ForEach(KeyboardPreferences.OneHandedPosition.allCases) { value in
                        Text(value.title).tag(value)
                    }
                } label: {
                    SettingLabel(title: "One-handed", detail: "Aligns a narrower key grid", icon: "hand.tap", color: .purple)
                }
            }

            Section("Appearance") {
                Picker(selection: $appearance) {
                    ForEach(KeyboardPreferences.Appearance.allCases) { value in
                        Text(value.title).tag(value)
                    }
                } label: {
                    SettingLabel(title: "Theme", detail: "System, light, or dark", icon: "circle.lefthalf.filled", color: .gray)
                }
                Toggle("Higher key contrast", isOn: $highContrastEnabled)
            }

        }
        .navigationTitle("Keyboard Settings")
        .onChange(of: emojiEnabled) { KeyboardPreferences.setEmojiEnabled($0) }
        .onChange(of: suggestionsEnabled) { KeyboardPreferences.setSuggestionsEnabled($0) }
        .onChange(of: doubleSpacePeriodEnabled) { KeyboardPreferences.setDoubleSpacePeriodEnabled($0) }
        .onChange(of: topRow) { KeyboardPreferences.setTopRow($0) }
        .onChange(of: longPressPunctuationEnabled) { KeyboardPreferences.setLongPressPunctuationEnabled($0) }
        .onChange(of: smartQuotesEnabled) { KeyboardPreferences.setSmartQuotesEnabled($0) }
        .onChange(of: characterPreviewEnabled) { KeyboardPreferences.setCharacterPreviewEnabled($0) }
        .onChange(of: keySpacing) { KeyboardPreferences.setKeySpacing($0) }
        .onChange(of: oneHandedPosition) { KeyboardPreferences.setOneHandedPosition($0) }
        .onChange(of: appearance) { KeyboardPreferences.setAppearance($0) }
        .onChange(of: highContrastEnabled) { KeyboardPreferences.setHighContrastEnabled($0) }
        .onChange(of: deleteRepeatSpeed) { KeyboardPreferences.setDeleteRepeatSpeed($0) }
    }
}

private struct SettingLabel: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
    @State private var hapticStrength = KeyboardPreferences.hapticStrength()
    @State private var keyClicksEnabled = KeyboardPreferences.keyClicksEnabled()
    @State private var fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
    @State private var testFeedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Form {
            Section("Feedback") {
                Toggle("Key Haptics", isOn: $hapticsEnabled)
                    .disabled(!fullAccessConfirmed)
                Picker("Strength", selection: $hapticStrength) {
                    ForEach(KeyboardPreferences.HapticStrength.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .disabled(!hapticsEnabled || !fullAccessConfirmed)
                Button {
                    testFeedback.impactOccurred(intensity: CGFloat(hapticStrength.intensity))
                    testFeedback.prepare()
                } label: {
                    Label("Test haptic", systemImage: "hand.tap.fill")
                }
                .disabled(!hapticsEnabled || !fullAccessConfirmed)
                Toggle("Key Clicks", isOn: $keyClicksEnabled)
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
        .onAppear { testFeedback.prepare() }
        .onChange(of: hapticsEnabled) { KeyboardPreferences.setHapticsEnabled($0) }
        .onChange(of: hapticStrength) { KeyboardPreferences.setHapticStrength($0) }
        .onChange(of: keyClicksEnabled) { KeyboardPreferences.setKeyClicksEnabled($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
        }
    }
}

#Preview {
    NavigationStack { OnboardingView() }
}
