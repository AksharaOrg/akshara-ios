import UIKit

/// Keeps the generators alive for the lifetime of the keyboard. Apple recommends
/// preparing a generator before its event, then preparing it again after firing
/// when another event may follow soon. A keyboard is exactly that interaction.
private final class KeyFeedback {
    private let impact: UIImpactFeedbackGenerator
    private let selection: UISelectionFeedbackGenerator

    init(view: UIView) {
        if #available(iOS 18.0, *) {
            impact = UIImpactFeedbackGenerator(style: .light, view: view)
            selection = UISelectionFeedbackGenerator(view: view)
        } else {
            impact = UIImpactFeedbackGenerator(style: .light)
            selection = UISelectionFeedbackGenerator()
        }
    }

    func prepare() {
        guard KeyboardPreferences.hapticsEnabled() else { return }
        impact.prepare()
        selection.prepare()
    }

    func keyPressed() {
        guard KeyboardPreferences.hapticsEnabled() else { return }
        // Prepare at the moment of contact. A keyboard extension can remain
        // alive while its haptic service is suspended between appearances.
        impact.prepare()
        // Keep the native light waveform, with just a small reduction from
        // its default strength so it remains perceptible without feeling busy.
        impact.impactOccurred(intensity: 0.75)
    }

    func selectionChanged() {
        guard KeyboardPreferences.hapticsEnabled() else { return }
        selection.selectionChanged()
        selection.prepare()
    }
}

/// A small UIKit key control tuned for the system keyboard's dense, tactile feel.
private final class NativeKeyButton: UIButton {
    private let isUtility: Bool
    private var longPressWasHandled = false
    private let hintLabel = UILabel()
    /// Called by the controller to mirror the system keyboard's character
    /// preview without making the key itself jump under the finger.
    var highlightChanged: ((NativeKeyButton, Bool) -> Void)?
    /// Fired at touch-down, which is when keyboard feedback needs to occur.
    var touchDown: (() -> Void)?

    private var usesIOS16KeyboardAppearance: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    private var usesIOS26KeyboardAppearance: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    init(title: String?, hint: String? = nil, symbol: String? = nil, utility: Bool = false) {
        self.isUtility = utility
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel?.font = .systemFont(ofSize: utility ? 18 : 22, weight: utility ? .medium : .regular)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        setTitle(title, for: .normal)
        setTitleColor(.label, for: .normal)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 9, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .right
        hintLabel.text = hint
        hintLabel.isHidden = hint == nil
        hintLabel.isUserInteractionEnabled = false
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        if let symbol {
            setImage(UIImage(systemName: symbol), for: .normal)
            tintColor = .label
            imageView?.preferredSymbolConfiguration = .init(pointSize: 20, weight: utility ? .medium : .regular)
        }
        backgroundColor = UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return utility ? UIColor(white: 0.26, alpha: 1) : UIColor(white: 0.40, alpha: 1)
            }
            if #unavailable(iOS 17.0) {
                return utility
                    ? UIColor(red: 190 / 255, green: 193 / 255, blue: 202 / 255, alpha: 1)
                    : .white
            }
            if !self.usesIOS26KeyboardAppearance {
                // iOS 17–25 retain the established, two-surface keyboard:
                // character keys are white while modifier keys are cooler and
                // darker.  The all-white treatment is specific to iOS 26.
                return utility
                    ? UIColor(red: 0.71, green: 0.73, blue: 0.77, alpha: 1)
                    : .systemBackground
            }
            // On current iOS, alphabetic utility controls (Shift, Delete,
            // 123, Emoji, and Globe) share the white character-key surface.
            // Treating them as the older grey system-key material made the
            // extension visibly diverge from the UK keyboard in iOS 26.
            return .systemBackground
        }
        layer.cornerRadius = utility ? 8 : 7
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        // The system key shadow is a fine grounding line, not a visible grey
        // outline. The previous opacity made every Akshara key look raised.
        // Current iOS keycaps sit almost flush against the keyboard chrome.
        // A 0.13 shadow left a visible dark trench beneath every Akshara key
        // when overlaid with the UK keyboard.
        layer.shadowOpacity = usesIOS26KeyboardAppearance
            ? 0.04
            : (usesIOS16KeyboardAppearance ? 0.18 : 0.23)
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        addTarget(self, action: #selector(pressBegan), for: .touchDown)
    }

    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet {
            // System keys darken on contact; keeping their geometry fixed is
            // important for fast, consecutive taps.
            // UIKit disables interaction on an animating view unless explicitly
            // told otherwise. That makes rapid repeated characters and Delete
            // taps easy to drop while the pressed-state fade is still running.
            UIView.animate(
                withDuration: 0.055,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
            ) {
                self.transform = .identity
                self.alpha = self.isHighlighted ? 0.62 : 1
            }
            highlightChanged?(self, isHighlighted)
        }
    }

    /// The visible gap is six points wide. Claiming half of it on each side
    /// makes the target forgiving, while avoiding the previous vertical
    /// overlap that could route a boundary touch to the neighbouring row.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -3, dy: -3).contains(point)
    }

    @objc private func pressBegan() {
        touchDown?()
    }

    func markLongPressHandled() { longPressWasHandled = true }

    func consumeLongPressHandled() -> Bool {
        defer { longPressWasHandled = false }
        return longPressWasHandled
    }

    /// Full-width iPads use materially larger keycaps than phones. Keep that
    /// tuning on the reusable key rather than letting each row invent fonts
    /// and corner radii independently.
    func applyLayoutMetrics(isPad: Bool) {
        let titleSize: CGFloat = isPad ? (isUtility ? 22 : 28) : (isUtility ? 18 : 22)
        titleLabel?.font = .systemFont(ofSize: titleSize, weight: isUtility ? .medium : .regular)
        // Phonetic Sinhala hints must remain secondary, but 9 pt becomes too
        // faint on modern phone displays. Keep the hierarchy while improving
        // recognition during fast touch typing.
        hintLabel.font = .systemFont(ofSize: isPad ? 12 : 10, weight: .regular)
        layer.cornerRadius = isPad ? (isUtility ? 10 : 8) : (isUtility ? 8 : 7)
        if let imageView {
            imageView.preferredSymbolConfiguration = .init(
                pointSize: isPad ? 23 : 20,
                weight: isUtility ? .medium : .regular
            )
        }
    }

    var isUtilityKey: Bool { isUtility }

    var supportsCharacterPreview: Bool {
        !isUtility && currentTitle != nil && currentTitle != " "
    }

    /// In Space-trackpad mode iOS keeps the key surfaces but removes their
    /// glyphs, making the keyboard read as a single cursor-control surface.
    func setGlyphsHidden(_ hidden: Bool, animated: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        let changes = {
            self.titleLabel?.alpha = alpha
            self.imageView?.alpha = alpha
            self.hintLabel.alpha = alpha
        }
        guard animated else { changes(); return }
        UIView.animate(
            withDuration: hidden ? 0.12 : 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: changes
        )
    }

    func collapseSpaceTitle(animated: Bool = true) {
        guard currentTitle != nil else { return }
        // The input-method name arrives as a centred confirmation, then
        // settles into iOS's quiet lower-right language annotation.
        let changes = {
            self.setTitleColor(.secondaryLabel, for: .normal)
            self.titleLabel?.font = .systemFont(ofSize: 11, weight: .regular)
            self.titleLabel?.alpha = 0.64
            self.titleLabel?.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            self.contentHorizontalAlignment = .right
            self.contentVerticalAlignment = .bottom
            self.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 7, right: 10)
            self.layoutIfNeeded()
        }
        guard animated else { changes(); return }
        UIView.animate(
            withDuration: 0.58,
            delay: 0,
            usingSpringWithDamping: 0.92,
            initialSpringVelocity: 0.18,
            options: [.curveEaseInOut, .beginFromCurrentState]
        , animations: changes)
    }
}

private enum EmojiCategory: CaseIterable {
    case recent, smileys, animals, food, activity, travel, objects, symbols, flags

    var symbolName: String {
        switch self {
        case .recent: return "clock"
        case .smileys: return "face.smiling"
        case .animals: return "pawprint"
        case .food: return "fork.knife"
        case .activity: return "soccerball"
        case .travel: return "car"
        case .objects: return "lightbulb"
        case .symbols: return "music.note"
        case .flags: return "flag"
        }
    }

    var title: String {
        switch self {
        case .recent: return "FREQUENTLY USED"
        case .smileys: return "SMILEYS & PEOPLE"
        case .animals: return "ANIMALS & NATURE"
        case .food: return "FOOD & DRINK"
        case .activity: return "ACTIVITY"
        case .travel: return "TRAVEL & PLACES"
        case .objects: return "OBJECTS"
        case .symbols: return "SYMBOLS"
        case .flags: return "FLAGS"
        }
    }
}

/// Uses the emoji characters supplied by the installed iOS version instead of
/// shipping artwork. New emoji therefore appear automatically after an iOS
/// update, rendered by Apple's own color emoji font.
private enum EmojiCatalog {
    private static let recentKey = "AksharaRecentEmoji"
    private static let excludedScalars: Set<UInt32> = [0x23, 0x2A, 0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299]

    static let allBaseEmoji: [String] = {
        var result: [String] = []
        for value in UInt32(0x20)...UInt32(0x1FAFF) {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji else { continue }
            guard !excludedScalars.contains(value), !(0x30...0x39).contains(value) else { continue }
            guard !(0x1F1E6...0x1F1FF).contains(value), !(0x1F3FB...0x1F3FF).contains(value) else { continue }
            result.append(String(scalar))
        }
        return result
    }()

    static let flags: [String] = Locale.Region.isoRegions.compactMap { region in
        let code = region.identifier.uppercased()
        guard code.count == 2,
              let first = code.unicodeScalars.first, let last = code.unicodeScalars.last,
              let firstFlag = Unicode.Scalar(0x1F1E6 + first.value - 65),
              let lastFlag = Unicode.Scalar(0x1F1E6 + last.value - 65) else { return nil }
        return String(firstFlag) + String(lastFlag)
    }.sorted()

