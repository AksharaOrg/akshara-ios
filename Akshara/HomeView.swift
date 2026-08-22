import SwiftUI
import UIKit

private enum AksharaLinks {
    static let github = URL(string: "https://github.com/AksharaOrg/akshara-ios")!
    static let website = URL(string: "https://akshara.org.lk")!
    static let appleKeyboardGuide = URL(string: "https://support.apple.com/guide/iphone/add-or-change-keyboards-iph73b71eb/ios")!
    static let sinhalaFrequencyList = URL(string: "https://github.com/nlpcuom/Word-Frequency-List-for-Sinhala")!
    static let cleanSinhalaTextCorpus = URL(string: "https://huggingface.co/datasets/Remeinium/CleanSinhalaTextCorpus")!
    static let cleanSinhalaTextCorpusDOI = URL(string: "https://doi.org/10.57967/hf/6460")!
    static let creativeCommonsAttribution = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
}

struct HomeView: View {
    @State private var mode = KeyboardPreferences.selectedMode()
    @State private var setupComplete = SetupStatus.isComplete()
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $mode) {
                        ForEach(SinhalaEngine.Mode.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    } label: {
                        DashboardLabel(title: "Layout", icon: "keyboard.fill", color: .systemBlue)
                    }
                    .pickerStyle(.navigationLink)
                    NavigationLink {
                        KeyboardSettingsView()
                    } label: {
                        DashboardLabel(title: "Keyboard Settings", icon: "slider.horizontal.3", color: .systemGray)
                    }
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text(mode.detail)
                }

                Section {
                    NavigationLink {
                        SetupView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "checkmark.seal.fill", color: .systemGreen)
                            Text("Set Up")
                            Spacer(minLength: 8)
                            SetupStatusBadge(isComplete: setupComplete)
                        }
                    }
                } footer: {
                    Text(setupComplete
                        ? "Akshara is ready to use."
                        : "Add the keyboard and allow Full Access to finish setup.")
                }

                Section("Reference") {
                    NavigationLink {
                        LayoutReferenceView()
                    } label: {
                        DashboardLabel(title: "Layout Quick Reference", icon: "keyboard.badge.ellipsis.fill", color: .systemPurple)
                    }
                }

                Section("Links") {
                    Link(destination: AksharaLinks.website) {
                        DashboardLabel(title: "Website", icon: "globe", color: .systemBlue)
                    }
                    Link(destination: AksharaLinks.github) {
                        DashboardLabel(title: "GitHub", icon: "chevron.left.forwardslash.chevron.right", color: .systemIndigo)
                    }
                }

                Section("About") {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        DashboardLabel(title: "Privacy Policy", icon: "hand.raised.fill", color: .systemTeal)
                    }
                    NavigationLink {
                        OpenSourceNoticesView()
                    } label: {
                        DashboardLabel(title: "Open Source Notices", icon: "doc.text.fill", color: .systemOrange)
                    }
                    LabeledContent("Version", value: Self.appVersion)
                    LabeledContent("Copyright", value: "© 2026 Lahiru Himesh Madusanka")
                    LabeledContent("License", value: "MIT License")
                    Button("Reset Keyboard Settings", role: .destructive) {
                        confirmReset = true
                    }
                }
            }
            .navigationTitle("Akshara")
            .aksharaFormChrome()
            .onAppear(perform: refreshHome)
            .onChange(of: mode) { KeyboardPreferences.setSelectedMode($0) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                refreshHome()
            }
            .confirmationDialog(
                "Reset Keyboard Settings?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    KeyboardPreferences.resetToDefaults()
                    mode = KeyboardPreferences.selectedMode()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This restores layout and feature options to their defaults. Full Access status is unchanged.")
            }
        }
    }

    private func refreshHome() {
        KeyboardPreferences.reload()
        mode = KeyboardPreferences.selectedMode()
        setupComplete = SetupStatus.isComplete()
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

private enum SetupStatus {
    static func isSinhalaKeyboardEnabled() -> Bool {
        UITextInputMode.activeInputModes.contains { $0.primaryLanguage == "si-LK" }
    }

    static func isComplete() -> Bool {
        isSinhalaKeyboardEnabled() && KeyboardPreferences.fullAccessConfirmed()
    }
}

private struct SetupStatusBadge: View {
    let isComplete: Bool

    var body: some View {
        Image(systemName: isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .symbolRenderingMode(.hierarchical)
            .font(.title3)
            .foregroundStyle(isComplete ? Color.green : Color.yellow)
            .accessibilityLabel(isComplete ? "Setup complete" : "Setup incomplete")
    }
}

private func openSystemSettings() {
    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(settingsURL)
}

/// Liquid Glass button chrome on iOS 26; plain system buttons earlier.
private extension View {
    @ViewBuilder
    func aksharaGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).controlSize(.large)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func aksharaFormChrome() -> some View {
        if #available(iOS 26.0, *) {
            self.listSectionSpacing(.default)
        } else {
            self
        }
    }
}

