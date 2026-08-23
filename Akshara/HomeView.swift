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
    static let thimiraThenuwara = URL(string: "https://thimirathenuwara.com/")!
}

struct HomeView: View {
    @State private var mode = KeyboardPreferences.selectedMode()
    @State private var setupComplete = SetupStatus.isComplete()

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

                Section {
                    NavigationLink {
                        AboutView(mode: $mode)
                    } label: {
                        DashboardLabel(title: "About", icon: "info.circle.fill", color: .systemTeal)
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
        }
    }

    private func refreshHome() {
        KeyboardPreferences.reload()
        mode = KeyboardPreferences.selectedMode()
        setupComplete = SetupStatus.isComplete()
    }
}

private enum AksharaAppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

/// Short-lived banner that stays visible across a navigation push.
@MainActor
private enum AksharaToast {
    private static weak var current: UIView?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String) {
        hideWork?.cancel()
        current?.removeFromSuperview()

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first
        else { return }

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 20
        blur.clipsToBounds = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        blur.contentView.addSubview(label)

        window.addSubview(blur)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -18),
            blur.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            blur.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            blur.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 24),
            blur.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -24)
        ])

        blur.alpha = 0
        blur.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseOut) {
            blur.alpha = 1
            blur.transform = .identity
        }

        current = blur
        let work = DispatchWorkItem {
            UIView.animate(withDuration: 0.22, animations: {
                current?.alpha = 0
                current?.transform = CGAffineTransform(translationX: 0, y: 8)
            }, completion: { _ in
                current?.removeFromSuperview()
                current = nil
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
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

/// Touches the pasteboard so iOS shows Settings → Akshara → Paste from Other
/// Apps, then opens that app settings page. There is no public URL for the
/// Paste submenu itself.
private func openAksharaPasteFromOtherAppsSettings() {
    let board = UIPasteboard.general
    _ = board.changeCount
    _ = board.string
    openSystemSettings()
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

/// Settings-style glyph tile. Glyphs are rasterized so Form rows cannot retint them.
/// On iOS 26 the fill is a live concentric squircle with a gradient and specular edge,
/// matching Settings list icons instead of a baked CALayer tile.
private struct SettingsIcon: View {
    let systemName: String
    let color: UIColor

    var body: some View {
        let fill = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        if #available(iOS 26.0, *) {
            Image(uiImage: Self.glyphImage(systemName: systemName, side: Self.liquidSide, pointSize: 16))
                .renderingMode(.original)
                .frame(width: Self.liquidSide, height: Self.liquidSide)
                .background {
                    Self.liquidShape.fill(Color(uiColor: fill).gradient)
                }
                .overlay {
                    Self.liquidShape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.22), location: 0),
                                .init(color: Color.white.opacity(0.06), location: 0.4),
                                .init(color: .clear, location: 0.7)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
                }
                .overlay {
                    Self.liquidShape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
                }
                .clipShape(Self.liquidShape)
                .accessibilityHidden(true)
        } else {
            Image(uiImage: Self.legacyImage(systemName: systemName, color: fill))
                .renderingMode(.original)
                .frame(width: Self.legacySide, height: Self.legacySide)
                .accessibilityHidden(true)
        }
    }

    @available(iOS 26.0, *)
    private static var liquidShape: ConcentricRectangle {
        // Fixed radius so every row matches; ConcentricRectangle uses iOS 26's squircle.
        ConcentricRectangle(corners: .fixed(8), isUniform: true)
    }

    private static let liquidSide: CGFloat = 30
    private static let legacySide: CGFloat = 29
    private static let legacyCornerRadius: CGFloat = 6.5

    /// White monochrome glyph, optically centered at its natural symbol size.
    private static func glyphImage(systemName: String, side: CGFloat, pointSize: CGFloat) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium, scale: .medium)
            .applying(UIImage.SymbolConfiguration.preferringMonochrome())
        let fallbackName = systemName.hasSuffix(".fill") ? String(systemName.dropLast(5)) : systemName
        let symbol = UIImage(systemName: systemName, withConfiguration: config)
            ?? UIImage(systemName: fallbackName, withConfiguration: config)
        let glyph = symbol?.withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            guard let glyph else { return }
            glyph.draw(at: CGPoint(
                x: (side - glyph.size.width) / 2,
                y: (side - glyph.size.height) / 2
            ))
        }
    }

    private static func legacyImage(systemName: String, color: UIColor) -> UIImage {
        let size = CGSize(width: legacySide, height: legacySide)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            let tile = CALayer()
            tile.frame = rect
            tile.backgroundColor = color.cgColor
            tile.cornerRadius = legacyCornerRadius
            tile.cornerCurve = .continuous
            tile.masksToBounds = true
            tile.render(in: context.cgContext)

            let glyph = glyphImage(systemName: systemName, side: legacySide, pointSize: 16)
            glyph.draw(in: rect)
        }
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
    @State private var showsDeveloperSettings = KeyboardPreferences.developerModeUnlocked()
    @State private var mode = KeyboardPreferences.selectedMode()
    @State private var emojiEnabled = KeyboardPreferences.emojiEnabled()
    @State private var emojiSkinTone = KeyboardPreferences.emojiSkinTone()
    @State private var suggestionsEnabled = KeyboardPreferences.suggestionsEnabled()
    @State private var emojiSuggestionsEnabled = KeyboardPreferences.emojiSuggestionsEnabled()
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
    @State private var predictiveTouchAreas = KeyboardPreferences.predictiveTouchAreas()

    var body: some View {
        Form {
            layoutModeSection
            featuresSection
            typingSection
            layoutMetricsSection
            appearanceSection
            if showsDeveloperSettings {
                developerSection
            }
        }
        .navigationTitle("Keyboard Settings")
        .aksharaFormChrome()
        .onAppear {
            KeyboardPreferences.reload()
            mode = KeyboardPreferences.selectedMode()
            emojiEnabled = KeyboardPreferences.emojiEnabled()
            emojiSkinTone = KeyboardPreferences.emojiSkinTone()
            showsDeveloperSettings = KeyboardPreferences.developerModeUnlocked()
        }
        .onChange(of: mode) { KeyboardPreferences.setSelectedMode($0) }
        .onChange(of: emojiEnabled) { KeyboardPreferences.setEmojiEnabled($0) }
        .onChange(of: emojiSkinTone) { KeyboardPreferences.setEmojiSkinTone($0) }
        .onChange(of: suggestionsEnabled) { KeyboardPreferences.setSuggestionsEnabled($0) }
        .onChange(of: emojiSuggestionsEnabled) { KeyboardPreferences.setEmojiSuggestionsEnabled($0) }
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
            if suggestionsEnabled {
                Toggle(isOn: $emojiSuggestionsEnabled) {
                    SettingLabel(
                        title: "Emoji Suggestions",
                        detail: "Shows matching emoji in the third suggestion",
                        icon: "face.smiling",
                        color: .systemOrange
                    )
                }
            }
            NavigationLink {
                ClipboardHistorySettingsView()
            } label: {
                SettingLabel(
                    title: "Clipboard History",
                    detail: "Shows a clipboard icon on the suggestion bar",
                    icon: "doc.on.clipboard",
                    color: .systemCyan
                )
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
            NavigationLink {
                DeveloperDebugView()
            } label: {
                SettingLabel(
                    title: "Developer",
                    detail: "Touch areas, chrome, and try fields",
                    icon: "ladybug.fill",
                    color: .systemMint
                )
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

private struct AboutView: View {
    @Binding var mode: SinhalaEngine.Mode
    @State private var confirmReset = false
    @State private var developerUnlocked = KeyboardPreferences.developerModeUnlocked()
    @State private var openDeveloper = false
    @State private var buildTapCount = 0
    @State private var lastBuildTap = Date.distantPast

    var body: some View {
        Form {
            Section {
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
                NavigationLink {
                    CreditsView()
                } label: {
                    DashboardLabel(title: "Credits", icon: "heart.fill", color: .systemPink)
                }
                if developerUnlocked && !openDeveloper {
                    NavigationLink {
                        DeveloperDebugView()
                    } label: {
                        DashboardLabel(title: "Developer", icon: "ladybug.fill", color: .systemMint)
                    }
                }
            }

            Section {
                LabeledContent("Version", value: AksharaAppInfo.version)
                LabeledContent("Build", value: AksharaAppInfo.buildNumber)
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: handleBuildTap)
                    }
                LabeledContent("Copyright", value: "© 2026 Lahiru Himesh Madusanka")
                LabeledContent("License", value: "MIT License")
            }

            Section {
                Button("Reset Keyboard Settings", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .aksharaFormChrome()
        .navigationDestination(isPresented: $openDeveloper) {
            DeveloperDebugView()
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

    private func handleBuildTap() {
        let now = Date()
        if now.timeIntervalSince(lastBuildTap) > 1.5 {
            buildTapCount = 0
        }
        lastBuildTap = now
        buildTapCount += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard buildTapCount >= 7 else { return }

        buildTapCount = 0
        KeyboardPreferences.setDeveloperModeUnlocked(true)
        developerUnlocked = true
        AksharaToast.show("welcome to the අක්ෂර 🇱🇰")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        openDeveloper = true
    }
}

private struct CreditsView: View {
    var body: some View {
        List {
            Section("Layout") {
                NoticeView(
                    title: "Thimira Thenuwara",
                    detail: "Phonetic and Smart Phonetic layout fixes.",
                    links: [("Website", AksharaLinks.thimiraThenuwara)]
                )
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
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
                Text("Allow Full Access lets the app and keyboard share local preferences through an App Group, play haptics, and — when Clipboard History is enabled — read the pasteboard while the keyboard is open. Apple still shows the system warning when you enable it. Clipboard items stay on your device and are never sent over the network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Clipboard History") {
                Text("When enabled in Keyboard Settings, Akshara saves copied text while the keyboard is open. iOS may ask you to allow pasting from other apps. You can choose Always Allow under Settings → Akshara → Paste from Other Apps so the keyboard stops asking every time. Turning the feature off clears saved history.")
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

            Section("Contributors") {
                NoticeView(
                    title: "Thimira Thenuwara",
                    detail: "Phonetic and Smart Phonetic layout fixes.",
                    links: [("Website", AksharaLinks.thimiraThenuwara)]
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

private struct DeveloperDebugView: View {
    @State private var showTouchAreas = KeyboardPreferences.showTouchAreas()
    @State private var chromeOverride = KeyboardPreferences.keyboardChromeOverride()
    @State private var glassText = ""
    @State private var classicText = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showTouchAreas) {
                    SettingLabel(
                        title: "Show Touch Areas",
                        detail: "Draw key hit cells over the grid",
                        icon: "square.dashed",
                        color: .systemMint
                    )
                }
            } footer: {
                Text("For debugging hit targets on the keyboard.")
            }

            Section {
                Picker(selection: $chromeOverride) {
                    ForEach(KeyboardPreferences.KeyboardChromeOverride.allCases) { value in
                        Text(value.title).tag(value)
                    }
                } label: {
                    SettingLabel(
                        title: "Keyboard Chrome",
                        detail: chromeOverride.detail,
                        icon: "rectangle.on.rectangle.angled",
                        color: .systemIndigo
                    )
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Chrome")
            } footer: {
                Text("Automatic follows iOS 26 Liquid Glass and keeps the canvas clear so the host tray shows through. Classic paints Akshara’s pre-glass tray. For a true non-glass system tray, run the Classic Host scheme with Keyboard Chrome set to Classic. Dismiss and reopen the keyboard after changing this.")
            }

            Section {
                TextField("Type here…", text: $glassText, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(false)
            } header: {
                Text("Liquid Glass field")
            } footer: {
                Text("SwiftUI field. On iOS 26 this uses the host’s Liquid Glass keyboard tray.")
            }

            Section {
                ClassicTryField(text: $classicText, placeholder: "Type here…")
                    .frame(minHeight: 88)
            } header: {
                Text("Classic field")
            } footer: {
                Text("UIKit field. The field chrome is pre-glass; the keyboard tray still follows the host unless Keyboard Chrome is Classic.")
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .aksharaFormChrome()
        .onAppear {
            KeyboardPreferences.reload()
            showTouchAreas = KeyboardPreferences.showTouchAreas()
            chromeOverride = KeyboardPreferences.keyboardChromeOverride()
        }
        .onChange(of: showTouchAreas) { KeyboardPreferences.setShowTouchAreas($0) }
        .onChange(of: chromeOverride) { value in
            KeyboardPreferences.setKeyboardChromeOverride(value)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

private struct ClassicTryField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .secondarySystemFill
        view.layer.cornerRadius = 8
        view.layer.cornerCurve = .continuous
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.keyboardDismissMode = .interactive
        context.coordinator.placeholderLabel.text = placeholder
        context.coordinator.placeholderLabel.font = view.font
        context.coordinator.placeholderLabel.textColor = .placeholderText
        context.coordinator.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(context.coordinator.placeholderLabel)
        NSLayoutConstraint.activate([
            context.coordinator.placeholderLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            context.coordinator.placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 11)
        ])
        context.coordinator.syncPlaceholder(for: view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        context.coordinator.placeholderLabel.text = placeholder
        context.coordinator.syncPlaceholder(for: uiView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        let placeholderLabel = UILabel()

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            syncPlaceholder(for: textView)
        }

        func syncPlaceholder(for textView: UITextView) {
            placeholderLabel.isHidden = !textView.text.isEmpty
        }
    }
}

private struct ClipboardHistorySettingsView: View {
    @State private var clipboardHistoryEnabled = KeyboardPreferences.clipboardHistoryEnabled()
    @State private var fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
    @State private var confirmClearClipboard = false
    @State private var showPasteAllowSetup = false

    var body: some View {
        Form {
            Section {
                Toggle("Clipboard History", isOn: $clipboardHistoryEnabled)
                    .disabled(!fullAccessConfirmed)
                Button("Clear History", role: .destructive) {
                    confirmClearClipboard = true
                }
                .disabled(!clipboardHistoryEnabled || !fullAccessConfirmed)
            } header: {
                Text("History")
            } footer: {
                if !fullAccessConfirmed {
                    Text("Full Access must be enabled before clipboard history can be used.")
                } else {
                    Text("Shows a clipboard icon on the suggestion bar. While Akshara is open, copied text is saved automatically.")
                }
            }

            if clipboardHistoryEnabled && fullAccessConfirmed {
                Section {
                    Button("Open Paste from Other Apps Settings") {
                        openAksharaPasteFromOtherAppsSettings()
                    }
                    .aksharaGlassButton(prominent: true)
                } header: {
                    Text("Paste from Other Apps")
                } footer: {
                    Text("To stop repeated “Allow Paste?” prompts, open Akshara’s settings, tap Paste from Other Apps, and choose Allow. Ask keeps prompting; Deny blocks automatic saves. Apple provides this control; it also covers the Akshara keyboard.")
                }
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
        .navigationTitle("Clipboard History")
        .aksharaFormChrome()
        .confirmationDialog(
            "Clear Clipboard History?",
            isPresented: $confirmClearClipboard,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                ClipboardHistoryStore.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes saved clipboard items from this device.")
        }
        .alert("Allow Paste from Other Apps", isPresented: $showPasteAllowSetup) {
            Button("Open Settings") {
                openAksharaPasteFromOtherAppsSettings()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("In Akshara settings, choose Paste from Other Apps → Allow. That stops iOS from asking every time Akshara saves a copy.")
        }
        .onAppear(perform: refresh)
        .onChange(of: clipboardHistoryEnabled) { enabled in
            KeyboardPreferences.setClipboardHistoryEnabled(enabled)
            if enabled {
                showPasteAllowSetup = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        KeyboardPreferences.reload()
        fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
        clipboardHistoryEnabled = KeyboardPreferences.clipboardHistoryEnabled()
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