    static func emoji(for category: EmojiCategory) -> [String] {
        if category == .recent { return recent() }
        if category == .flags { return flags }
        return allBaseEmoji.filter { value in
            guard let scalar = value.unicodeScalars.first else { return false }
            let code = scalar.value
            switch category {
            case .smileys: return (0x1F300...0x1F3FF).contains(code) || (0x1F600...0x1F64F).contains(code)
            case .animals: return (0x1F400...0x1F4AF).contains(code)
            case .food: return (0x1F32D...0x1F37F).contains(code) || (0x1F950...0x1F96F).contains(code)
            case .activity: return (0x1F380...0x1F3FF).contains(code) || (0x1F947...0x1F94C).contains(code)
            case .travel: return (0x1F680...0x1F6FF).contains(code) || (0x1F900...0x1F93F).contains(code)
            case .objects: return (0x1F4B0...0x1F5FF).contains(code) || (0x1F9E0...0x1FAFF).contains(code)
            case .symbols: return !emoji(for: .smileys).contains(value)
                && !emoji(for: .animals).contains(value)
                && !emoji(for: .food).contains(value)
                && !emoji(for: .activity).contains(value)
                && !emoji(for: .travel).contains(value)
                && !emoji(for: .objects).contains(value)
            case .recent, .flags: return false
            }
        }
    }

    static func record(_ emoji: String) {
        var values = recent().filter { $0 != emoji }
        values.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(values.prefix(36)), forKey: recentKey)
    }

    static func recent() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? ["😀", "😂", "🥹", "❤️", "👍", "🙏", "🔥", "🎉"]
    }

    /// Official Unicode CLDR annotations provide the names and keywords used
    /// to power character pickers. The compact index is generated at build
    /// time and bundled with the extension, so search remains private and
    /// works without Full Access or a network connection.
    private static let searchIndex: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "EmojiSearchIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return index
    }()

    /// Normalize the bundled CLDR index once. Normalizing thousands of terms
    /// for every typed search character made the Emoji search feel sluggish.
    private static let normalizedSearchIndex: [(emoji: String, terms: Set<String>)] = {
        searchIndex.map { emoji, terms in
            let normalizedTerms = terms.flatMap { term in
                term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .lowercased(with: .current)
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            }
            return (emoji, Set(normalizedTerms))
        }
    }()

    static func search(_ query: String) -> [String] {
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased(with: .current)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map(String.init)
        guard !tokens.isEmpty else { return ["😐", "😀", "😃", "😁", "😄", "😆", "🥹", "😅"] }
        let matches = normalizedSearchIndex.compactMap { entry -> (String, Int)? in
            guard tokens.allSatisfy({ token in
                // Prefix matching makes natural variants work: "prayer"
                // finds CLDR's "pray", while exact terms rank above prefixes.
                entry.terms.contains {
                    $0.hasPrefix(token) || ($0.count >= 3 && token.hasPrefix($0))
                }
            }) else { return nil }
            let score = tokens.reduce(0) { partial, token in
                partial + (entry.terms.contains(token) ? 2 : 1)
            }
            return (entry.emoji, score)
        }
        return matches.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }.prefix(8).map(\.0)
    }
}

private final class EmojiPickerView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UITextFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var onDelete: (() -> Void)?
    private var category: EmojiCategory = .recent { didSet { collectionView.reloadData(); updateCategorySelection() } }
    private var categoryButtons: [EmojiCategory: UIButton] = [:]
    private let categoryBar = UIStackView()
    private let collectionView: UICollectionView
    private let titleLabel = UILabel()
    private let searchField = UISearchTextField()
    private let emojiSuggestionRow = UIStackView()
    private let searchKeyboard = UIStackView()
    private var searchQuery = ""
    private var emojiSuggestionButtons: [UIButton] = []
    private enum SearchLayer { case letters, numbers, symbols }
    private var searchLayer: SearchLayer = .letters
    private var searchShift = false
    private var searchButtons: [UIButton] = []

    /// iOS 16's Emoji search keyboard has a cooler chrome, softer utility
    /// keys, and a deliberately indented, equal-width A–L row. Keep this
    /// compatibility treatment isolated so later iOS releases retain the
    /// current keyboard appearance.
    private var usesIOS16EmojiSearchAppearance: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    private var emojiPickerBackgroundColor: UIColor {
        guard usesIOS16EmojiSearchAppearance else {
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(white: 0.16, alpha: 1)
                : UIColor(red: 226 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1) }
        }
        return UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.16, alpha: 1)
            : UIColor(red: 209 / 255, green: 210 / 255, blue: 216 / 255, alpha: 1) }
    }

    private var searchKeySurfaceColor: UIColor {
        guard usesIOS16EmojiSearchAppearance else { return .systemBackground }
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.40, alpha: 1) : .white }
    }

    private var searchUtilitySurfaceColor: UIColor {
        guard usesIOS16EmojiSearchAppearance else {
            return UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
        }
        return UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.32, alpha: 1)
            : UIColor(red: 190 / 255, green: 193 / 255, blue: 202 / 255, alpha: 1) }
    }

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 3
        layout.scrollDirection = .vertical
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = emojiPickerBackgroundColor
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        searchField.placeholder = "Search Emoji"
        searchField.font = .systemFont(ofSize: 18)
        // This picker deliberately manages its own input instead of invoking
        // iOS's keyboard. Set the color explicitly so programmatic updates
        // remain legible in both appearances.
        searchField.textColor = .label
        searchField.tintColor = .systemBlue
        if usesIOS16EmojiSearchAppearance {
            searchField.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(white: 0.25, alpha: 1)
                : UIColor(red: 197 / 255, green: 199 / 255, blue: 206 / 255, alpha: 1) }
        }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        addSubview(searchField)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        categoryBar.axis = .horizontal
        categoryBar.distribution = .fill
        categoryBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(categoryBar)
        let letters = UIButton(type: .system)
        letters.setTitle("ABC", for: .normal)
        letters.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
        letters.setTitleColor(.label, for: .normal)
        letters.addTarget(self, action: #selector(dismissPicker), for: .touchUpInside)
        categoryBar.addArrangedSubview(letters)
        letters.widthAnchor.constraint(equalToConstant: 51).isActive = true

        // iOS reserves fixed end caps for ABC and Delete, then divides the
        // remaining rail between compact category targets.  Keeping that
        // middle strip flexible preserves the native proportions on each
        // phone width instead of stretching every item identically.
        let categoryStrip = UIStackView()
        categoryStrip.axis = .horizontal
        categoryStrip.distribution = .fillEqually
        categoryBar.addArrangedSubview(categoryStrip)
        for item in EmojiCategory.allCases {
            let slot = UIView()
            categoryStrip.addArrangedSubview(slot)
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setImage(UIImage(systemName: item.symbolName), for: .normal)
            button.tintColor = .secondaryLabel
            button.setPreferredSymbolConfiguration(.init(pointSize: 19, weight: .regular), forImageIn: .normal)
            button.tag = EmojiCategory.allCases.firstIndex(of: item) ?? 0
            button.addTarget(self, action: #selector(selectCategory(_:)), for: .touchUpInside)
            categoryButtons[item] = button
            slot.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 30),
                button.heightAnchor.constraint(equalToConstant: 30)
            ])
        }
        let delete = UIButton(type: .system)
        delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
        delete.tintColor = .label
        delete.setPreferredSymbolConfiguration(.init(pointSize: 21, weight: .regular), forImageIn: .normal)
        delete.addTarget(self, action: #selector(deleteEmojiInput), for: .touchUpInside)
        categoryBar.addArrangedSubview(delete)
        delete.widthAnchor.constraint(equalToConstant: 51).isActive = true

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "emoji")
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        emojiSuggestionRow.axis = .horizontal
        emojiSuggestionRow.distribution = .fillEqually
        emojiSuggestionRow.translatesAutoresizingMaskIntoConstraints = false
        emojiSuggestionRow.isHidden = true
        addSubview(emojiSuggestionRow)
        for emoji in ["😐", "😀", "😃", "😁", "😄", "😆", "🥹", "😅"] {
            let button = UIButton(type: .system)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 27)
            // The title is replaced as the query changes. Read it at tap time
            // rather than capturing the original default-row emoji.
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let emoji = button?.currentTitle, !emoji.isEmpty else { return }
                self?.onSelect?(emoji)
            }, for: .touchUpInside)
            emojiSuggestionRow.addArrangedSubview(button)
            emojiSuggestionButtons.append(button)
        }

        searchKeyboard.axis = .vertical
        searchKeyboard.spacing = 6
        searchKeyboard.distribution = .fillEqually
        searchKeyboard.translatesAutoresizingMaskIntoConstraints = false
        searchKeyboard.isHidden = true
        addSubview(searchKeyboard)
        for (rowIndex, row) in [["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l"], ["⇧","z","x","c","v","b","n","m","⌫"], ["123","emoji","space","Search"]].enumerated() {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.distribution = (rowIndex == 0 || (usesIOS16EmojiSearchAppearance && rowIndex == 1)) ? .fillEqually : .fill
            if rowIndex == 1 {
                stack.layoutMargins = UIEdgeInsets(top: 0, left: 21, bottom: 0, right: 21)
                stack.isLayoutMarginsRelativeArrangement = true
            }
            var letterButtons: [UIButton] = []
            for key in row {
                let button = UIButton(type: .system)
                button.setTitle(["space", "emoji", "Search"].contains(key) ? nil : key, for: .normal)
                button.setTitleColor(key == "Search" ? .white : .label, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 20)
                // `face.smiling` is the native-style, open-mouth emoji key.
                // Never give this button a title as well: UIKit otherwise
                // renders the legacy text glyph beside the SF Symbol.
                if key == "emoji" { button.setImage(UIImage(systemName: "face.smiling"), for: .normal); button.tintColor = .label }
                if key == "Search" { button.setTitle(nil, for: .normal); button.setImage(UIImage(systemName: "checkmark"), for: .normal); button.tintColor = .white }
                button.backgroundColor = key == "Search" ? .systemBlue : (key == "⇧" || key == "⌫" || key == "123" ? searchUtilitySurfaceColor : searchKeySurfaceColor)
                button.layer.cornerRadius = 7
                button.accessibilityIdentifier = key
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let key = button?.accessibilityIdentifier else { return }
                    self?.pressSearchKey(key)
                }, for: .touchUpInside)
                searchButtons.append(button)
                stack.addArrangedSubview(button)
                if rowIndex == 2, key != "⇧", key != "⌫" { letterButtons.append(button) }
                if rowIndex == 2, key == "⇧" || key == "⌫" { button.widthAnchor.constraint(equalToConstant: 42).isActive = true }
                if rowIndex == 3 {
                    switch key {
                    case "123", "emoji": button.widthAnchor.constraint(equalToConstant: 42).isActive = true
                    case "Search": button.widthAnchor.constraint(equalToConstant: 92).isActive = true
                    default: break
                    }
                }
            }
            for button in letterButtons.dropFirst() { button.widthAnchor.constraint(equalTo: letterButtons[0].widthAnchor).isActive = true }
            searchKeyboard.addArrangedSubview(stack)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.heightAnchor.constraint(equalToConstant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            titleLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            categoryBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            categoryBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            categoryBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            categoryBar.heightAnchor.constraint(equalToConstant: 36),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            collectionView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            collectionView.bottomAnchor.constraint(equalTo: categoryBar.topAnchor, constant: -3),
            emojiSuggestionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            emojiSuggestionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            emojiSuggestionRow.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            emojiSuggestionRow.heightAnchor.constraint(equalToConstant: 38),
            // Native search layouts leave a slightly wider outer gutter than
            // the main custom keyboard, keeping letter keys compact.
            searchKeyboard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            searchKeyboard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            searchKeyboard.topAnchor.constraint(equalTo: emojiSuggestionRow.bottomAnchor, constant: 5),
            searchKeyboard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
        updateCategorySelection()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectCategory(_ sender: UIButton) { category = EmojiCategory.allCases[sender.tag] }
    @objc private func dismissPicker() { onDismiss?() }
    @objc private func deleteEmojiInput() { onDelete?() }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        collectionView.isHidden = true
        titleLabel.isHidden = true
        categoryBar.isHidden = true
        emojiSuggestionRow.isHidden = false
        searchKeyboard.isHidden = false
        updateEmojiSearchResults()
        return false
    }

    private func pressSearchKey(_ key: String) {
        switch key {
        case "⌫": if !searchQuery.isEmpty { searchQuery.removeLast() }
        case "space": searchQuery += " "
        case "⇧": searchShift.toggle(); refreshSearchKeys(); return
        case "123": searchLayer = .numbers; refreshSearchKeys(); return
        case "#+=": searchLayer = .symbols; refreshSearchKeys(); return
        case "ABC": searchLayer = .letters; refreshSearchKeys(); return
        case "emoji": endEmojiSearch(); return
        case "Search":
            endEmojiSearch(); return
        default:
            searchQuery += key
            if searchShift { searchShift = false; refreshSearchKeys() }
        }
        searchField.text = searchQuery
        updateEmojiSearchResults()
    }

    private func updateEmojiSearchResults() {
        let matches = EmojiCatalog.search(searchQuery)
        for (index, button) in emojiSuggestionButtons.enumerated() {
            button.setTitle(index < matches.count ? matches[index] : nil, for: .normal)
            button.isEnabled = index < matches.count
        }
    }

    private func endEmojiSearch() {
        searchQuery = ""
        searchField.text = nil
        searchLayer = .letters
        searchShift = false
        collectionView.isHidden = false
        titleLabel.isHidden = false
        categoryBar.isHidden = false
        emojiSuggestionRow.isHidden = true
        searchKeyboard.isHidden = true
    }

    private func refreshSearchKeys() {
        let rows: [[String]]
        switch searchLayer {
        case .letters:
            let letter: (String) -> String = { self.searchShift ? $0.uppercased() : $0 }
            rows = [["q","w","e","r","t","y","u","i","o","p"].map(letter), ["a","s","d","f","g","h","j","k","l"].map(letter), ["⇧","z","x","c","v","b","n","m","⌫"].map { $0.count == 1 ? letter($0) : $0 }, ["123","emoji","space","Search"]]
        case .numbers:
            rows = [["1","2","3","4","5","6","7","8","9","0"], ["-","/",":",";","(",")","$","&","@"], ["#+=",".",",","?","!","'","(",")","⌫"], ["ABC","emoji","space","Search"]]
        case .symbols:
            rows = [["[","]","{","}","#","%","^","*","+","="], ["_","\\","|","~","<",">","€","£","¥"], ["123",".",",","?","!","'","(",")","⌫"], ["ABC","emoji","space","Search"]]
        }
        let keys = rows.flatMap { $0 }
        for (button, key) in zip(searchButtons, keys) {
            button.accessibilityIdentifier = key
            button.setImage(nil, for: .normal)
            button.setTitle(["space", "emoji", "Search"].contains(key) ? nil : key, for: .normal)
            button.setTitleColor(key == "Search" ? .white : .label, for: .normal)
            button.tintColor = key == "Search" ? .white : .label
            if key == "emoji" { button.setImage(UIImage(systemName: "face.smiling"), for: .normal) }
            if key == "Search" { button.setTitle(nil, for: .normal); button.setImage(UIImage(systemName: "checkmark"), for: .normal) }
            button.backgroundColor = key == "Search" ? .systemBlue : (["⇧", "⌫", "123", "ABC", "#+="].contains(key) ? searchUtilitySurfaceColor : searchKeySurfaceColor)
        }
    }

    private func updateCategorySelection() {
        titleLabel.text = category.title
        for (item, button) in categoryButtons {
            let selected = item == category
            button.alpha = selected ? 1 : 0.48
            button.tintColor = selected ? .label : .secondaryLabel
            button.layer.cornerRadius = 15
            button.layer.cornerCurve = .continuous
            button.backgroundColor = selected ? UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 0.34, alpha: 1) : UIColor(red: 0.76, green: 0.77, blue: 0.80, alpha: 1)
            } : .clear
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { EmojiCatalog.emoji(for: category).count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath)
        let label: UILabel
        if let existing = cell.contentView.subviews.first as? UILabel { label = existing }
        else {
            label = UILabel()
            label.font = .systemFont(ofSize: 28)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor), label.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor), label.topAnchor.constraint(equalTo: cell.contentView.topAnchor), label.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)])
        }
        label.text = EmojiCatalog.emoji(for: category)[indexPath.item]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let emoji = EmojiCatalog.emoji(for: category)[indexPath.item]
        EmojiCatalog.record(emoji)
        onSelect?(emoji)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: floor(collectionView.bounds.width / 9), height: 38)
    }
}