/// Guided enable flow. Full Access can only be confirmed after the keyboard
/// extension runs once, so step 3 includes the try field.
private struct SetupView: View {
    @State private var keyboardEnabled = SetupStatus.isSinhalaKeyboardEnabled()
    @State private var fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
    @State private var tryText = ""

    private var setupComplete: Bool {
        keyboardEnabled && fullAccessConfirmed
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    SettingsIcon(
                        systemName: setupComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        color: setupComplete ? .systemGreen : .systemYellow
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(setupComplete ? "Setup complete" : "Setup incomplete")
                            .font(.body.weight(.semibold))
                        Text(setupComplete
                            ? "Akshara is ready to use."
                            : "Finish the steps below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    SetupStatusBadge(isComplete: setupComplete)
                }
            } footer: {
                Text("Full Access is confirmed only after you open the Akshara keyboard once.")
            }

            Section {
                stepRow(
                    number: 1,
                    title: "Add Akshara Keyboard",
                    done: keyboardEnabled
                )
                Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open iOS Settings") {
                    openSystemSettings()
                }
                .aksharaGlassButton(prominent: !keyboardEnabled)
                Link("Apple Keyboard Guide", destination: AksharaLinks.appleKeyboardGuide)
            } header: {
                Text("Step 1")
            } footer: {
                Text(keyboardEnabled
                    ? "A Sinhala keyboard is enabled. This can also read On if Apple’s Sinhala keyboard is on."
                    : "Return here after adding Akshara. Status updates when you come back to the app.")
            }

            Section {
                stepRow(
                    number: 2,
                    title: "Allow Full Access",
                    done: fullAccessConfirmed
                )
                Text("Settings → General → Keyboard → Keyboards → Akshara → Allow Full Access")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open iOS Settings") {
                    openSystemSettings()
                }
                .aksharaGlassButton(prominent: keyboardEnabled && !fullAccessConfirmed)
                .disabled(!keyboardEnabled)
            } header: {
                Text("Step 2")
            } footer: {
                Text(fullAccessConfirmed
                    ? "Full Access is confirmed."
                    : "Required for shared settings and haptics. Apple shows a system warning when you enable it.")
            }

            Section {
                stepRow(
                    number: 3,
                    title: "Open Akshara Once",
                    done: fullAccessConfirmed
                )
                Text("Tap the field below, then use the globe key to select Akshara. Opening it once lets the app confirm Full Access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Type here to try Akshara…", text: $tryText, axis: .vertical)
                    .lineLimit(3...6)
                    .disabled(!keyboardEnabled)
            } header: {
                Text("Step 3")
            } footer: {
                Text(fullAccessConfirmed
                    ? "Akshara has run with Full Access. You can keep typing here to try the keyboard."
                    : "After enabling Full Access, switch to Akshara in this field, then return to this screen.")
            }
        }
        .navigationTitle("Set Up")
        .navigationBarTitleDisplayMode(.inline)
        .aksharaFormChrome()
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        KeyboardPreferences.reload()
        keyboardEnabled = SetupStatus.isSinhalaKeyboardEnabled()
        fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
    }

    private func stepRow(number: Int, title: String, done: Bool) -> some View {
        HStack {
            Text("\(number). \(title)")
            Spacer()
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "\(title) complete" : "\(title) incomplete")
        }
    }
}

private struct DashboardLabel: View {
    let title: String
    let icon: String
    let color: UIColor

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon, color: color)
            Text(title)
        }
    }
}

/// Settings-style glyph tile. On iOS 26 the corner is softer to match Liquid Glass list icons.
private struct SettingsIcon: View {
    let systemName: String
    let color: UIColor

