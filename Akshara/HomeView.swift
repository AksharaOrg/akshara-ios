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
                        : "Add Akshara in Settings, then try it here. Full Access is optional.")
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
    static let confirmationKey = "aksharaSetupConfirmed"

    // iOS exposes a language, not a public identifier for installed keyboards.
    // Let the user confirm Akshara rather than misidentifying Apple's Sinhala.
    static func isComplete() -> Bool {
        UserDefaults.standard.bool(forKey: confirmationKey)
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

/// Setup confirmation is explicit because iOS cannot identify Akshara by language.
private struct SetupView: View {
    @AppStorage(SetupStatus.confirmationKey) private var setupConfirmed = false
    @State private var fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
    @State private var tryText = ""

    var body: some View {
        Form {
            Section {
                Label(setupConfirmed ? "Setup confirmed" : "Set up Akshara",
                      systemImage: setupConfirmed ? "checkmark.seal.fill" : "keyboard")
                Text("Basic typing works without Full Access or an internet connection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("1. Add Akshara") {
                Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara")
                    .font(.footnote)
                Button("Open iOS Settings", action: openSystemSettings)
                    .aksharaGlassButton(prominent: !setupConfirmed)
                Link("Apple Keyboard Guide", destination: AksharaLinks.appleKeyboardGuide)
            }
            Section {
                Text("Tap the field, hold the globe key, and select Akshara. Type a few characters to check it works.")
                    .font(.footnote)
                TextField("Type here to try Akshara…", text: $tryText, axis: .vertical)
                    .lineLimit(3...6)
                Toggle("I selected and tested Akshara", isOn: $setupConfirmed)
            } header: {
                Text("2. Try the Keyboard")
            } footer: {
                Text("iOS does not let this app distinguish Akshara from other Sinhala keyboards. Confirm setup after selecting Akshara yourself.")
            }
            Section {
                Text("Full Access enables shared settings, haptics, and optional Clipboard History. You can keep it off and use basic typing.")
                    .font(.footnote)
                Text("Settings → General → Keyboard → Keyboards → Akshara → Allow Full Access")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Open iOS Settings", action: openSystemSettings)
                    .aksharaGlassButton(prominent: false)
                if fullAccessConfirmed {
                    Text("Full Access was confirmed the last time Akshara opened. Settings shows its current status.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Optional: Full Access")
            } footer: {
                Text("Apple shows a system warning. Akshara processes typing on your device and does not transmit it.")
            }
        }
        .navigationTitle("Set Up")
        .navigationBarTitleDisplayMode(.inline)
        .aksharaFormChrome()
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in refresh() }
    }

    private func refresh() {
        KeyboardPreferences.reload()
        fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
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

/// Names and descriptions are shared by the settings rows and their search index.
private enum KeyboardSetting: String, CaseIterable, Identifiable {
    case layout
    case englishKeyboard
    case smartPhonetic
    case emojiKey
    case emojiSkinTone
    case suggestions
    case autocorrect
    case savedWords
    case emojiSuggestions
    case clipboard
    case haptics
    case clearLearnedWords
    case spaceAcceptsSuggestion
    case characterPreview
    case topRow
    case doubleSpacePeriod
    case longPressPunctuation
    case smartQuotes
    case smartPunctuation
    case englishOneWord
    case deleteRepeat
    case keySpacing
    case oneHanded
    case predictiveTouchAreas
    case theme
    case highContrast
    case hideDottedCircles
    case developer

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case mode, features, typing, layout, appearance, developer
        var id: String { rawValue }
        var title: String? {
            switch self {
            case .mode: return nil
            case .features: return "Keyboard Features"
            case .typing: return "Typing"
            case .layout: return "Layout"
            case .appearance: return "Appearance"
            case .developer: return nil
            }
        }
    }

    var group: Group {
        switch self {
        case .layout, .smartPhonetic: return .mode
        case .englishKeyboard, .emojiKey, .emojiSkinTone, .suggestions, .autocorrect, .savedWords, .emojiSuggestions, .clipboard, .haptics: return .features
        case .clearLearnedWords, .spaceAcceptsSuggestion, .characterPreview, .topRow, .doubleSpacePeriod, .longPressPunctuation, .smartQuotes, .smartPunctuation, .englishOneWord, .deleteRepeat: return .typing
        case .keySpacing, .oneHanded, .predictiveTouchAreas: return .layout
        case .theme, .highContrast, .hideDottedCircles: return .appearance
        case .developer: return .developer
        }
    }

    private var info: (title: String, detail: String, icon: String, color: UIColor, keywords: String) {
        switch self {
        case .layout:
            return ("Layout", "Choose a Sinhala typing layout", "keyboard.fill", .systemBlue, "Sinhala සිංහල Wijesekara SLS Phonetic Smart Phonetic transliteration typing mode")
        case .smartPhonetic:
            return ("Smart Phonetic Spelling", "Grammar-correct typing and spelling options", "character.cursor.ibeam", .systemBlue, "grammar spelling phonetic classic rakaransaya repaya classical archaic")
        case .englishKeyboard:
            return ("English Keyboard", "English (UK) spelling; switch beside the emoji key", "character.bubble.fill", .systemCyan, "English UK British Sinhala සිංහල language switch bilingual Latin")
        case .emojiKey:
            return ("Emoji Key", "Shows the emoji picker", "face.smiling.fill", .systemOrange, "emoji picker smiley")
        case .emojiSkinTone:
            return ("Emoji Skin Tone", "Default tone for compatible emoji", "hand.thumbsup.fill", .systemBrown, "emoji skin tone colour color default hands")
        case .suggestions:
            return ("Suggestions", "Shows word completions", "text.badge.plus", .systemIndigo, "prediction predictions completion dictionary words")
        case .autocorrect:
            return ("Autocorrect", "Corrects likely misspellings when you finish a word", "text.badge.checkmark", .systemTeal, "auto correct correction spelling typo misspelling")
        case .savedWords:
            return ("Saved Autocorrect Words", "Never correct these words; add your own", "bookmark.fill", .systemTeal, "dictionary protected protection exceptions names never correct add remove saved words")
        case .emojiSuggestions:
            return ("Emoji Suggestions", "Shows matching emoji in the third suggestion", "face.smiling", .systemOrange, "emoji predictions suggestions smiley")
        case .clipboard:
            return ("Clipboard History", "Shows a clipboard icon on the suggestion bar", "doc.on.clipboard", .systemCyan, "copy paste pinned clips history Full Access Allow Paste permission clear history")
        case .haptics:
            return ("Haptics", "Sound and haptic feedback", "waveform", .systemRed, "sound sounds click clicks feedback vibration vibrate haptic strength test Full Access")
        case .clearLearnedWords:
            return ("Clear Learned Words", "Deletes words and word pairs learned in Sinhala and English", "trash.fill", .systemRed, "reset forget learning learned dictionary personal words word pairs")
        case .spaceAcceptsSuggestion:
            return ("Space Accepts Suggestion", "Press Space to use the centre suggestion while typing.", "text.badge.plus", .systemIndigo, "space center centre suggestion accept prediction")
        case .characterPreview:
            return ("Character Preview", "Enlarges the pressed key", "textformat.size", .systemBlue, "bubble popup callout character preview enlarged")
        case .topRow:
            return ("Keyboard Top Row", "Above the letter keys", "rectangle.topthird.inset.filled", .systemGreen, "top row number numbers emoji none")
        case .doubleSpacePeriod:
            return ("Double-Space Period", "Inserts a period with two spaces", "textformat", .systemGray, "double space period full stop punctuation")
        case .longPressPunctuation:
            return ("Long-Press Punctuation", "Hold keys for related marks", "ellipsis.circle.fill", .systemPurple, "hold long press punctuation alternates marks")
        case .smartQuotes:
            return ("Smart Quotes", "Curly quotes while typing", "quote.closing", .systemMint, "curly straight quotes quotation apostrophe")
        case .smartPunctuation:
            return ("Smart Punctuation", "Trims spaces around marks; adds a space after . ? !", "textformat.abc", .systemPink, "spacing space punctuation automatic period")
        case .englishOneWord:
            return ("English for One Word", "Swipe up on Space for one Latin word", "character.bubble.fill", .systemCyan, "Smart Phonetic swipe space one English Latin word")
        case .deleteRepeat:
            return ("Delete Repeat", "Speed while holding Delete", "delete.left.fill", .systemRed, "backspace delete repeat speed hold slow standard fast")
        case .keySpacing:
            return ("Key Spacing", "Space between the keys", "arrow.left.and.right", .systemTeal, "spacing compact standard relaxed gaps width")
        case .oneHanded:
            return ("One-Handed", "Move the keyboard to one side", "hand.tap.fill", .systemPurple, "one handed onehanded left right centre center thumb position")
        case .predictiveTouchAreas:
            return ("Predictive Touch Areas", "Grow likely next letters; off keeps A, L, Z, M expansion", "sparkles", .systemOrange, "prediction touch areas hit targets mistouch accuracy")
        case .theme:
            return ("Theme", "System, light, or dark", "circle.lefthalf.filled", .systemGray, "appearance system light dark theme")
        case .highContrast:
            return ("Higher Key Contrast", "Stronger key borders and fills", "circle.lefthalf.striped.horizontal.inverse", .systemBrown, "higher high contrast accessibility borders fills visibility")
        case .hideDottedCircles:
            return ("Hide Dotted Circles", "Use clean Sinhala mark icons on keys and previews", "circle.dotted", .systemBlue, "dotted circles Sinhala සිංහල marks glyphs icons preview")
        case .developer:
            return ("Developer", "Touch areas, chrome, and try fields", "ladybug.fill", .systemMint, "developer debug touch areas chrome try fields Classic Liquid Glass")
        }
    }

    func label(detail: String? = nil) -> SettingLabel {
        SettingLabel(title: info.title, detail: detail ?? info.detail, icon: info.icon, color: info.color)
    }

    static func tokens(in query: String) -> [String] {
        normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func matches(_ tokens: [String]) -> Bool {
        let text = Self.normalized([info.title, info.detail, info.keywords, group.title ?? ""].joined(separator: " "))
        return tokens.allSatisfy { text.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
    }
}

private struct SmartPhoneticSettingsView: View {
    @Binding var configuration: SmartPhoneticConfiguration

    var body: some View {
        Form {
            Section {
                Toggle("Grammar-correct Smart Phonetic", isOn: $configuration.enabled)
                    .accessibilityIdentifier("smartPhoneticV2")
            } footer: {
                Text("Uses Sinhala spelling rules while you type, then chooses a sound-alike dictionary spelling on Space. Turn off to use classic Smart Phonetic. Your selected layout stays the same.")
            }
            if configuration.enabled {
                Section("Spelling options") {
                    Toggle("Write kruura as ක්‍රූර", isOn: $configuration.options.rakaransayaU)
                        .accessibilityIdentifier("v2RakaransayaU")
                    Toggle("Joined repaya · කර්‍ම", isOn: $configuration.options.repayaZwj)
                        .accessibilityIdentifier("v2RepayaZwj")
                    Toggle("Classical conjuncts · අක්‍ෂර", isOn: $configuration.options.classical)
                        .accessibilityIdentifier("v2Classical")
                    Toggle("Archaic letters", isOn: $configuration.options.archaic)
                        .accessibilityIdentifier("v2Archaic")
                }
            }
            Section {
                Link("How grammar-correct spelling works", destination: URL(string: "https://srilals.github.io/Sinhala-Phonetic-Orthography/")!)
            }
        }
        .navigationTitle("Smart Phonetic")
        .aksharaFormChrome()
    }
}

private struct KeyboardSettingsView: View {
    @State private var searchText = ""
    @State private var confirmClearLearnedWords = false
    @State private var clearingLearnedWords = false
    @State private var clearLearningFailed = false
    @State private var showsDeveloperSettings = KeyboardPreferences.developerModeUnlocked()
    @State private var mode = KeyboardPreferences.selectedMode()
    @State private var emojiEnabled = KeyboardPreferences.emojiEnabled()
    @State private var smartPhonetic = KeyboardPreferences.smartPhoneticConfiguration()
    @State private var emojiSkinTone = KeyboardPreferences.emojiSkinTone()
    @State private var suggestionsEnabled = KeyboardPreferences.suggestionsEnabled()
    @State private var spaceAcceptsSuggestionEnabled = KeyboardPreferences.spaceAcceptsSuggestionEnabled()
    @State private var autocorrectEnabled = KeyboardPreferences.autocorrectEnabled()
    @State private var emojiSuggestionsEnabled = KeyboardPreferences.emojiSuggestionsEnabled()
    @State private var doubleSpacePeriodEnabled = KeyboardPreferences.doubleSpacePeriodEnabled()
    @State private var topRow = KeyboardPreferences.topRow()
    @State private var longPressPunctuationEnabled = KeyboardPreferences.longPressPunctuationEnabled()
    @State private var smartQuotesEnabled = KeyboardPreferences.smartQuotesEnabled()
    @State private var smartPunctuationSpacingEnabled = KeyboardPreferences.smartPunctuationSpacingEnabled()
    @State private var englishKeyboardEnabled = KeyboardPreferences.englishKeyboardEnabled()
    @State private var englishForOneWordEnabled = KeyboardPreferences.englishForOneWordEnabled()
    @State private var characterPreviewEnabled = KeyboardPreferences.characterPreviewEnabled()
    @State private var hideDottedCirclesEnabled = KeyboardPreferences.hideDottedCirclesEnabled()
    @State private var keySpacing = KeyboardPreferences.keySpacing()
    @State private var oneHandedPosition = KeyboardPreferences.oneHandedPosition()
    @State private var appearance = KeyboardPreferences.appearance()
    @State private var highContrastEnabled = KeyboardPreferences.highContrastEnabled()
    @State private var deleteRepeatSpeed = KeyboardPreferences.deleteRepeatSpeed()
    @State private var predictiveTouchAreas = KeyboardPreferences.predictiveTouchAreas()

    var body: some View {
        Form {
            let settings = visibleSettings
            ForEach(KeyboardSetting.Group.allCases) { group in
                let rows = settings.filter { $0.group == group }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { setting in
                            settingRow(setting)
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            if settings.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Settings Found").font(.headline)
                        Text("Try a different name or keyword.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
        .confirmationDialog("Clear Learned Words?", isPresented: $confirmClearLearnedWords, titleVisibility: .visible) {
            Button("Clear Learned Words", role: .destructive) {
                clearingLearnedWords = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let cleared = KeyboardPreferences.clearLearnedWords()
                    DispatchQueue.main.async {
                        clearingLearnedWords = false
                        clearLearningFailed = !cleared
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes words and word pairs learned in Sinhala and English. The bundled dictionaries and your settings stay available.")
        }
        .alert("Could Not Clear Learned Words", isPresented: $clearLearningFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again after closing the keyboard.")
        }
        .navigationTitle("Keyboard Settings")
        .aksharaFormChrome()
        .onAppear {
            KeyboardPreferences.reload()
            mode = KeyboardPreferences.selectedMode()
            emojiEnabled = KeyboardPreferences.emojiEnabled()
            smartPhonetic = KeyboardPreferences.smartPhoneticConfiguration()
            emojiSkinTone = KeyboardPreferences.emojiSkinTone()
            suggestionsEnabled = KeyboardPreferences.suggestionsEnabled()
            spaceAcceptsSuggestionEnabled = KeyboardPreferences.spaceAcceptsSuggestionEnabled()
            autocorrectEnabled = KeyboardPreferences.autocorrectEnabled()
            englishKeyboardEnabled = KeyboardPreferences.englishKeyboardEnabled()
            hideDottedCirclesEnabled = KeyboardPreferences.hideDottedCirclesEnabled()
            showsDeveloperSettings = KeyboardPreferences.developerModeUnlocked()
        }
        .onChange(of: mode) { KeyboardPreferences.setSelectedMode($0) }
        .onChange(of: emojiEnabled) { KeyboardPreferences.setEmojiEnabled($0) }
        .onChange(of: smartPhonetic) { KeyboardPreferences.setSmartPhoneticConfiguration($0) }
        .onChange(of: emojiSkinTone) { KeyboardPreferences.setEmojiSkinTone($0) }
        .onChange(of: suggestionsEnabled) { KeyboardPreferences.setSuggestionsEnabled($0) }
        .onChange(of: spaceAcceptsSuggestionEnabled) { KeyboardPreferences.setSpaceAcceptsSuggestionEnabled($0) }
        .onChange(of: autocorrectEnabled) { KeyboardPreferences.setAutocorrectEnabled($0) }
        .onChange(of: emojiSuggestionsEnabled) { KeyboardPreferences.setEmojiSuggestionsEnabled($0) }
        .onChange(of: doubleSpacePeriodEnabled) { KeyboardPreferences.setDoubleSpacePeriodEnabled($0) }
        .onChange(of: topRow) { KeyboardPreferences.setTopRow($0) }
        .onChange(of: longPressPunctuationEnabled) { KeyboardPreferences.setLongPressPunctuationEnabled($0) }
        .onChange(of: smartQuotesEnabled) { KeyboardPreferences.setSmartQuotesEnabled($0) }
        .onChange(of: smartPunctuationSpacingEnabled) { KeyboardPreferences.setSmartPunctuationSpacingEnabled($0) }
        .onChange(of: englishKeyboardEnabled) { KeyboardPreferences.setEnglishKeyboardEnabled($0) }
        .onChange(of: englishForOneWordEnabled) { KeyboardPreferences.setEnglishForOneWordEnabled($0) }
        .onChange(of: characterPreviewEnabled) { KeyboardPreferences.setCharacterPreviewEnabled($0) }
        .onChange(of: hideDottedCirclesEnabled) { KeyboardPreferences.setHideDottedCirclesEnabled($0) }
        .onChange(of: keySpacing) { KeyboardPreferences.setKeySpacing($0) }
        .onChange(of: oneHandedPosition) { KeyboardPreferences.setOneHandedPosition($0) }
        .onChange(of: appearance) { KeyboardPreferences.setAppearance($0) }
        .onChange(of: highContrastEnabled) { KeyboardPreferences.setHighContrastEnabled($0) }
        .onChange(of: deleteRepeatSpeed) { KeyboardPreferences.setDeleteRepeatSpeed($0) }
        .onChange(of: predictiveTouchAreas) { KeyboardPreferences.setPredictiveTouchAreas($0) }
    }

    private var visibleSettings: [KeyboardSetting] {
        let tokens = KeyboardSetting.tokens(in: searchText)
        let available = KeyboardSetting.allCases.filter { $0 != .developer || showsDeveloperSettings }
        if tokens.isEmpty {
            return available.filter { setting in
                switch setting {
                case .smartPhonetic: return mode == .smartPhonetic
                case .emojiSkinTone: return emojiEnabled
                case .emojiSuggestions: return suggestionsEnabled
                case .englishOneWord: return mode == .smartPhonetic
                default: return true
                }
            }
        }
        var matches = Set(available.filter { $0.matches(tokens) })
        // Keep hidden options discoverable, with the prerequisite alongside.
        if matches.contains(.emojiSkinTone), !emojiEnabled { matches.insert(.emojiKey) }
        if matches.contains(.emojiSuggestions), !suggestionsEnabled { matches.insert(.suggestions) }
        if matches.contains(.englishOneWord), mode != .smartPhonetic { matches.insert(.layout) }
        if matches.contains(.smartPhonetic), mode != .smartPhonetic { matches.insert(.layout) }
        return available.filter { matches.contains($0) }
    }

    @ViewBuilder
    private func settingRow(_ setting: KeyboardSetting) -> some View {
        switch setting.group {
        case .mode: modeSettingRow(setting)
        case .features: featuresSettingRow(setting)
        case .typing: typingSettingRow(setting)
        case .layout: layoutSettingRow(setting)
        case .appearance: appearanceSettingRow(setting)
        case .developer: developerSettingRow(setting)
        }
    }

    @ViewBuilder
    private func modeSettingRow(_ setting: KeyboardSetting) -> some View {
        switch setting {
        case .smartPhonetic:
            NavigationLink {
                SmartPhoneticSettingsView(configuration: $smartPhonetic)
            } label: {
                setting.label(detail: smartPhonetic.enabled ? "Grammar-correct" : "Classic")
            }
        case .layout:
            Picker(selection: $mode) {
                ForEach(SinhalaEngine.Mode.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            } label: {
                setting.label(detail: mode.detail)
            }
            .pickerStyle(.navigationLink)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func featuresSettingRow(_ setting: KeyboardSetting) -> some View {
        switch setting {
        case .englishKeyboard:
            Toggle(isOn: $englishKeyboardEnabled) {
                setting.label()
            }
        case .emojiKey:
            Toggle(isOn: $emojiEnabled) {
                setting.label()
            }
        case .emojiSkinTone:
            Picker(selection: $emojiSkinTone) {
                ForEach(KeyboardPreferences.EmojiSkinTone.allCases) { tone in
                    Text("\(tone.preview)  \(tone.title)").tag(tone)
                }
            } label: {
                setting.label(detail: emojiEnabled ? nil : "Enable Emoji Key to choose a skin tone")
            }
            .pickerStyle(.navigationLink)
            .disabled(!emojiEnabled)
        case .suggestions:
            Toggle(isOn: $suggestionsEnabled) {
                setting.label()
            }
        case .autocorrect:
            Toggle(isOn: $autocorrectEnabled) {
                setting.label()
            }
        case .savedWords:
            NavigationLink {
                SavedAutocorrectWordsView()
            } label: {
                setting.label()
            }
        case .emojiSuggestions:
            Toggle(isOn: $emojiSuggestionsEnabled) {
                setting.label(detail: suggestionsEnabled ? nil : "Enable Suggestions to show matching emoji")
            }
            .disabled(!suggestionsEnabled)
        case .clipboard:
            NavigationLink {
                ClipboardHistorySettingsView()
            } label: {
                setting.label()
            }
        case .haptics:
            NavigationLink {
                HapticsSettingsView()
            } label: {
                setting.label()
            }
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func typingSettingRow(_ setting: KeyboardSetting) -> some View {
        switch setting {
        case .clearLearnedWords:
            Button(clearingLearnedWords ? "Clearing Learned Words…" : "Clear Learned Words", role: .destructive) { confirmClearLearnedWords = true }
                .disabled(clearingLearnedWords)
        case .spaceAcceptsSuggestion:
            Toggle(isOn: $spaceAcceptsSuggestionEnabled) {
                setting.label()
            }
        case .characterPreview:
            Toggle(isOn: $characterPreviewEnabled) {
                setting.label()
            }
        case .topRow:
            Picker(selection: $topRow) {
                ForEach(KeyboardPreferences.TopRow.allCases) { row in
                    Text(row.title).tag(row)
                }
            } label: {
                setting.label()
            }
            .pickerStyle(.navigationLink)
            .accessibilityHint("Choose whether the row above the letters shows emoji, numbers, or nothing.")
        case .doubleSpacePeriod:
            Toggle(isOn: $doubleSpacePeriodEnabled) {
                setting.label()
            }
        case .longPressPunctuation:
            Toggle(isOn: $longPressPunctuationEnabled) {
                setting.label()
            }
        case .smartQuotes:
            Toggle(isOn: $smartQuotesEnabled) {
                setting.label()
            }
        case .smartPunctuation:
            Toggle(isOn: $smartPunctuationSpacingEnabled) {
                setting.label()
            }
        case .englishOneWord:
            Toggle(isOn: $englishForOneWordEnabled) {
                setting.label(detail: mode == .smartPhonetic ? nil : "Choose Smart Phonetic in Layout to use this gesture")
            }
            .disabled(mode != .smartPhonetic)
        case .deleteRepeat:
            Picker(selection: $deleteRepeatSpeed) {
                ForEach(KeyboardPreferences.DeleteRepeatSpeed.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                setting.label()
            }
            .pickerStyle(.navigationLink)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func layoutSettingRow(_ setting: KeyboardSetting) -> some View {
        switch setting {
        case .keySpacing:
            Picker(selection: $keySpacing) {
                ForEach(KeyboardPreferences.KeySpacing.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                setting.label(detail: keySpacing.detail)
            }
            .pickerStyle(.navigationLink)
        case .oneHanded:
            Picker(selection: $oneHandedPosition) {
                ForEach(KeyboardPreferences.OneHandedPosition.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                setting.label(detail: oneHandedPosition.detail)
            }
            .pickerStyle(.navigationLink)
        case .predictiveTouchAreas:
            Toggle(isOn: $predictiveTouchAreas) {
                setting.label()
            }
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func appearanceSettingRow(_ setting: KeyboardSetting) -> some View {
        switch setting {
        case .theme:
            Picker(selection: $appearance) {
                ForEach(KeyboardPreferences.Appearance.allCases) { value in
                    Text(value.title).tag(value)
                }
            } label: {
                setting.label()
            }
            .pickerStyle(.navigationLink)
        case .highContrast:
            Toggle(isOn: $highContrastEnabled) {
                setting.label()
            }
        case .hideDottedCircles:
            Toggle(isOn: $hideDottedCirclesEnabled) {
                setting.label()
            }
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func developerSettingRow(_ setting: KeyboardSetting) -> some View {
        switch setting {
        case .developer:
            NavigationLink {
                DeveloperDebugView()
            } label: {
                setting.label()
            }
        default: EmptyView()
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
            if KeyboardPreferences.hotPath.smartPhonetic.enabled {
                return [("d / D / dh / Dh", "ද / ඩ / ධ / ඪ"),
                        ("ai / au", "අයි / අවු"), ("E / Au", "ඓ / ඖ"),
                        ("lankaava", "ලංකාව"), ("mrudu / kruura", "මෘදු / කෲර"),
                        ("kramaya / vidyaava", "ක්‍රමය / විද්‍යාව"),
                        ("honda + Space", "හොඳ"), ("kazda + Space", "කඳ")]
            }
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
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    DashboardLabel(title: "Diagnostics", icon: "waveform.path.ecg", color: .systemRed)
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
                Text("When enabled in Keyboard Settings, Akshara saves copied text while the keyboard is open. iOS may ask you to allow pasting from other apps. You can choose Always Allow under Settings → Akshara → Paste from Other Apps so the keyboard stops asking every time. Recent history retains up to 10 clips; newer clips replace older ones. Pin important clips from the keyboard; they stay until you delete them manually. You can delete individual clips or clear history in Keyboard Settings. Turning Clipboard History off stops capture but does not erase saved clips.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Predictions") {
                Text("Word suggestions use bundled models and words and word pairs learned from your typing and suggestion selections. Learned data stays on your device until you clear it in Keyboard Settings → Clear Learned Words. Clearing also invalidates cached predictions and pending saves. Typing can learn new words afterwards. Reset Keyboard Settings does not clear learned words.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Text("Apple may provide Akshara with on-device crash, hang, and performance reports. Akshara stores them locally and sends nothing automatically. Reports contain system, device, app-version, and call-stack information—not typed text—and leave your device only when you choose Export Diagnostics.")
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

private struct DiagnosticsView: View {
    @State private var reportCount = 0
    @State private var exportFile: URL?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Stored reports", value: "\(reportCount)")
                Button("Prepare Export") {
                    exportFile = CrashReportManager.shared.makeExportFile()
                    reportCount = CrashReportManager.shared.storedReportCount
                }
                .disabled(reportCount == 0)

                if let exportFile {
                    ShareLink(item: exportFile) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("Crash & Performance Reports")
            } footer: {
                Text("Reports are generated by iOS and may arrive after a delay. They include crashes, hangs, CPU and disk exceptions, and daily performance metrics. Typed text is never included.")
            }

            Section {
                Button("Delete Stored Reports", role: .destructive) {
                    confirmDelete = true
                }
                .disabled(reportCount == 0)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .aksharaFormChrome()
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Delete Diagnostics?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                CrashReportManager.shared.deleteStoredReports()
                exportFile = nil
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all locally stored crash and performance reports.")
        }
    }

    private func refresh() {
        reportCount = CrashReportManager.shared.storedReportCount
        if reportCount == 0 { exportFile = nil }
    }
}

private struct OpenSourceNoticesView: View {
    private static let orthographyLicense: String = {
        guard let url = Bundle.main.url(forResource: "SinhalaOrthography-LICENSE", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
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
                    title: "Sinhala Phonetic Orthography",
                    detail: "Smart Phonetic v2 and its sound lexicon are Swift ports of this research and Akshara Android's implementation.\n\n" + Self.orthographyLicense,
                    links: [("Source", URL(string: "https://github.com/SrilalS/Sinhala-Phonetic-Orthography")!),
                            ("Research", URL(string: "https://srilals.github.io/Sinhala-Phonetic-Orthography/")!)]
                )
                NoticeView(
                    title: "A Word Frequency List for Sinhala",
                    detail: "SinhalaFrequencyModel.tsv is a compact derivative of the University of Moratuwa National Languages Processing Centre word-frequency list. It retains the first 40,000 high-frequency entries, filters malformed or overlong tokens, and is sorted for on-device prefix lookup.\n\nCitation: Aloka Fernando and Gihan Dias (2021), “Building a Linguistic Resource: A Word Frequency List for Sinhala,” ICON 2021, pages 606–610.",
                    links: [("Source", AksharaLinks.sinhalaFrequencyList)]
                )

                NoticeView(
                    title: "Akshara Sinhala Dictionary",
                    detail: "Autocorrect uses the 8,000 highest-ranked verified Sinhala spellings from Akshara Dictionary's redistributable export, pinned to revision 83ba4423ca20784857563cf76ff4648411e3db76 for this release. The keyboard bundles only its compact local spelling index; it never downloads dictionary data or sends typed text over the network.",
                    links: [("Source", URL(string: "https://github.com/AksharaOrg/akshara-dictionary")!)]
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
            Section("English Language Data") {
                Text("English completions and corrections use the 25,000-word aparrish/wordfreq-en-25000 export, derived from rspeer/wordfreq (CC BY-SA 4.0). Next-word counts use synth-inc/predictive-bigrams, derived from the Leipzig Corpora Collection (CC BY). Conversational continuations are shared with Akshara for Android.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Word-frequency data and attribution", destination: URL(string: "https://github.com/aparrish/wordfreq-en-25000")!)
                Link("wordfreq source attributions", destination: URL(string: "https://github.com/rspeer/wordfreq")!)
                Link("Next-word data", destination: URL(string: "https://github.com/synth-inc/predictive-bigrams")!)
                Link("Leipzig Corpora Collection", destination: URL(string: "https://wortschatz.uni-leipzig.de/")!)
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

private struct SavedAutocorrectWordsView: View {
    @State private var newWord = ""
    @State private var savedWords = KeyboardPreferences.autocorrectProtectedWords()

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Sinhala word", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(normalizedNewWord.isEmpty)
                }
            } footer: {
                Text("Saved words are never changed automatically. You can add a word here, or the keyboard will save it after you reverse the same autocorrection three times.")
            }

            Section("Saved Words") {
                if savedWords.isEmpty {
                    Text("No saved words yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(savedWords, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete(perform: removeWords)
                }
            }
        }
        .navigationTitle("Saved Autocorrect Words")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadWords)
    }

    private var normalizedNewWord: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private func addWord() {
        let word = normalizedNewWord
        guard !word.isEmpty else { return }
        KeyboardPreferences.protectFromAutocorrect(word)
        newWord = ""
        reloadWords()
    }

    private func removeWords(at offsets: IndexSet) {
        for index in offsets where savedWords.indices.contains(index) {
            KeyboardPreferences.removeAutocorrectProtection(savedWords[index])
        }
        reloadWords()
    }

    private func reloadWords() {
        savedWords = KeyboardPreferences.autocorrectProtectedWords()
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
                    Text("Shows a clipboard icon on the suggestion bar. While Akshara is open, copied text is saved automatically. Pin important clips from the keyboard to keep them.")
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
                ClipboardHistoryStore.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes recent clips. Pinned clips are kept until you delete them from the keyboard.")
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