/// The system keyboard represents a zero-width joiner with two dotted
/// circles bridged by an arch. It is a key label, not text that gets inserted.
private func joinerKeyImage() -> UIImage {
    JoinerKeyImage.image
}

private enum JoinerKeyImage {
    static let image: UIImage = {
    let size = CGSize(width: 34, height: 25)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        let graphics = context.cgContext
        graphics.setStrokeColor(UIColor.label.cgColor)
        graphics.setLineWidth(2.25)
        graphics.setLineCap(.round)

        let arch = UIBezierPath()
        arch.move(to: CGPoint(x: 3, y: 8))
        arch.addCurve(to: CGPoint(x: 31, y: 8), controlPoint1: CGPoint(x: 10, y: 1), controlPoint2: CGPoint(x: 24, y: 1))
        graphics.addPath(arch.cgPath)
        graphics.strokePath()

        graphics.setLineWidth(1.8)
        graphics.setLineDash(phase: 0, lengths: [0.1, 3.5])
        for centerX in [10.0, 24.0] {
            graphics.addEllipse(in: CGRect(x: centerX - 5.5, y: 12, width: 11, height: 11))
            graphics.strokePath()
        }
        graphics.setLineDash(phase: 0, lengths: [])
    }.withRenderingMode(.alwaysTemplate)
    }()
}

/// A compact rendition of the iOS character-preview balloon. Drawing it in a
/// separate overlay prevents Auto Layout from moving the keyboard rows while a
/// finger is down.
private final class KeyPreviewView: UIView {
    private let glyphLabel = UILabel()
    private let shapeLayer = CAShapeLayer()
    private var glyphBottomConstraint: NSLayoutConstraint!
    private var lowerWidth: CGFloat = 30
    private var lowerCenterX: CGFloat = 30
    private var lowerHeight: CGFloat = 42

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 3
        glyphLabel.textAlignment = .center
        glyphLabel.textColor = .label
        glyphLabel.font = .systemFont(ofSize: 31, weight: .regular)
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)
        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glyphLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            glyphLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
        ])
        glyphBottomConstraint = glyphLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(lowerHeight + 6))
        glyphBottomConstraint.isActive = true
        layer.insertSublayer(shapeLayer, at: 0)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        let w = bounds.width
        let h = bounds.height
        // A wide upper chamber narrows into a lower section that exactly
        // matches the originating key's width and horizontal position.
        let lowerLeft = max(5, lowerCenterX - lowerWidth / 2)
        let lowerRight = min(w - 5, lowerCenterX + lowerWidth / 2)
        let lowerTop = h - lowerHeight
        let shoulderY = lowerTop - 11
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 8, y: shoulderY))
        path.addLine(to: CGPoint(x: 8, y: 9))
        path.addQuadCurve(to: CGPoint(x: 17, y: 0), controlPoint: CGPoint(x: 8, y: 0))
        path.addLine(to: CGPoint(x: w - 17, y: 0))
        path.addQuadCurve(to: CGPoint(x: w - 8, y: 9), controlPoint: CGPoint(x: w - 8, y: 0))
        path.addLine(to: CGPoint(x: w - 8, y: shoulderY))
        path.addCurve(to: CGPoint(x: lowerRight, y: lowerTop), controlPoint1: CGPoint(x: w - 8, y: shoulderY + 6), controlPoint2: CGPoint(x: lowerRight + 6, y: lowerTop))
        path.addLine(to: CGPoint(x: lowerRight, y: h - 6))
        path.addQuadCurve(to: CGPoint(x: lowerRight - 6, y: h), controlPoint: CGPoint(x: lowerRight, y: h))
        path.addLine(to: CGPoint(x: lowerLeft + 6, y: h))
        path.addQuadCurve(to: CGPoint(x: lowerLeft, y: h - 6), controlPoint: CGPoint(x: lowerLeft, y: h))
        path.addLine(to: CGPoint(x: lowerLeft, y: lowerTop))
        path.addCurve(to: CGPoint(x: 8, y: shoulderY), controlPoint1: CGPoint(x: lowerLeft - 6, y: lowerTop), controlPoint2: CGPoint(x: 8, y: shoulderY + 6))
        path.close()
        shapeLayer.path = path.cgPath
        shapeLayer.fillColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.68, alpha: 1) : UIColor.white
        }.cgColor
    }

    func display(_ title: String) { glyphLabel.text = title }

    func configure(lowerWidth: CGFloat, lowerCenterX: CGFloat, lowerHeight: CGFloat) {
        self.lowerWidth = lowerWidth
        self.lowerCenterX = lowerCenterX
        self.lowerHeight = lowerHeight
        glyphBottomConstraint.constant = -(lowerHeight + 6)
        setNeedsLayout()
    }
}

