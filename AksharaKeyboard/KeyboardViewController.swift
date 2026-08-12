import UIKit

/// A small UIKit key control tuned for the system keyboard's dense, tactile feel.
private final class NativeKeyButton: UIButton {
    // A light impact is effectively imperceptible through many iPhone cases.
    // Medium remains brief, but is reliably tactile on physical hardware.
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let isUtility: Bool
    private var longPressWasHandled = false
    private let hintLabel = UILabel()
    /// Called by the controller to mirror the system keyboard's character
    /// preview without making the key itself jump under the finger.
    var highlightChanged: ((NativeKeyButton, Bool) -> Void)?

    init(title: String?, hint: String? = nil, symbol: String? = nil, utility: Bool = false) {
        self.isUtility = utility
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel?.font = .systemFont(ofSize: utility ? 19 : 22, weight: .regular)
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
            imageView?.preferredSymbolConfiguration = .init(pointSize: 20, weight: .regular)
        }
        backgroundColor = UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return utility ? UIColor(white: 0.26, alpha: 1) : UIColor(white: 0.40, alpha: 1)
            }
            return utility ? UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) : .systemBackground
        }
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.23
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        addTarget(self, action: #selector(pressBegan), for: .touchDown)
    }

    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet {
            // System keys darken on contact; keeping their geometry fixed is
            // important for fast, consecutive taps.
            UIView.animate(withDuration: 0.055, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.transform = .identity
                self.alpha = self.isHighlighted ? 0.62 : 1
            }
            highlightChanged?(self, isHighlighted)
        }
    }

    /// The visible gap is six points wide. Claiming half of it on each side
    /// gives a forgiving target without overlapping a neighbouring key.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -3, dy: -4).contains(point)
    }

    @objc private func pressBegan() {
        guard KeyboardPreferences.hapticsEnabled() else { return }
        impact.prepare()
        impact.impactOccurred()
    }

    func markLongPressHandled() { longPressWasHandled = true }

    func consumeLongPressHandled() -> Bool {
        defer { longPressWasHandled = false }
        return longPressWasHandled
    }

    var isUtilityKey: Bool { isUtility }

    var supportsCharacterPreview: Bool {
        !isUtility && currentTitle != nil && currentTitle != " "
    }

    func collapseSpaceTitle() {
        guard currentTitle != nil else { return }
        // The input-method name arrives as a centred confirmation, then
        // settles into iOS's quiet lower-right language annotation.
        UIView.animate(
            withDuration: 0.58,
            delay: 0,
            usingSpringWithDamping: 0.92,
            initialSpringVelocity: 0.18,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.setTitleColor(.secondaryLabel, for: .normal)
            self.titleLabel?.font = .systemFont(ofSize: 11, weight: .regular)
            self.titleLabel?.alpha = 0.64
            self.titleLabel?.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            self.contentHorizontalAlignment = .right
            self.contentVerticalAlignment = .bottom
            self.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 7, right: 10)
            self.layoutIfNeeded()
        }
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

    static let flags: [String] = Locale.isoRegionCodes.compactMap { code in
        let code = code.uppercased()
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
}

/// POC corpus seed from laknath/Sinhala-Dictionary, used with the author's
/// permission. The production corpus can replace this list without changing
/// the ranking or keyboard UI.
private enum SinhalaPredictionEngine {
    private static let words = [
        "අංක", "අංකය", "අංකුර", "අපි", "අපිට", "අපේ", "අම්මා", "අම්මාගේ", "ආයුබෝවන්",
        "ඔබ", "ඔබගේ", "ඔබට", "කරනවා", "කියනවා", "කියන්න", "කොළඹ", "ගෙදර", "ගෙදරට",
        "චිත්‍ර", "තවත්", "දවස", "දෙන්න", "නම", "නැහැ", "පිටුව", "පාසල", "බලන්න",
        "මම", "මගේ", "මිතුරා", "ලංකා", "ලංකාවේ", "වචනය", "වෙන්න", "සතුට", "සිංහල",
        "සිංහලයා", "ස්තුතියි", "සුබ", "සුබපැතුම්", "හොඳ", "හෙලෝ"
    ]