    var body: some View {
        Image(uiImage: Self.image(systemName: systemName, color: color))
            .renderingMode(.original)
            .frame(width: Self.side, height: Self.side)
            .accessibilityHidden(true)
    }

    private static var side: CGFloat {
        if #available(iOS 26.0, *) { return 30 }
        return 29
    }

    private static var cornerRadius: CGFloat {
        if #available(iOS 26.0, *) { return 8 }
        return 6.5
    }

    private static var glyphInset: CGFloat {
        if #available(iOS 26.0, *) { return 6.5 }
        return 6
    }

    private static var glyphPointSize: CGFloat {
        if #available(iOS 26.0, *) { return 15 }
        return 16
    }

    private static func image(systemName: String, color: UIColor) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let fill = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            let tile = CALayer()
            tile.frame = rect
            tile.backgroundColor = fill.cgColor
            tile.cornerRadius = cornerRadius
            tile.cornerCurve = .continuous
            tile.masksToBounds = true
            tile.render(in: context.cgContext)

            let config = UIImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .medium, scale: .medium)
                .applying(UIImage.SymbolConfiguration.preferringMonochrome())
            let fallbackName = systemName.hasSuffix(".fill") ? String(systemName.dropLast(5)) : systemName
            let symbol = UIImage(systemName: systemName, withConfiguration: config)
                ?? UIImage(systemName: fallbackName, withConfiguration: config)
            guard let glyph = symbol?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            glyph.draw(in: fittedRect(for: glyph.size, in: rect.insetBy(dx: glyphInset, dy: glyphInset)))
        }
    }

    private static func fittedRect(for glyphSize: CGSize, in bounds: CGRect) -> CGRect {
        guard glyphSize.width > 0, glyphSize.height > 0 else { return bounds }
        let scale = min(bounds.width / glyphSize.width, bounds.height / glyphSize.height)
        let size = CGSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct SettingLabel: View {
    let title: String
    let detail: String
    let icon: String
    let color: UIColor

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct KeyboardSettingsView: View {
    @State private var mode = KeyboardPreferences.selectedMode()
    @State private var emojiEnabled = KeyboardPreferences.emojiEnabled()
    @State private var emojiSkinTone = KeyboardPreferences.emojiSkinTone()
    @State private var suggestionsEnabled = KeyboardPreferences.suggestionsEnabled()
    @State private var doubleSpacePeriodEnabled = KeyboardPreferences.doubleSpacePeriodEnabled()
    @State private var topRow = KeyboardPreferences.topRow()
    @State private var longPressPunctuationEnabled = KeyboardPreferences.longPressPunctuationEnabled()
    @State private var smartQuotesEnabled = KeyboardPreferences.smartQuotesEnabled()
    @State private var smartPunctuationSpacingEnabled = KeyboardPreferences.smartPunctuationSpacingEnabled()
    @State private var englishForOneWordEnabled = KeyboardPreferences.englishForOneWordEnabled()
    @State private var characterPreviewEnabled = KeyboardPreferences.characterPreviewEnabled()
    @State private var keySpacing = KeyboardPreferences.keySpacing()
    @State private var oneHandedPosition = KeyboardPreferences.oneHandedPosition()
    @State private var appearance = KeyboardPreferences.appearance()
    @State private var highContrastEnabled = KeyboardPreferences.highContrastEnabled()
    @State private var deleteRepeatSpeed = KeyboardPreferences.deleteRepeatSpeed()
    @State private var showTouchAreas = KeyboardPreferences.showTouchAreas()
    @State private var predictiveTouchAreas = KeyboardPreferences.predictiveTouchAreas()

    var body: some View {
        Form {
            layoutModeSection
            featuresSection
            typingSection
            layoutMetricsSection
            appearanceSection
            developerSection
        }
        .navigationTitle("Keyboard Settings")
        .aksharaFormChrome()
        .onAppear { mode = KeyboardPreferences.selectedMode() }
        .onChange(of: mode) { KeyboardPreferences.setSelectedMode($0) }
        .onChange(of: emojiEnabled) { KeyboardPreferences.setEmojiEnabled($0) }
        .onChange(of: emojiSkinTone) { KeyboardPreferences.setEmojiSkinTone($0) }
        .onChange(of: suggestionsEnabled) { KeyboardPreferences.setSuggestionsEnabled($0) }
        .onChange(of: doubleSpacePeriodEnabled) { KeyboardPreferences.setDoubleSpacePeriodEnabled($0) }
        .onChange(of: topRow) { KeyboardPreferences.setTopRow($0) }
        .onChange(of: longPressPunctuationEnabled) { KeyboardPreferences.setLongPressPunctuationEnabled($0) }
        .onChange(of: smartQuotesEnabled) { KeyboardPreferences.setSmartQuotesEnabled($0) }
        .onChange(of: smartPunctuationSpacingEnabled) { KeyboardPreferences.setSmartPunctuationSpacingEnabled($0) }
        .onChange(of: englishForOneWordEnabled) { KeyboardPreferences.setEnglishForOneWordEnabled($0) }
        .onChange(of: characterPreviewEnabled) { KeyboardPreferences.setCharacterPreviewEnabled($0) }
        .onChange(of: keySpacing) { KeyboardPreferences.setKeySpacing($0) }
        .onChange(of: oneHandedPosition) { KeyboardPreferences.setOneHandedPosition($0) }
        .onChange(of: appearance) { KeyboardPreferences.setAppearance($0) }
        .onChange(of: highContrastEnabled) { KeyboardPreferences.setHighContrastEnabled($0) }
        .onChange(of: deleteRepeatSpeed) { KeyboardPreferences.setDeleteRepeatSpeed($0) }
        .onChange(of: showTouchAreas) { KeyboardPreferences.setShowTouchAreas($0) }
        .onChange(of: predictiveTouchAreas) { KeyboardPreferences.setPredictiveTouchAreas($0) }
    }

    private var layoutModeSection: some View {
        Section {
            Picker(selection: $mode) {
                ForEach(SinhalaEngine.Mode.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            } label: {
                SettingLabel(title: "Layout", detail: mode.detail, icon: "keyboard.fill", color: .systemBlue)
            }
            .pickerStyle(.navigationLink)
        }
    }

    private var featuresSection: some View {
        Section("Keyboard Features") {
            Toggle(isOn: $emojiEnabled) {
                SettingLabel(title: "Emoji Key", detail: "Shows the emoji picker", icon: "face.smiling.fill", color: .systemOrange)
            }
            if emojiEnabled {
                Picker(selection: $emojiSkinTone) {
                    ForEach(KeyboardPreferences.EmojiSkinTone.allCases) { tone in
                        Text("\(tone.preview)  \(tone.title)").tag(tone)
                    }
                } label: {
                    SettingLabel(title: "Emoji Skin Tone", detail: "Default tone for compatible emoji", icon: "hand.thumbsup.fill", color: .systemBrown)
                }
                .pickerStyle(.navigationLink)
            }
            Toggle(isOn: $suggestionsEnabled) {
                SettingLabel(title: "Suggestions", detail: "Shows word completions", icon: "text.badge.plus", color: .systemIndigo)
            }
            NavigationLink {
                HapticsSettingsView()
            } label: {
                SettingLabel(title: "Haptics", detail: "Sound and haptic feedback", icon: "waveform", color: .systemRed)
            }
        }
    }

    private var typingSection: some View {
        Section {
            Toggle(isOn: $characterPreviewEnabled) {
                SettingLabel(title: "Character Preview", detail: "Enlarges the pressed key", icon: "textformat.size", color: .systemBlue)
            }
            Picker(selection: $topRow) {
                ForEach(KeyboardPreferences.TopRow.allCases) { row in
                    Text(row.title).tag(row)
                }
            } label: {
                SettingLabel(title: "Keyboard Top Row", detail: "Above the letter keys", icon: "rectangle.topthird.inset.filled", color: .systemGreen)
            }
            .pickerStyle(.navigationLink)
            .accessibilityHint("Choose whether the row above the letters shows emoji, numbers, or nothing.")
            Toggle(isOn: $doubleSpacePeriodEnabled) {
                SettingLabel(title: "Double-Space Period", detail: "Inserts a period with two spaces", icon: "textformat", color: .systemGray)
            }
            Toggle(isOn: $longPressPunctuationEnabled) {
                SettingLabel(title: "Long-Press Punctuation", detail: "Hold keys for related marks", icon: "ellipsis.circle.fill", color: .systemPurple)
            }
            Toggle(isOn: $smartQuotesEnabled) {
                SettingLabel(title: "Smart Quotes", detail: "Curly quotes while typing", icon: "quote.closing", color: .systemMint)
            }
            Toggle(isOn: $smartPunctuationSpacingEnabled) {
                SettingLabel(
                    title: "Smart Punctuation",
                    detail: "Trims spaces around marks; adds a space after . ? !",
                    icon: "textformat.abc",
                    color: .systemPink
                )
            }
            if mode == .smartPhonetic {
                Toggle(isOn: $englishForOneWordEnabled) {
                    SettingLabel(
                        title: "English for One Word",
                        detail: "Swipe up on Space for one Latin word",
                        icon: "character.bubble.fill",
                        color: .systemCyan
                    )
                }
            }
            Picker(selection: $deleteRepeatSpeed) {
                ForEach(KeyboardPreferences.DeleteRepeatSpeed.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                SettingLabel(title: "Delete Repeat", detail: "Speed while holding Delete", icon: "delete.left.fill", color: .systemRed)
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Typing")
        }
    }

    private var layoutMetricsSection: some View {
        Section {
            Picker(selection: $keySpacing) {
                ForEach(KeyboardPreferences.KeySpacing.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                SettingLabel(title: "Key Spacing", detail: keySpacing.detail, icon: "arrow.left.and.right", color: .systemTeal)
            }
            .pickerStyle(.navigationLink)
            Picker(selection: $oneHandedPosition) {
                ForEach(KeyboardPreferences.OneHandedPosition.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                SettingLabel(title: "One-Handed", detail: oneHandedPosition.detail, icon: "hand.tap.fill", color: .systemPurple)
            }
            .pickerStyle(.navigationLink)
            Toggle(isOn: $predictiveTouchAreas) {
                SettingLabel(
                    title: "Predictive Touch Areas",
                    detail: "Grow likely next letters; off keeps A, L, Z, M expansion",
                    icon: "sparkles",
                    color: .systemOrange
                )
            }
        } header: {
            Text("Layout")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $appearance) {
                ForEach(KeyboardPreferences.Appearance.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                SettingLabel(title: "Theme", detail: "System, light, or dark", icon: "circle.lefthalf.filled", color: .systemGray)
            }
            .pickerStyle(.navigationLink)
            Toggle(isOn: $highContrastEnabled) {
                SettingLabel(title: "Higher Key Contrast", detail: "Stronger key borders and fills", icon: "circle.lefthalf.striped.horizontal.inverse", color: .systemBrown)
            }
        }
    }

    private var developerSection: some View {
        Section {
            Toggle(isOn: $showTouchAreas) {
                SettingLabel(title: "Show Touch Areas", detail: "Draw key hit cells over the grid", icon: "square.dashed", color: .systemMint)
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("For debugging hit targets on the keyboard.")
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
            return [("k / g / q", "ක / ග / ද"), ("t / T / th / thh", "ට / ඨ / ත / ථ"),
                    ("z + g/j/d/q", "ඟ / ඦ / ඬ / ඳ"), ("aa / Aa", "ා / ෑ"),
                    ("ru / ruu", "ෘ / ෲ"), ("M, x, or zn", "ං"),
                    ("s / S", "ස / ෂ"), ("sh / Sh", "ශ / ෂ")]
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Layout", selection: $mode) {
                    ForEach(SinhalaEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("This does not change the live keyboard.")
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

private struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section("On Your Device") {
                Text("Typing stays on your device. Akshara does not send keystrokes, suggestions, or analytics off the device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Full Access") {
                Text("Allow Full Access is only so the app and keyboard can share local preferences through an App Group and play haptics. Apple still shows the system warning when you enable it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Predictions") {
                Text("Word suggestions use compact models bundled with the app. Source corpora are not included and never leave your device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("No Tracking") {
                Text("Akshara has no account, no advertising identifiers, and no third-party analytics or tracking SDKs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Contact") {
                Link("Website", destination: AksharaLinks.website)
                Link("GitHub", destination: AksharaLinks.github)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OpenSourceNoticesView: View {
    var body: some View {
        List {
            Section("Akshara") {
                NoticeView(
                    title: "Akshara",
                    detail: "Copyright © 2026 Lahiru Himesh Madusanka. Licensed under the MIT License.",
                    links: [("Source code", AksharaLinks.github)]
                )
            }

            Section("Language resources") {
                NoticeView(
                    title: "A Word Frequency List for Sinhala",
                    detail: "SinhalaFrequencyModel.tsv is a compact derivative of the University of Moratuwa National Languages Processing Centre word-frequency list. It retains the first 40,000 high-frequency entries, filters malformed or overlong tokens, and is sorted for on-device prefix lookup.\n\nCitation: Aloka Fernando and Gihan Dias (2021), “Building a Linguistic Resource: A Word Frequency List for Sinhala,” ICON 2021, pages 606–610.",
                    links: [("Source", AksharaLinks.sinhalaFrequencyList)]
                )

                NoticeView(
                    title: "CleanSinhalaTextCorpus",
                    detail: "SinhalaNextWordModel.tsv and SinhalaTrigramModel.tsv are compact count-only models derived from the full corpus_part_0.gz (~1.0 GiB decompressed) in CleanSinhalaTextCorpus by Remeinium AI and Kusal Darshana (2025). Conversational lines are up-weighted. The next-word table keeps up to sixteen continuations for 30,000 preceding-word contexts. Empty-context suggestions use a curated spoken-opener list. Source text is not distributed with Akshara.",
                    links: [
                        ("Dataset", AksharaLinks.cleanSinhalaTextCorpus),
                        ("Dataset DOI", AksharaLinks.cleanSinhalaTextCorpusDOI),
                        ("CC BY 4.0", AksharaLinks.creativeCommonsAttribution)
                    ]
                )
            }

            Section("Privacy") {
                Text("The source corpus is not included in the app. Predictions use the compact on-device models bundled with Akshara.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Open Source Notices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NoticeView: View {
    let title: String
    let detail: String
    let links: [(String, URL)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(links, id: \.1) { label, destination in
                Link(label, destination: destination)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct HapticsSettingsView: View {
    @State private var hapticsEnabled = KeyboardPreferences.hapticsEnabled()
    @State private var hapticStrength = KeyboardPreferences.hapticStrength()
    @State private var keyClicksEnabled = KeyboardPreferences.keyClicksEnabled()
    @State private var fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()

    var body: some View {
        Form {
            Section {
                Toggle("Key Haptics", isOn: $hapticsEnabled)
                    .disabled(!fullAccessConfirmed)
                Picker("Strength", selection: $hapticStrength) {
                    ForEach(KeyboardPreferences.HapticStrength.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .disabled(!hapticsEnabled || !fullAccessConfirmed)
                Button {
                    playTestHaptic()
                } label: {
                    Label("Test Haptic", systemImage: "hand.tap")
                }
                .disabled(!hapticsEnabled || !fullAccessConfirmed)
                Toggle("Key Clicks", isOn: $keyClicksEnabled)
            } header: {
                Text("Feedback")
            } footer: {
                Text(fullAccessConfirmed
                    ? "Haptic feedback plays when you touch a key."
                    : "Full Access must be enabled before key haptics can be used.")
            }

            Section {
                Label(
                    fullAccessConfirmed ? "Full Access confirmed" : "Full Access required",
                    systemImage: fullAccessConfirmed ? "checkmark.circle.fill" : "lock.fill"
                )
                .foregroundStyle(fullAccessConfirmed ? .green : .secondary)
                Button("Open iOS Settings") {
                    openSystemSettings()
                }
                .aksharaGlassButton(prominent: !fullAccessConfirmed)
            } header: {
                Text("Keyboard Full Access")
            } footer: {
                Text("Settings → General → Keyboard → Keyboards → Akshara → Allow Full Access. Then open the Akshara keyboard once and return here.")
            }
        }
        .navigationTitle("Haptics")
        .aksharaFormChrome()
        .onAppear(perform: refreshFullAccess)
        .onChange(of: hapticsEnabled) { KeyboardPreferences.setHapticsEnabled($0) }
        .onChange(of: hapticStrength) { KeyboardPreferences.setHapticStrength($0) }
        .onChange(of: keyClicksEnabled) { KeyboardPreferences.setKeyClicksEnabled($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshFullAccess()
        }
    }

    private func refreshFullAccess() {
        KeyboardPreferences.reload()
        fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
    }

    private func playTestHaptic() {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch hapticStrength {
        case .light: style = .light
        case .standard: style = .medium
        case .strong: style = .heavy
        }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: CGFloat(hapticStrength.intensity))
    }
}

#Preview {
    HomeView()
}