/// Non-interactive, press-and-slide alternate picker. The originating key
/// keeps the touch stream; this view only renders the same kind of expanded
/// choice strip that iOS presents for held characters.
private final class AlternateCharacterPickerView: UIView {
    private var labels: [UILabel] = []
    private let selectionLayer = CALayer()
    private(set) var selectedIndex = 0

    init(choices: [String]) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.66, alpha: 1) : .white
        }
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 3
        selectionLayer.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : UIColor(white: 0.82, alpha: 1)
        }.cgColor
        selectionLayer.cornerRadius = 8
        layer.insertSublayer(selectionLayer, at: 0)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        for choice in choices {
            let label = UILabel()
            label.text = choice
            label.textColor = .label
            label.font = .systemFont(ofSize: 29, weight: .regular)
            label.textAlignment = .center
            stack.addArrangedSubview(label)
            labels.append(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSelection(animated: false)
    }

    func select(at point: CGPoint) -> Int {
        let itemWidth = bounds.width / CGFloat(max(labels.count, 1))
        let index = min(max(Int(point.x / itemWidth), 0), labels.count - 1)
        guard index != selectedIndex else { return selectedIndex }
        selectedIndex = index
        updateSelection(animated: true)
        return index
    }

    func select(index: Int) {
        selectedIndex = min(max(index, 0), labels.count - 1)
        updateSelection(animated: false)
    }

    private func updateSelection(animated: Bool) {
        guard !labels.isEmpty else { return }
        let itemWidth = bounds.width / CGFloat(labels.count)
        let frame = CGRect(x: CGFloat(selectedIndex) * itemWidth + 4, y: 4, width: itemWidth - 8, height: bounds.height - 8)
        if animated {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.08)
            selectionLayer.frame = frame
            CATransaction.commit()
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            selectionLayer.frame = frame
            CATransaction.commit()
        }
    }
}

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    private enum Layer { case letters, numbers, symbols }
    /// KeyboardKit's device configurations are a useful model here: a full
    /// iPad keyboard is not a stretched iPhone keyboard.  It has taller keys,
    /// a different action placement, and needs to respond when an iPad enters
    /// Split View or uses the floating keyboard.
    private enum LayoutProfile: Equatable {
        case phonePortrait, phoneLandscape, padPortrait, padLandscape
    }
    private var layer: Layer = .letters
    private var shift = false
    private var rawBuffer = ""
    private var phoneticBuffer = ""
    private var lastPhoneticRendered = ""
    /// The phonetic compositor needs a short look-behind window so a later
    /// vowel can replace a consonant's provisional virama.  Keep that window
    /// marked, but commit older, unambiguous chunks.  Some host editors are
    /// noticeably slower when asked to redraw an ever-growing marked range.
    private var committedPhoneticSegments: [(source: String, rendered: String)] = []
    private let maximumMarkedPhoneticSourceLength = 8
    private var visibleEntries: [String] = []
    private var visibleSources: [String] = []
    private enum MarkedCompositionKind { case prebase, independentVowel }
    private var markedSource: String?
    private var markedKind: MarkedCompositionKind?
    private var mode: SinhalaEngine.Mode = .sls
    private var lastSpaceTimestamp: TimeInterval?
    private let keyboardStack = UIStackView()
    /// iOS 26 owns the keyboard's colour treatment through a system material;
    /// older OS versions keep the calibrated opaque surface below.
    private let keyboardChrome = UIVisualEffectView(effect: nil)
    private let candidateBar = UIView()
    private var candidateBarHeight: NSLayoutConstraint!
    private var keyboardMinimumHeight: NSLayoutConstraint!
    private var candidateButtons: [UIButton] = []
    private var candidates: [String?] = [nil, nil, nil]
    private var predictionPrefix = ""
    private var emojiPicker: EmojiPickerView?
    private let trackpadSurface = UIView()
    private var deleteRepeater: Timer?
    private var keyPreview: KeyPreviewView?
    private var alternatePicker: AlternateCharacterPickerView?
    private var keyFeedback: KeyFeedback?
    // The language-label transition is an input-session introduction, not a
    // key-layer transition. Rebuilding for Shift or 123 must keep it quiet.
    private var shouldAnimateSpaceLabel = true
    private var spaceTrackpadStartX: CGFloat = 0
    private var spaceTrackpadOffset = 0
    private var appliedLayoutProfile: LayoutProfile?

    private var usesIOS16KeyboardAppearance: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    private var layoutProfile: LayoutProfile {
        // An input view is a shallow horizontal strip in every orientation;
        // comparing its own width and height classifies almost every portrait
        // device as landscape. Use the enclosing window scene instead.
        let isLandscape = view.window?.windowScene?.interfaceOrientation.isLandscape
            ?? (view.bounds.width > view.bounds.height)
        // A floating / narrow Split View iPad keyboard needs the compact
        // layout.  Checking the input view width rather than only idiom keeps
        // it usable in every iPad multitasking size.
        let isFullWidthPad = UIDevice.current.userInterfaceIdiom == .pad && view.bounds.width >= 600
        switch (isFullWidthPad, isLandscape) {
        case (true, true): return .padLandscape
        case (true, false): return .padPortrait
        case (false, true): return .phoneLandscape
        case (false, false): return .phonePortrait
        }
    }

    private var usesPadLayout: Bool {
        switch layoutProfile {
        case .padPortrait, .padLandscape: return true
        case .phonePortrait, .phoneLandscape: return false
        }
    }

    private var candidateHeight: CGFloat {
        switch layoutProfile {
        case .padPortrait, .padLandscape: return 44
        case .phoneLandscape: return 28
        case .phonePortrait: return 29
        }
    }

    private var keyboardBaseHeight: CGFloat {
        switch layoutProfile {
        case .padPortrait: return 292
        case .padLandscape: return 374
        case .phoneLandscape: return 162
        // Native iPhone 17 Pro chrome starts two points lower than the
        // previous 216 pt surface. This keeps its rounded top edge aligned
        // with the system keyboard while preserving the 29 pt candidate rail.
        case .phonePortrait: return 214
        }
    }

    private var standardKeyboardHeight: CGFloat {
        keyboardBaseHeight + (showsCandidateBar ? candidateHeight : 0)
    }

    /// All Sinhala layouts share the candidate rail. Direct Wijesekara input
    /// does not need transliteration candidates, but it does use this rail for
    /// word prediction once a local prediction provider is enabled.
    private var showsCandidateBar: Bool {
        KeyboardPreferences.suggestionsEnabled()
    }

    private var emojiPickerHeight: CGFloat {
        usesPadLayout ? keyboardBaseHeight : 251
    }

    var enableInputClicksWhenVisible: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Match the dark system keyboard chrome so the extension flows into
        // iOS's own input-mode / dictation footer without a visible seam.
        view.backgroundColor = .clear
        if #available(iOS 26.0, *) {
            // The material backdrop samples the white Messages canvas and
            // produces #DDDEE1, visibly darker than the system keyboard
            // footer (#E2E4E8). Use the measured system surface directly so
            // the extension meets that footer without a colour seam.
            keyboardChrome.effect = nil
            keyboardChrome.contentView.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
                    : UIColor(red: 226 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1)
            }
        } else {
            keyboardChrome.effect = nil
            keyboardChrome.contentView.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
                    : (self.usesIOS16KeyboardAppearance
                        ? UIColor(red: 209 / 255, green: 210 / 255, blue: 216 / 255, alpha: 1)
                        : UIColor(red: 226 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1))
            }
        }
        keyboardChrome.translatesAutoresizingMaskIntoConstraints = false
        keyboardChrome.layer.cornerRadius = 24
        keyboardChrome.layer.cornerCurve = .continuous
        keyboardChrome.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        keyboardChrome.clipsToBounds = true
        mode = KeyboardPreferences.selectedMode()
        configureLayout()
        keyFeedback = KeyFeedback(view: view)
        keyFeedback?.prepare()
        rebuildKeys()
        // A native candidate rail is populated immediately, rather than
        // presenting a blank, segmented strip until the first character.
        updatePredictions(for: "")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // `hasFullAccess` is only available inside the keyboard extension.
        // Persist a positive confirmation for the containing app to display.
        if hasFullAccess {
            KeyboardPreferences.setFullAccessConfirmed(true)
        }
        let selectedMode = KeyboardPreferences.selectedMode()
        if selectedMode != mode {
            commitActiveComposition()
            mode = selectedMode
        }
        shouldAnimateSpaceLabel = true
        keyFeedback?.prepare()
        rebuildKeys()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The first layout is where an extension receives its true width.
        // Rebuild only when the profile changes, never per keystroke.
        let profile = layoutProfile
        guard profile != appliedLayoutProfile else { return }
        appliedLayoutProfile = profile
        candidateBarHeight?.constant = showsCandidateBar ? candidateHeight : 0
        let contentHeight = emojiPicker == nil ? standardKeyboardHeight : emojiPickerHeight
        keyboardMinimumHeight?.constant = contentHeight
        preferredContentSize = CGSize(width: 0, height: contentHeight)
        keyboardStack.spacing = usesPadLayout ? 10 : (profile == .phoneLandscape ? 5 : 8)
        candidateButtons.enumerated().forEach { index, button in
            button.titleLabel?.font = .systemFont(
                ofSize: usesPadLayout ? 20 : 18,
                weight: index == 1 ? .medium : .regular
            )
        }
        rebuildKeys()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDeleteRepeat()
        hideKeyPreview(animated: false)
        hideAlternatePicker()
        // The emoji picker is extension-owned. It must never survive an input
        // mode change and cover the next (native) keyboard.
        hideEmojiPicker()
        setTrackpadAppearance(active: false, animated: false)
    }

    private func configureLayout() {
        view.addSubview(keyboardChrome)
        NSLayoutConstraint.activate([
            keyboardChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardChrome.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardChrome.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.isUserInteractionEnabled = true
        candidateBar.backgroundColor = .clear
        view.addSubview(candidateBar)
        let segments = UIStackView()
        segments.axis = .horizontal
        segments.distribution = .fillEqually
        segments.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.addSubview(segments)
        NSLayoutConstraint.activate([
            segments.leadingAnchor.constraint(equalTo: candidateBar.leadingAnchor),
            segments.trailingAnchor.constraint(equalTo: candidateBar.trailingAnchor),
            segments.topAnchor.constraint(equalTo: candidateBar.topAnchor),
            segments.bottomAnchor.constraint(equalTo: candidateBar.bottomAnchor)
        ])
        for index in 0..<3 {
            let segment = UIView()
            segments.addArrangedSubview(segment)
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.titleLabel?.font = .systemFont(ofSize: 18, weight: index == 1 ? .medium : .regular)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(.label, for: .normal)
            button.tag = index
            button.addTarget(self, action: #selector(selectPrediction(_:)), for: .touchUpInside)
            segment.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: segment.leadingAnchor, constant: 8),
                button.trailingAnchor.constraint(equalTo: segment.trailingAnchor, constant: -8),
                button.topAnchor.constraint(equalTo: segment.topAnchor),
                button.bottomAnchor.constraint(equalTo: segment.bottomAnchor)
            ])
            candidateButtons.append(button)
            guard index < 2 else { continue }
            let separator = UIView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.36, alpha: 0.7)
                    : UIColor(red: 0.77, green: 0.79, blue: 0.83, alpha: 0.75)
            }
            segment.addSubview(separator)
            NSLayoutConstraint.activate([
                separator.trailingAnchor.constraint(equalTo: segment.trailingAnchor),
                separator.centerYAnchor.constraint(equalTo: candidateBar.centerYAnchor),
                separator.heightAnchor.constraint(equalToConstant: 26),
                separator.widthAnchor.constraint(equalToConstant: 1)
            ])
        }
        candidateBarHeight = candidateBar.heightAnchor.constraint(equalToConstant: showsCandidateBar ? candidateHeight : 0)
        NSLayoutConstraint.activate([
            candidateBar.leadingAnchor.constraint(equalTo: keyboardChrome.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: keyboardChrome.trailingAnchor),
            candidateBar.topAnchor.constraint(equalTo: keyboardChrome.topAnchor),
            candidateBarHeight
        ])
        keyboardStack.axis = .vertical; keyboardStack.spacing = 8; keyboardStack.distribution = .fillEqually
        keyboardStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardStack)
        NSLayoutConstraint.activate([
            keyboardStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: usesIOS16KeyboardAppearance ? 5 : 7),
            keyboardStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: usesIOS16KeyboardAppearance ? -5 : -7),
            keyboardStack.topAnchor.constraint(
                equalTo: candidateBar.bottomAnchor,
                constant: usesIOS16KeyboardAppearance ? 11 : 7
            ),
            // Give the iOS 16 grid a little more breathing room vertically
            // without reintroducing the unwanted left/right inset.
            keyboardStack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: usesIOS16KeyboardAppearance ? -2 : -7
            ),
        ])
        keyboardMinimumHeight = view.heightAnchor.constraint(greaterThanOrEqualToConstant: standardKeyboardHeight)
        keyboardMinimumHeight.isActive = true
        trackpadSurface.translatesAutoresizingMaskIntoConstraints = false
        trackpadSurface.isUserInteractionEnabled = false
        trackpadSurface.layer.cornerRadius = 7
        trackpadSurface.layer.cornerCurve = .continuous
        trackpadSurface.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.58, alpha: 1) : UIColor(white: 0.72, alpha: 1)
        }
        trackpadSurface.alpha = 0
        view.addSubview(trackpadSurface)
        NSLayoutConstraint.activate([
            trackpadSurface.leadingAnchor.constraint(equalTo: keyboardStack.leadingAnchor),
            trackpadSurface.trailingAnchor.constraint(equalTo: keyboardStack.trailingAnchor),
            trackpadSurface.topAnchor.constraint(equalTo: keyboardStack.topAnchor),
            trackpadSurface.bottomAnchor.constraint(equalTo: keyboardStack.bottomAnchor)
        ])
        preferredContentSize = CGSize(width: 0, height: standardKeyboardHeight)
    }

    private func rebuildKeys() {
        candidateBarHeight?.constant = showsCandidateBar ? candidateHeight : 0
        candidateBar.isHidden = !showsCandidateBar
        if emojiPicker == nil {
            keyboardMinimumHeight?.constant = standardKeyboardHeight
            preferredContentSize = CGSize(width: 0, height: standardKeyboardHeight)
        }
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Match the native English fourth row: the emoji affordance sits
        // between the number key and Space. A keyboard extension can ask iOS
        // to advance input modes, but cannot select Emoji directly.
        let emojiKey = KeyboardPreferences.emojiEnabled() ? ["emoji"] : []
        let globeKey = needsInputModeSwitchKey ? ["globe"] : []
        let bottom = usesPadLayout
            ? ["123"] + emojiKey + globeKey + ["space", "123", "dismiss"]
            : ["123"] + emojiKey + globeKey + ["space", "return"]
        // The native Sinhala reference uses three even 11-key rows. Preserve
        // that geometry while exposing the full direct Wijesekara layer.
        let letterRows: [[String]]
        if usesPadLayout {
            // Match the iPad convention of putting Delete and Return at the
            // trailing edge of the first two letter rows.  This prevents the
            // old phone-only bottom row from becoming a sparse, oversized
            // strip on a full-width iPad.
            letterRows = mode == .sls
                ? [["q","w","e","r","t","y","u","i","o","p","[","delete"], ["a","s","d","f","g","h","j","k","l",";","return"], ["shift","rakaranshaya","x","c","v","b","n","m",",",".","shift"]]
                : [["q","w","e","r","t","y","u","i","o","p","delete"], ["a","s","d","f","g","h","j","k","l","return"], ["shift","z","x","c","v","b","n","m","shift"]]
        } else {
            letterRows = mode == .sls
                ? [["q","w","e","r","t","y","u","i","o","p","["], ["a","s","d","f","g","h","j","k","l",";"], ["shift","rakaranshaya","x","c","v","b","n","m",",",".","delete"]]
                : [["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l"], ["shift","z","x","c","v","b","n","m","delete"]]
        }
        let rows: [[String]]
        switch layer {
        case .letters:
            rows = letterRows + [bottom]
        case .numbers:
            rows = usesPadLayout
                ? [["1","2","3","4","5","6","7","8","9","0","delete"], ["-","/",":",";","(",")","$","&","@","\"","return"], ["#+=",".",",","?","!","kundaliya","#+="], bottom.map { $0 == "123" ? "ABC" : $0 }]
                : [["1","2","3","4","5","6","7","8","9","0"], ["-","/",":",";","(",")","$","&","@","\""], ["#+=",".",",","?","!","kundaliya","delete"], bottom.map { $0 == "123" ? "ABC" : $0 }]
        case .symbols:
            rows = usesPadLayout
                ? [["[","]","{","}","#","%","^","*","+","=","delete"], ["_","\\","|","~","<",">","€","£","¥","•","return"], ["123",".",",","?","!","kundaliya","123"], bottom.map { $0 == "123" ? "ABC" : $0 }]
                : [["[","]","{","}","#","%","^","*","+","="], ["_","\\","|","~","<",">","€","£","¥","•"], ["123",".",",","?","!","kundaliya","delete"], bottom.map { $0 == "123" ? "ABC" : $0 }]
        }
        for (index, row) in rows.enumerated() { keyboardStack.addArrangedSubview(makeRow(row, index: index)) }
    }

    private func makeRow(_ keys: [String], index: Int) -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 6; row.alignment = .fill
        let isBottom = index == 3
        let isEnglishAlphabet = layer == .letters && mode != .sls
        row.distribution = usesPadLayout && !isBottom ? .fillEqually : ((isBottom || index == 2) ? .fill : .fillEqually)
        if isEnglishAlphabet && index == 1 {
            row.layoutMargins = UIEdgeInsets(top: 0, left: 21, bottom: 0, right: 21)
            row.isLayoutMarginsRelativeArrangement = true
        } else if usesPadLayout && index == 2 && keys.count < 10 {
            // Sparse phonetic and numeric rows are centred on iPad instead of
            // becoming much wider than the upper rows. Seven-key symbol rows
            // need a larger inset than the nine-key phonetic row.
            let fraction: CGFloat = keys.count <= 7 ? 0.24 : 0.14
            let inset = max(42, view.bounds.width * fraction)
            row.layoutMargins = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            row.isLayoutMarginsRelativeArrangement = true
        } else if index == 2 {
            row.layoutMargins = UIEdgeInsets(top: 0, left: isEnglishAlphabet ? 0 : 2, bottom: 0, right: isEnglishAlphabet ? 0 : 2)
            row.isLayoutMarginsRelativeArrangement = true
        }
        var letterButtons: [NativeKeyButton] = []
        for keyName in keys {
            let button = makeKey(keyName)
            row.addArrangedSubview(button)
            if isBottom {
                switch keyName {
                case "123", "ABC": button.widthAnchor.constraint(equalToConstant: usesPadLayout ? 58 : (isEnglishAlphabet ? 42 : 56)).isActive = true
                case "emoji", "globe", "dismiss": button.widthAnchor.constraint(equalToConstant: usesPadLayout ? 58 : (isEnglishAlphabet ? 42 : 46)).isActive = true
                case "return": button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 92 : 72).isActive = true
                default: break
                }
            } else if !usesPadLayout && index == 2 && keyName == "shift" {
                // The phonetic layout has seven letter keys here. Giving its
                // system controls the remaining width makes those letters the
                // same width as the ten keys above, just like iOS.
                button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 51 : 31).isActive = true
            } else if !usesPadLayout && index == 2 && keyName == "delete" {
                button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 51 : 31).isActive = true
            } else if index == 2 {
                letterButtons.append(button)
            }
        }
        for button in letterButtons.dropFirst() { button.widthAnchor.constraint(equalTo: letterButtons[0].widthAnchor).isActive = true }
        return row
    }

    private func makeKey(_ key: String) -> NativeKeyButton {
        let utility = ["shift", "delete", "123", "ABC", "#+=", "globe", "dismiss"].contains(key)
        let button = NativeKeyButton(
            title: title(for: key),
            hint: hint(for: key),
            symbol: symbol(for: key),
            utility: utility
        )
        button.applyLayoutMetrics(isPad: usesPadLayout)
        button.touchDown = { [weak self] in
            // If iOS failed to deliver an old Delete touch-up (for example
            // after a host-app cursor move), any new contact is authoritative.
            self?.stopDeleteRepeat()
            self?.keyFeedback?.keyPressed()
        }
        if key == "space" {
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
            button.titleLabel?.minimumScaleFactor = 0.8
            if shouldAnimateSpaceLabel {
                shouldAnimateSpaceLabel = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak button] in
                    button?.collapseSpaceTitle()
                }
            } else {
                // Layer rebuilds replace the button. Apply the settled state
                // directly so Shift/123/#+= never replay the introduction.
                button.collapseSpaceTitle(animated: false)
            }
        }
        if key == "rakaranshaya", shift {
            button.setTitle(nil, for: .normal)
            button.setImage(joinerKeyImage(), for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = "Zero Width Joiner"
        }
        button.highlightChanged = { [weak self] button, highlighted in
            guard key != "space", button.supportsCharacterPreview else { return }
            if highlighted {
                self?.showKeyPreview(for: button)
            } else {
                self?.hideKeyPreview()
            }
        }
        let triggerEvent: UIControl.Event = shouldCommitOnTouchDown(key) ? .touchDown : .touchUpInside
        button.addAction(UIAction { [weak self, weak button] _ in
            guard button?.consumeLongPressHandled() != true else { return }
            self?.press(key)
        }, for: triggerEvent)
        if key == "delete" {
            // Start repeat only after UIKit has positively recognized a hold.
            // A touch-down timer can outlive a rapid tap when the host app
            // changes lines, causing unexpected deletion after the finger has
            // already lifted.
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleDeleteLongPress(_:)))
            longPress.minimumPressDuration = 0.42
            longPress.cancelsTouchesInView = false
            button.addGestureRecognizer(longPress)
        }
        if key == "space" {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSpaceTrackpad(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.cancelsTouchesInView = false
            button.addGestureRecognizer(longPress)
        }
        if layer == .letters, mode == .sls, sanyakaya(for: key) != nil {
            button.accessibilityIdentifier = key
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSanyakayaLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.cancelsTouchesInView = false
            button.addGestureRecognizer(longPress)
        }
        return button
    }

    /// The system keyboard visibly commits normal taps as the finger lands.
    /// Keep Space and alternate-character keys on touch-up: a held Space
    /// enters cursor control, and these keys must not insert their base value
    /// before a long-press alternate is chosen.
    private func shouldCommitOnTouchDown(_ key: String) -> Bool {
        guard key != "space" else { return false }
        return !(layer == .letters && mode == .sls && sanyakaya(for: key) != nil)
    }

    /// Mirrors the system keyboard's long-press Space behavior. UIKit gives a
    /// keyboard extension cursor movement through UITextDocumentProxy rather
    /// than exposing the host text view directly.
    @objc private func handleSpaceTrackpad(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? NativeKeyButton else { return }
        switch recognizer.state {
        case .began:
            button.markLongPressHandled()
            commitActiveComposition()
            setTrackpadAppearance(active: true)
            spaceTrackpadStartX = recognizer.location(in: view).x
            spaceTrackpadOffset = 0
            keyFeedback?.prepare()
        case .changed:
            let movement = recognizer.location(in: view).x - spaceTrackpadStartX
            // Larger iPad keycaps need a slightly longer gesture before the
            // caret advances, otherwise a small settling movement jumps words.
            let pointsPerCharacter: CGFloat = usesPadLayout ? 16 : 10
            let targetOffset = Int(movement / pointsPerCharacter)
            let delta = targetOffset - spaceTrackpadOffset
            guard delta != 0 else { return }
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
            spaceTrackpadOffset = targetOffset
            keyFeedback?.selectionChanged()
        case .ended, .cancelled, .failed:
            spaceTrackpadOffset = 0
            setTrackpadAppearance(active: false)
        default:
            break
        }
    }

    private func setTrackpadAppearance(active: Bool, animated: Bool = true) {
        setKeyGlyphsHidden(active, animated: animated)
        // Native Space-trackpad mode does not dim the entire keyboard. Keep
        // this legacy overlay hidden; only the individual key glyphs fade.
        trackpadSurface.alpha = 0
    }

    private func setKeyGlyphsHidden(_ hidden: Bool, animated: Bool) {
        keyboardStack.arrangedSubviews.forEach { row in
            row.subviews.compactMap { $0 as? NativeKeyButton }.forEach {
                $0.setGlyphsHidden(hidden, animated: animated)
            }
        }
    }

    private func showKeyPreview(for button: NativeKeyButton) {
        guard let title = button.currentTitle else { return }
        let keyFrame = button.convert(button.bounds, to: view)
        // A custom keyboard cannot draw above its extension boundary. The
        // top-row balloon would be cut off, so omit it instead of rendering a
        // malformed partial preview.
        guard keyFrame.minY >= 47 else { return }
        let preview = keyPreview ?? KeyPreviewView()
        if preview.superview == nil {
            view.addSubview(preview)
            keyPreview = preview
            preview.alpha = 0
        }
        let maximumPreviewWidth: CGFloat = usesPadLayout ? 120 : 64
        let previewSize = CGSize(
            width: min(max(keyFrame.width + 26, 54), maximumPreviewWidth),
            height: keyFrame.height + (usesPadLayout ? 56 : 47)
        )
        let minX = view.bounds.minX + 2
        let maxX = view.bounds.maxX - previewSize.width - 2
        let x = min(max(keyFrame.midX - previewSize.width / 2, minX), maxX)
        // The bottom geometry retains the exact key width. For edge keys,
        // shift the stem within the clamped upper chamber to stay aligned.
        preview.configure(lowerWidth: keyFrame.width, lowerCenterX: keyFrame.midX - x, lowerHeight: keyFrame.height)
        preview.frame = CGRect(
            x: x,
            y: max(0, keyFrame.minY - (usesPadLayout ? 56 : 47)),
            width: previewSize.width,
            height: previewSize.height
        )
        preview.display(title)
        view.bringSubviewToFront(preview)
        if preview.alpha == 0 {
            preview.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
            UIView.animate(withDuration: 0.10, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                preview.alpha = 1
                preview.transform = .identity
            }
        } else {
            preview.alpha = 1
            preview.transform = .identity
        }
    }

    private func hideKeyPreview(animated: Bool = true) {
        guard let preview = keyPreview, preview.superview != nil else { return }
        let changes = { preview.alpha = 0; preview.transform = CGAffineTransform(scaleX: 0.88, y: 0.88) }
        if animated {
            UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: changes)
        } else {
            changes()
        }
    }

    private func symbol(for key: String) -> String? {
        switch key {
        case "shift": return "shift"
        case "delete": return "delete.left"
        case "emoji": return "face.smiling"
        case "globe": return "globe"
        case "return": return "return"
        case "dismiss": return "keyboard.chevron.compact.down"
        default: return nil
        }
    }

    private func title(for key: String) -> String? {
        if key == "space" {
            switch mode {
            case .sls: return "අක්ෂර Wijesekara"
            case .phonetic: return "අක්ෂර Phonetic"
            case .smartPhonetic: return "අක්ෂර Smart Phonetic"
            }
        }
        if ["shift", "delete", "emoji", "globe", "return", "dismiss"].contains(key) { return nil }
        if key == "rakaranshaya" { return shift ? "ZWJ" : "්‍ර" }
        if key == "kundaliya" { return "෴" }
        if key == "yansaya" { return "්‍ය" }
        // Shift–H is the Wijesekara yansaya only. In phonetic layouts it
        // remains the literal capital H, which the transliterator handles.
        if key == "h", shift, mode == .sls { return "්‍ය" }
        guard key.count == 1, layer == .letters else { return key }
        return mode == .sls ? SinhalaEngine.slsKeyLabel(key, shifted: shift) : (shift ? key.uppercased() : key)
    }

    private func hint(for key: String) -> String? {
        if mode == .sls, layer == .letters, let alternate = sanyakaya(for: key) {
            // Show the held-character result in the same quiet upper-right
            // position used for phonetic transliteration hints.
            return String(alternate)
        }
        guard mode != .sls, layer == .letters, key.count == 1 else { return nil }
        let source = shift ? key.uppercased() : key
        let rendered = SinhalaEngine.transliterate(source, mode: mode)
        let hint = rendered.unicodeScalars.filter {
            (0x0D80...0x0DFF).contains($0.value) && $0.value != 0x0DCA
        }
        guard !hint.isEmpty else { return nil }
        return String(String.UnicodeScalarView(hint))
    }

    private func press(_ key: String) {
        UIDevice.current.playInputClick()
        if key != "space" { lastSpaceTimestamp = nil }
        switch key {
        case "delete": deleteOnce()
        case "space": insertSpace()
        case "return": commit(suffix: "\n")
        case "emoji": showEmojiPicker()
        case "globe":
            // Dismiss our overlay before asking iOS to select the next input
            // mode. UIKit does not necessarily send viewWillDisappear first.
            hideEmojiPicker()
            advanceToNextInputMode()
        case "dismiss":
            commitActiveComposition()
            dismissKeyboard()
        case "shift": shift.toggle(); rebuildKeys()
        case "123": layer = .numbers; rebuildKeys()
        case "#+=": layer = .symbols; rebuildKeys()
        case "ABC": layer = .letters; rebuildKeys()
        case "rakaranshaya":
            insertLive(shift ? "\u{200D}" : "\u{E004}")
            if shift {
                shift = false
                rebuildKeys()
            }
        case "kundaliya": commit(suffix: "෴")
        case "yansaya": insertLive("\u{E005}")
        default:
            let input = shift ? key.uppercased() : key
            if layer == .letters {
                insertLive(mode == .sls ? SinhalaEngine.slsCharacter(for: key, shifted: shift) : input)
                // Rebuilding all controls after every character creates a
                // brief dead zone during rapid typing. The system keyboard
                // leaves its geometry alone unless Shift actually changes.
                if shift {
                    shift = false
                    rebuildKeys()
                }
            }
            else { commit(suffix: input) }
        }
    }

    private func showEmojiPicker() {
        guard emojiPicker == nil else { return }
        commitActiveComposition()
        let picker = EmojiPickerView()
        picker.onSelect = { [weak self] emoji in self?.commit(suffix: emoji) }
        picker.onDismiss = { [weak self] in self?.hideEmojiPicker() }
        picker.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        emojiPicker = picker
        candidateBar.isHidden = true
        keyboardStack.isHidden = true
        keyboardMinimumHeight.constant = emojiPickerHeight
        preferredContentSize = CGSize(width: 0, height: emojiPickerHeight)
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.topAnchor.constraint(equalTo: view.topAnchor),
            picker.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func hideEmojiPicker() {
        emojiPicker?.removeFromSuperview()
        emojiPicker = nil
        candidateBar.isHidden = !showsCandidateBar
        keyboardStack.isHidden = false
        keyboardMinimumHeight.constant = standardKeyboardHeight
        preferredContentSize = CGSize(width: 0, height: standardKeyboardHeight)
    }

    private func updatePredictions(for prefix: String) {
        guard showsCandidateBar else {
            predictionPrefix = ""
            candidates = [nil, nil, nil]
            candidateButtons.forEach { $0.setTitle(nil, for: .normal); $0.isEnabled = false }
            return
        }
        predictionPrefix = prefix
        let request = SinhalaPredictionRequest(
            composingText: prefix,
            precedingWords: predictionContext(for: prefix),
            maximumResults: 3
        )
        let ranked = SinhalaPredictionProviderRegistry.shared.activeProvider
            .candidates(for: request)
            .map(\.text)
        // iOS gives the centre slot the strongest visual weight. Preserve the
        // dictionary ranking while presenting its best match in that slot.
        switch ranked.count {
        case 3: candidates = [ranked[1], ranked[0], ranked[2]]
        case 2: candidates = [ranked[1], ranked[0], nil]
        case 1: candidates = [nil, ranked[0], nil]
        default: candidates = [nil, nil, nil]
        }
        for (index, button) in candidateButtons.enumerated() {
            button.setTitle(candidates[index], for: .normal)
            button.isEnabled = candidates[index] != nil
        }
    }

    @objc private func selectPrediction(_ sender: UIButton) {
        guard sender.tag < candidates.count, let candidate = candidates[sender.tag] else { return }
        let precedingWord = predictionContext(for: predictionPrefix).last
        if !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty {
            clearPhoneticComposition()
        } else if markedSource != nil {
            // Independent-vowel and pre-base Wijesekara input is already a
            // marked range. Clearing it replaces that range; attempting a
            // backward delete instead leaves it in place and duplicates the
            // candidate (for example අඅම්මා).
            clearMarkedComposition()
        } else {
            // The POC only predicts a word being actively built by this
            // keyboard, so deleting its grapheme clusters is bounded and does
            // not inspect host-app text.
            // UITextDocumentProxy removes the composing Sinhala scalars one
            // at a time. Counting grapheme clusters leaves the independent
            // vowel behind for inputs such as අම්, yielding අඅම්මා.
            for _ in predictionPrefix.unicodeScalars { textDocumentProxy.deleteBackward() }
        }
        // Selecting a prediction completes a word. Match the system keyboard
        // by committing its separator as part of the selection, so the next
        // keystroke begins the following word rather than appending to it.
        textDocumentProxy.insertText(candidate + " ")
        // Learn only a deliberate selection. Raw host-app text and ordinary
        // keystrokes stay ephemeral, while the user can still remove learned
        // data later when we add dictionary-management settings.
        SinhalaPredictionProviderRegistry.shared.activeProvider.recordSelection(candidate, after: precedingWord)
        // A selected candidate replaces the entire active word. Keeping the
        // old per-key deletion history would make the next Backspace delete a
        // prefix of the chosen word instead of one document character.
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        predictionPrefix = ""
        candidates = [nil, nil, nil]
        candidateButtons.forEach { $0.setTitle(nil, for: .normal); $0.isEnabled = false }
    }

    /// `UITextDocumentProxy` gives a bounded pre-cursor window. Use it only to
    /// rank the current suggestion in memory; the provider never persists it.
    private func predictionContext(for composingText: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words = (textDocumentProxy.documentContextBeforeInput ?? "")
            .components(separatedBy: separators)
            .filter { word in
                !word.isEmpty && word.unicodeScalars.contains { (0x0D80...0x0DFF).contains($0.value) }
            }
        // With direct Wijesekara input the current partial word is already in
        // the host document. It is not prior-word context for its own ranking.
        if !composingText.isEmpty, words.last?.hasSuffix(composingText) == true {
            words.removeLast()
        }
        return Array(words.suffix(2))
    }

    private func deleteOnce() {
        lastSpaceTimestamp = nil
        if !phoneticBuffer.isEmpty {
            phoneticBuffer.removeLast()
            if phoneticBuffer.isEmpty {
                restorePreviousPhoneticSegmentAfterDelete()
            } else {
                updatePhoneticComposition()
            }
            return
        }
        if !committedPhoneticSegments.isEmpty {
            restorePreviousPhoneticSegmentAfterDelete()
            return
        }
        if var source = markedSource {
            source.removeLast()
            if source.isEmpty {
                clearMarkedComposition()
            } else if let kind = markedKind {
                updateMarkedComposition(source, kind: kind)
            }
            return
        }
        guard !rawBuffer.isEmpty else { textDocumentProxy.deleteBackward(); return }
        if let visible = visibleEntries.popLast(), let source = visibleSources.popLast() {
            for _ in source { rawBuffer.removeLast() }
            for _ in visible { textDocumentProxy.deleteBackward() }
            // The key layout itself has not changed. Recreating every button
            // here adds layout work right as the user is likely to press
            // Delete again; refresh only the suggestion content instead.
            updatePredictions(for: visibleEntries.joined())
        }
    }

    @objc private func handleDeleteLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            stopDeleteRepeat()
            // The initial touch-down already deleted one character. A
            // confirmed hold begins with the next character, then repeats.
            deleteOnce()
            let repeater = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.deleteOnce()
            }
            deleteRepeater = repeater
            RunLoop.main.add(repeater, forMode: .common)
        case .ended, .cancelled, .failed:
            stopDeleteRepeat()
        default:
            break
        }
    }

    @objc private func stopDeleteRepeat() {
        deleteRepeater?.invalidate()
        deleteRepeater = nil
    }

    /// The four prenasalized Sinhala consonants live behind their ordinary
    /// Wijesekara consonant keys, just like iOS alternate characters.
    private func sanyakaya(for key: String) -> Character? {
        [".": "ඟ", "c": "ඦ", "v": "ඬ", "o": "ඳ"][key]
    }

    @objc private func handleSanyakayaLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? NativeKeyButton,
              let key = button.accessibilityIdentifier,
              let character = sanyakaya(for: key) else { return }
        switch recognizer.state {
        case .began:
            // Suppress the key's normal touch-up action once the alternate
            // picker is open. A quick tap never reaches this state.
            button.markLongPressHandled()
            hideKeyPreview()
            showAlternatePicker(for: button, alternate: String(character))
            keyFeedback?.selectionChanged()
        case .changed:
            // Each supported sangaka key currently has one alternate. Keep it
            // selected throughout the drag, as iOS does for a single-choice
            // expanded key, instead of letting the original key win again.
            break
        case .ended:
            hideAlternatePicker()
            insertLive(String(character))
        case .cancelled, .failed:
            hideAlternatePicker()
        default:
            break
        }
    }

    private func showAlternatePicker(for button: NativeKeyButton, alternate: String) {
        let picker = AlternateCharacterPickerView(choices: [alternate])
        let keyFrame = button.convert(button.bounds, to: view)
        let side: CGFloat = usesPadLayout ? 76 : 60
        let size = CGSize(width: side, height: side)
        let x = min(max(keyFrame.midX - size.width / 2, view.bounds.minX + 2), view.bounds.maxX - size.width - 2)
        picker.frame = CGRect(x: x, y: max(0, keyFrame.minY - 44), width: size.width, height: size.height)
        picker.select(index: 0)
        picker.alpha = 0
        picker.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
        view.addSubview(picker)
        view.bringSubviewToFront(picker)
        alternatePicker = picker
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
            picker.alpha = 1
            picker.transform = .identity
        }
    }

    private func hideAlternatePicker() {
        alternatePicker?.removeFromSuperview()
        alternatePicker = nil
    }

    private func commit(suffix: String) {
        if !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty {
            commitPhoneticComposition(suffix: suffix)
            updatePredictions(for: "")
            return
        }
        if markedSource != nil {
            commitMarkedComposition(suffix: suffix)
            rawBuffer = ""
            visibleEntries.removeAll()
            visibleSources.removeAll()
            updatePredictions(for: "")
            return
        }
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        updatePredictions(for: "")
        // Text commitment does not alter the key geometry. Rebuilding this
        // hierarchy after every Space, punctuation mark, or Return creates a
        // brief input dead zone for the next rapid touch.
        textDocumentProxy.insertText(suffix)
    }

    /// Uses the system's marked-text session for multistage Sinhala input.
    /// The provisional glyph stays visible and is replaced in place until the
    /// next unrelated key commits it.
    private func insertLive(_ source: String) {
        if mode != .sls {
            phoneticBuffer += source
            updatePhoneticComposition()
            return
        }
        if let markedSource, let markedKind {
            switch markedKind {
            case .prebase where canExtendPrebase(markedSource, with: source):
                updateMarkedComposition(markedSource + source, kind: .prebase)
                return
            case .independentVowel where combinesWithIndependentVowel(markedSource, suffix: source):
                updateMarkedComposition(markedSource + source, kind: .independentVowel)
                return
            default:
                commitMarkedComposition()
                insertLive(source)
                return
            }
        }
        if source == "ෙ" {
            updateMarkedComposition(source, kind: .prebase)
            return
        }
        if isIndependentVowel(source) {
            updateMarkedComposition(source, kind: .independentVowel)
            return
        }
        insertRendered(source)
    }

    private func updateMarkedComposition(_ source: String, kind: MarkedCompositionKind) {
        let rendered = SinhalaEngine.transliterate(source, mode: mode)
        let caret = (rendered as NSString).length
        textDocumentProxy.setMarkedText(rendered, selectedRange: NSRange(location: caret, length: 0))
        markedSource = source
        markedKind = kind
        // The marked cluster replaces only the tail of the word. Keep the
        // already committed Wijesekara glyphs in the provider request rather
        // than treating this cluster as a new word.
        updatePredictions(for: visibleEntries.joined() + rendered)
    }

    private func updatePhoneticComposition() {
        commitStablePhoneticPrefixIfNeeded()
        let rendered = SinhalaEngine.transliterate(phoneticBuffer, mode: mode)
        
        let oldScalars = Array(lastPhoneticRendered.unicodeScalars)
        let newScalars = Array(rendered.unicodeScalars)
        
        var commonCount = 0
        for (o, n) in zip(oldScalars, newScalars) {
            if o == n { commonCount += 1 } else { break }
        }
        
        let deletes = oldScalars.count - commonCount
        for _ in 0..<deletes { textDocumentProxy.deleteBackward() }
        
        let inserts = String(String.UnicodeScalarView(newScalars[commonCount...]))
        if !inserts.isEmpty { textDocumentProxy.insertText(inserts) }
        
        lastPhoneticRendered = rendered
        updatePredictions(for: committedPhoneticSegments.map(\.rendered).joined() + rendered)
    }

    private func commitPhoneticComposition(suffix: String = "") {
        guard !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty else { return }
        if !suffix.isEmpty { textDocumentProxy.insertText(suffix) }
        phoneticBuffer = ""
        lastPhoneticRendered = ""
        committedPhoneticSegments.removeAll()
        updatePredictions(for: "")
    }

    private func clearPhoneticComposition() {
        for _ in lastPhoneticRendered.unicodeScalars { textDocumentProxy.deleteBackward() }
        phoneticBuffer = ""
        lastPhoneticRendered = ""
        for segment in committedPhoneticSegments.reversed() {
            for _ in segment.rendered.unicodeScalars { textDocumentProxy.deleteBackward() }
        }
        committedPhoneticSegments.removeAll()
        updatePredictions(for: "")
    }

    /// Move a prefix out of the host editor's marked range only when splitting
    /// it produces exactly the same visible text.  This preserves the
    /// compositor's semantics while bounding the expensive host-side redraw.
    private func commitStablePhoneticPrefixIfNeeded() {
        let sourceLength = phoneticBuffer.count
        guard sourceLength > maximumMarkedPhoneticSourceLength else { return }

        let fullRendered = SinhalaEngine.transliterate(phoneticBuffer, mode: mode)
        let latestPrefixLength = sourceLength - maximumMarkedPhoneticSourceLength
        for prefixLength in stride(from: latestPrefixLength, through: 1, by: -1) {
            let split = phoneticBuffer.index(phoneticBuffer.startIndex, offsetBy: prefixLength)
            let prefix = String(phoneticBuffer[..<split])
            let suffix = String(phoneticBuffer[split...])
            let renderedPrefix = SinhalaEngine.transliterate(prefix, mode: mode)
            let renderedSuffix = SinhalaEngine.transliterate(suffix, mode: mode)
            guard renderedPrefix + renderedSuffix == fullRendered else { continue }

            // Replace the current active range with a committed prefix and a
            // small new suffix. This happens once per chunk, not per
            // keystroke, and keeps input responsive in heavy host editors.
            committedPhoneticSegments.append((source: prefix, rendered: renderedPrefix))
            phoneticBuffer = suffix
            
            if lastPhoneticRendered.hasPrefix(renderedPrefix) {
                lastPhoneticRendered = String(lastPhoneticRendered.dropFirst(renderedPrefix.count))
            } else {
                lastPhoneticRendered = ""
            }
            return
        }
    }

    /// A backspace can cross a committed phonetic chunk. Re-open just that
    /// final chunk so the deletion retains the same transliteration behavior
    /// as it had while the whole word was marked.
    private func restorePreviousPhoneticSegmentAfterDelete() {
        for _ in lastPhoneticRendered.unicodeScalars { textDocumentProxy.deleteBackward() }
        lastPhoneticRendered = ""
        
        guard var segment = committedPhoneticSegments.popLast() else {
            updatePredictions(for: "")
            return
        }
        for _ in segment.rendered.unicodeScalars { textDocumentProxy.deleteBackward() }
        segment.source.removeLast()
        phoneticBuffer = segment.source
        if phoneticBuffer.isEmpty {
            updatePredictions(for: committedPhoneticSegments.map(\.rendered).joined())
        } else {
            updatePhoneticComposition()
        }
    }

    private func commitActiveComposition() {
        if !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty {
            commitPhoneticComposition()
        }
        commitMarkedComposition()
    }

    private func commitMarkedComposition(suffix: String = "") {
        guard let source = markedSource else { return }
        let rendered = SinhalaEngine.transliterate(source, mode: mode)
        // Explicitly clear just the active composition before committing it.
        // Some host fields append `insertText` after a selected marked range,
        // producing a duplicate (for example, තේ තේ) instead of replacing it.
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.insertText(rendered + suffix)
        rawBuffer += source
        visibleEntries.append(rendered)
        visibleSources.append(source)
        markedSource = nil
        markedKind = nil
    }

    private func clearMarkedComposition() {
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
        markedSource = nil
        markedKind = nil
    }

    private func insertRendered(_ source: String) {
        let rendered = SinhalaEngine.transliterate(source, mode: mode)
        rawBuffer += source
        visibleEntries.append(rendered)
        visibleSources.append(source)
        textDocumentProxy.insertText(rendered)
        updatePredictions(for: visibleEntries.joined())
    }

    private func containsConsonant(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0D9A...0x0DC6).contains($0.value) }
    }

    private func canExtendPrebase(_ source: String, with suffix: String) -> Bool {
        let scalars = Array(source.unicodeScalars)
        guard scalars.first?.value == 0x0DD9 else { return false }
        let prebaseCount = scalars.prefix { $0.value == 0x0DD9 }.count
        let hasConsonant = scalars.contains { (0x0D9A...0x0DC6).contains($0.value) }
        if !hasConsonant {
            return (suffix == "ෙ" && prebaseCount < 2) || isSinhalaConsonant(suffix)
        }
        // After a single kombuwa and a base, a trailing key can produce
        // කේ, කො, කෞ, or (after කො) කෝ.
        guard prebaseCount == 1 else { return false }
        if scalars.count == 2 { return ["්", "ා", "ෟ"].contains(suffix) }
        if scalars.count == 3, scalars[2].value == 0x0DCF { return suffix == "්" }
        return false
    }

    private func isSinhalaConsonant(_ text: String) -> Bool {
        text.unicodeScalars.first.map { (0x0D9A...0x0DC6).contains($0.value) } ?? false
    }

    private func isIndependentVowel(_ text: String) -> Bool {
        text.unicodeScalars.first.map { (0x0D85...0x0D96).contains($0.value) } ?? false
    }

    private func combinesWithIndependentVowel(_ source: String, suffix: String) -> Bool {
        guard let vowel = source.unicodeScalars.first,
              let sign = suffix.unicodeScalars.first else { return false }
        switch vowel.value {
        case 0x0D85: return [0x0DCF, 0x0DD0, 0x0DD1].contains(sign.value) // අා/ැ/ෑ
        case 0x0D91: return sign.value == 0x0DCA // එ්
        case 0x0D89: return sign.value == 0x0DD3 // ඉී
        case 0x0D94: return [0x0DCA, 0x0DDF, 0x0DD6].contains(sign.value) // ඔ්/ෞ/ූ
        case 0x0D8B: return [0x0DDF, 0x0DD6].contains(sign.value) // උෞ/ූ
        case 0x0D8D: return sign.value == 0x0DD8 // ඍෘ
        default: return false
        }
    }

    /// Matches the standard iOS double-space shortcut: the second tap turns
    /// the prior space into a period followed by one ready for the next word.
    private func insertSpace() {
        let now = CACurrentMediaTime()
        let isDoubleSpace = rawBuffer.isEmpty && (lastSpaceTimestamp.map { now - $0 < 0.45 } ?? false)
        if isDoubleSpace {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpaceTimestamp = nil
            return
        }

        commit(suffix: " ")
        lastSpaceTimestamp = now
    }

}