    static func matches(prefix: String) -> [String] {
        guard prefix.count >= 1 else { return [] }
        return words.filter { $0.hasPrefix(prefix) && $0 != prefix }.prefix(3).map { $0 }
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

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 3
        layout.scrollDirection = .vertical
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 226 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1) }
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        searchField.placeholder = "Search Emoji"
        searchField.font = .systemFont(ofSize: 18)
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
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: item.symbolName), for: .normal)
            button.tintColor = .secondaryLabel
            button.setPreferredSymbolConfiguration(.init(pointSize: 19, weight: .regular), forImageIn: .normal)
            button.tag = EmojiCategory.allCases.firstIndex(of: item) ?? 0
            button.addTarget(self, action: #selector(selectCategory(_:)), for: .touchUpInside)
            categoryButtons[item] = button
            categoryStrip.addArrangedSubview(button)
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
        for (rowIndex, row) in [["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l"], ["⇧","z","x","c","v","b","n","m","⌫"], ["123","☺︎","space","Search"]].enumerated() {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.distribution = rowIndex == 0 ? .fillEqually : .fill
            if rowIndex == 1 {
                stack.layoutMargins = UIEdgeInsets(top: 0, left: 21, bottom: 0, right: 21)
                stack.isLayoutMarginsRelativeArrangement = true
            }
            var letterButtons: [UIButton] = []
            for key in row {
                let button = UIButton(type: .system)
                button.setTitle(key == "space" ? nil : key, for: .normal)
                button.setTitleColor(key == "Search" ? .white : .label, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 20)
                if key == "☺︎" { button.setImage(UIImage(systemName: "face.smiling"), for: .normal); button.tintColor = .label }
                if key == "Search" { button.setTitle(nil, for: .normal); button.setImage(UIImage(systemName: "checkmark"), for: .normal); button.tintColor = .white }
                button.backgroundColor = key == "Search" ? .systemBlue : (key == "⇧" || key == "⌫" || key == "123" ? UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) : .systemBackground)
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
                    case "123", "☺︎": button.widthAnchor.constraint(equalToConstant: 42).isActive = true
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
            searchKeyboard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            searchKeyboard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
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
        case "☺︎": endEmojiSearch(); return
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
        let catalog: [(String, String)] = [
            ("😀", "grinning happy smile"), ("😃", "smile happy"), ("😄", "smile happy"),
            ("😂", "laugh tears"), ("🥹", "smile tears"), ("😍", "heart eyes love"),
            ("😘", "kiss love"), ("😭", "cry sad tears"), ("❤️", "heart love"),
            ("👍", "thumbs up like"), ("👎", "thumbs down"), ("🙏", "pray thanks"),
            ("🎉", "party celebration"), ("🔥", "fire"), ("✅", "check done"), ("🚗", "car travel")
        ]
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty
            ? ["😐", "😀", "😃", "😁", "😄", "😆", "🥹", "😅"]
            : catalog.filter { $0.1.contains(query) }.map { $0.0 }
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
            rows = [["q","w","e","r","t","y","u","i","o","p"].map(letter), ["a","s","d","f","g","h","j","k","l"].map(letter), ["⇧","z","x","c","v","b","n","m","⌫"].map { $0.count == 1 ? letter($0) : $0 }, ["123","☺︎","space","Search"]]
        case .numbers:
            rows = [["1","2","3","4","5","6","7","8","9","0"], ["-","/",":",";","(",")","$","&","@"], ["#+=",".",",","?","!","'","(",")","⌫"], ["ABC","☺︎","space","Search"]]
        case .symbols:
            rows = [["[","]","{","}","#","%","^","*","+","="], ["_","\\","|","~","<",">","€","£","¥"], ["123",".",",","?","!","'","(",")","⌫"], ["ABC","☺︎","space","Search"]]
        }
        let keys = rows.flatMap { $0 }
        for (button, key) in zip(searchButtons, keys) {
            button.accessibilityIdentifier = key
            button.setImage(nil, for: .normal)
            button.setTitle(key == "space" ? nil : key, for: .normal)
            button.setTitleColor(key == "Search" ? .white : .label, for: .normal)
            button.tintColor = key == "Search" ? .white : .label
            if key == "☺︎" { button.setTitle(nil, for: .normal); button.setImage(UIImage(systemName: "face.smiling"), for: .normal) }
            if key == "Search" { button.setTitle(nil, for: .normal); button.setImage(UIImage(systemName: "checkmark"), for: .normal) }
            button.backgroundColor = key == "Search" ? .systemBlue : (["⇧", "⌫", "123", "ABC", "#+="].contains(key) ? UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) : .systemBackground)
        }
    }

    private func updateCategorySelection() {
        titleLabel.text = category.title
        for (item, button) in categoryButtons {
            let selected = item == category
            button.alpha = selected ? 1 : 0.48
            button.tintColor = selected ? .label : .secondaryLabel
            button.layer.cornerRadius = 16
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
    private var layer: Layer = .letters
    private var shift = false
    private var rawBuffer = ""
    private var phoneticBuffer = ""
    private var visibleEntries: [String] = []
    private var visibleSources: [String] = []
    private enum MarkedCompositionKind { case prebase, independentVowel }
    private var markedSource: String?
    private var markedKind: MarkedCompositionKind?
    private var mode: SinhalaEngine.Mode = .sls
    private var lastSpaceTimestamp: TimeInterval?
    private let keyboardStack = UIStackView()
    private let keyboardChrome = UIView()
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
    private let alternateSelectionFeedback = UISelectionFeedbackGenerator()
    private var spaceTrackpadStartX: CGFloat = 0
    private var spaceTrackpadOffset = 0
    private let cursorSelectionFeedback = UISelectionFeedbackGenerator()

    private var standardKeyboardHeight: CGFloat {
        KeyboardPreferences.suggestionsEnabled() ? 251 : 216
    }

    var enableInputClicksWhenVisible: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Match the dark system keyboard chrome so the extension flows into
        // iOS's own input-mode / dictation footer without a visible seam.
        view.backgroundColor = .clear
        keyboardChrome.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
                : UIColor(red: 226 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1)
        }
        keyboardChrome.translatesAutoresizingMaskIntoConstraints = false
        keyboardChrome.layer.cornerRadius = 24
        keyboardChrome.layer.cornerCurve = .continuous
        keyboardChrome.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        mode = KeyboardPreferences.selectedMode()
        configureLayout()
        rebuildKeys()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let selectedMode = KeyboardPreferences.selectedMode()
        if selectedMode != mode {
            commitActiveComposition()
            mode = selectedMode
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
        candidateBarHeight = candidateBar.heightAnchor.constraint(equalToConstant: 35)
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
            keyboardStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            keyboardStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            keyboardStack.topAnchor.constraint(equalTo: candidateBar.bottomAnchor, constant: 7),
            keyboardStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
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
        let suggestionsEnabled = KeyboardPreferences.suggestionsEnabled()
        candidateBarHeight?.constant = suggestionsEnabled ? 35 : 0
        candidateBar.isHidden = !suggestionsEnabled
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
        let bottom = ["123"] + emojiKey + globeKey + ["space", "return"]
        // The native Sinhala reference uses three even 11-key rows. Preserve
        // that geometry while exposing the full direct Wijesekara layer.
        let letterRows: [[String]] = mode == .sls
            ? [["q","w","e","r","t","y","u","i","o","p","["], ["a","s","d","f","g","h","j","k","l",";"], ["shift","rakaranshaya","x","c","v","b","n","m",",",".","delete"]]
            : [["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l"], ["shift","z","x","c","v","b","n","m","delete"]]
        let rows: [[String]]
        switch layer {
        case .letters:
            rows = letterRows + [bottom]
        case .numbers:
            rows = [["1","2","3","4","5","6","7","8","9","0"], ["-","/",":",";","(",")","$","&","@","\""], ["#+=",".",",","?","!","kundaliya","delete"], bottom.map { $0 == "123" ? "ABC" : $0 }]
        case .symbols:
            rows = [["[","]","{","}","#","%","^","*","+","="], ["_","\\","|","~","<",">","€","£","¥","•"], ["123",".",",","?","!","kundaliya","delete"], bottom.map { $0 == "123" ? "ABC" : $0 }]
        }
        for (index, row) in rows.enumerated() { keyboardStack.addArrangedSubview(makeRow(row, index: index)) }
    }

    private func makeRow(_ keys: [String], index: Int) -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 6; row.alignment = .fill
        let isBottom = index == 3
        let isEnglishAlphabet = layer == .letters && mode != .sls
        row.distribution = (isBottom || index == 2) ? .fill : .fillEqually
        if isEnglishAlphabet && index == 1 {
            row.layoutMargins = UIEdgeInsets(top: 0, left: 21, bottom: 0, right: 21)
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
                case "123", "ABC": button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 42 : 56).isActive = true
                case "emoji": button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 42 : 46).isActive = true
                case "globe": button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 42 : 46).isActive = true
                case "return": button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 92 : 72).isActive = true
                default: break
                }
            } else if index == 2 && keyName == "shift" {
                button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 42 : 31).isActive = true
            } else if index == 2 && keyName == "delete" {
                button.widthAnchor.constraint(equalToConstant: isEnglishAlphabet ? 42 : 31).isActive = true
            } else if index == 2 {
                letterButtons.append(button)
            }
        }
        for button in letterButtons.dropFirst() { button.widthAnchor.constraint(equalTo: letterButtons[0].widthAnchor).isActive = true }
        return row
    }

    private func makeKey(_ key: String) -> NativeKeyButton {
        let utility = ["shift", "delete", "123", "ABC", "#+=", "globe"].contains(key)
        let button = NativeKeyButton(title: title(for: key), hint: hint(for: key), symbol: symbol(for: key), utility: utility)
        if key == "space" {
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
            button.titleLabel?.minimumScaleFactor = 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak button] in
                button?.collapseSpaceTitle()
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
        button.addAction(UIAction { [weak self, weak button] _ in
            guard button?.consumeLongPressHandled() != true else { return }
            self?.press(key)
        }, for: .touchUpInside)
        if key == "delete" {
            button.addTarget(self, action: #selector(startDeleteRepeat), for: .touchDown)
            button.addTarget(self, action: #selector(stopDeleteRepeat), for: [.touchUpInside, .touchUpOutside, .touchCancel])
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
            cursorSelectionFeedback.prepare()
        case .changed:
            let movement = recognizer.location(in: view).x - spaceTrackpadStartX
            // Ten points per character feels controlled on compact keyboards
            // while still allowing a fast scrub across a word or sentence.
            let targetOffset = Int(movement / 10)
            let delta = targetOffset - spaceTrackpadOffset
            guard delta != 0 else { return }
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
            spaceTrackpadOffset = targetOffset
            cursorSelectionFeedback.selectionChanged()
            cursorSelectionFeedback.prepare()
        case .ended, .cancelled, .failed:
            spaceTrackpadOffset = 0
            setTrackpadAppearance(active: false)
        default:
            break
        }
    }

    private func setTrackpadAppearance(active: Bool, animated: Bool = true) {
        let changes = { self.trackpadSurface.alpha = active ? 1 : 0 }
        guard animated else { changes(); return }
        UIView.animate(withDuration: active ? 0.12 : 0.09, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes)
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
        let previewSize = CGSize(width: min(max(keyFrame.width + 26, 54), 64), height: keyFrame.height + 47)
        let minX = view.bounds.minX + 2
        let maxX = view.bounds.maxX - previewSize.width - 2
        let x = min(max(keyFrame.midX - previewSize.width / 2, minX), maxX)
        // The bottom geometry retains the exact key width. For edge keys,
        // shift the stem within the clamped upper chamber to stay aligned.
        preview.configure(lowerWidth: keyFrame.width, lowerCenterX: keyFrame.midX - x, lowerHeight: keyFrame.height)
        preview.frame = CGRect(x: x, y: max(0, keyFrame.minY - 47), width: previewSize.width, height: previewSize.height)
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
        if ["shift", "delete", "emoji", "globe", "return"].contains(key) { return nil }
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
        case "shift": shift.toggle(); rebuildKeys()
        case "123": layer = .numbers; rebuildKeys()
        case "#+=": layer = .symbols; rebuildKeys()
        case "ABC": layer = .letters; rebuildKeys()
        case "rakaranshaya":
            insertLive(shift ? "\u{200D}" : "\u{E004}")
            if shift { shift = false }
            rebuildKeys()
        case "kundaliya": commit(suffix: "෴")
        case "yansaya": insertLive("\u{E005}"); rebuildKeys()
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
        keyboardMinimumHeight.constant = 251
        preferredContentSize = CGSize(width: 0, height: 251)
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
        candidateBar.isHidden = !KeyboardPreferences.suggestionsEnabled()
        keyboardStack.isHidden = false
        keyboardMinimumHeight.constant = standardKeyboardHeight
        preferredContentSize = CGSize(width: 0, height: standardKeyboardHeight)
    }

    private func updatePredictions(for prefix: String) {
        guard KeyboardPreferences.suggestionsEnabled() else {
            predictionPrefix = ""
            candidates = [nil, nil, nil]
            candidateButtons.forEach { $0.setTitle(nil, for: .normal); $0.isEnabled = false }
            return
        }
        predictionPrefix = prefix
        let ranked = SinhalaPredictionEngine.matches(prefix: prefix)
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
        if !phoneticBuffer.isEmpty {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            phoneticBuffer = ""
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
        textDocumentProxy.insertText(candidate)
        predictionPrefix = ""
        candidates = [nil, nil, nil]
        candidateButtons.forEach { $0.setTitle(nil, for: .normal); $0.isEnabled = false }
    }

    private func deleteOnce() {
        lastSpaceTimestamp = nil
        if !phoneticBuffer.isEmpty {
            phoneticBuffer.removeLast()
            if phoneticBuffer.isEmpty {
                clearPhoneticComposition()
            } else {
                updatePhoneticComposition()
            }
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
        }
        rebuildKeys()
    }

    @objc private func startDeleteRepeat() {
        deleteRepeater?.invalidate()
        let initialDelay = Timer(timeInterval: 0.42, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deleteOnce()
            let repeater = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.deleteOnce() }
            self.deleteRepeater = repeater
            RunLoop.main.add(repeater, forMode: .common)
        }
        deleteRepeater = initialDelay
        RunLoop.main.add(initialDelay, forMode: .common)
    }

    @objc private func stopDeleteRepeat() { deleteRepeater?.invalidate(); deleteRepeater = nil }

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
            alternateSelectionFeedback.selectionChanged()
            alternateSelectionFeedback.prepare()
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
        let size = CGSize(width: 60, height: 60)
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
        if !phoneticBuffer.isEmpty {
            commitPhoneticComposition(suffix: suffix)
            updatePredictions(for: "")
            rebuildKeys()
            return
        }
        if markedSource != nil {
            commitMarkedComposition(suffix: suffix)
            rawBuffer = ""
            visibleEntries.removeAll()
            visibleSources.removeAll()
            updatePredictions(for: "")
            rebuildKeys()
            return
        }
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        updatePredictions(for: "")
        textDocumentProxy.insertText(suffix); rebuildKeys()
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
        updatePredictions(for: rendered)
    }

    private func updatePhoneticComposition() {
        let rendered = SinhalaEngine.transliterate(phoneticBuffer, mode: mode)
        let caret = (rendered as NSString).length
        textDocumentProxy.setMarkedText(rendered, selectedRange: NSRange(location: caret, length: 0))
        updatePredictions(for: rendered)
    }

    private func commitPhoneticComposition(suffix: String = "") {
        guard !phoneticBuffer.isEmpty else { return }
        let rendered = SinhalaEngine.transliterate(phoneticBuffer, mode: mode)
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.insertText(rendered + suffix)
        phoneticBuffer = ""
        updatePredictions(for: "")
    }

    private func clearPhoneticComposition() {
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
        phoneticBuffer = ""
        updatePredictions(for: "")
    }

    private func commitActiveComposition() {
        if !phoneticBuffer.isEmpty {
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
        updatePredictions(for: predictionPrefix + rendered)
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
            rebuildKeys()
            return
        }

        commit(suffix: " ")
        lastSpaceTimestamp = now
    }

}
