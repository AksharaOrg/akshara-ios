import UIKit

/// A small UIKit key control tuned for the system keyboard's dense, tactile feel.
private final class NativeKeyButton: UIButton {
    // A light impact is effectively imperceptible through many iPhone cases.
    // Medium remains brief, but is reliably tactile on physical hardware.
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let isUtility: Bool
    private var longPressWasHandled = false
    /// Called by the controller to mirror the system keyboard's character
    /// preview without making the key itself jump under the finger.
    var highlightChanged: ((NativeKeyButton, Bool) -> Void)?

    init(title: String?, symbol: String? = nil, utility: Bool = false) {
        self.isUtility = utility
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel?.font = .systemFont(ofSize: utility ? 19 : 22, weight: .regular)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        setTitle(title, for: .normal)
        setTitleColor(.label, for: .normal)
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
        layer.cornerRadius = 5
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
    private enum Layer { case letters, symbols }
    private var layer: Layer = .letters
    private var shift = false
    private var rawBuffer = ""
    private var visibleEntries: [String] = []
    private var visibleSources: [String] = []
    private enum MarkedCompositionKind { case prebase, independentVowel }
    private var markedSource: String?
    private var markedKind: MarkedCompositionKind?
    private var mode: SinhalaEngine.Mode = .sls
    private var lastSpaceTimestamp: TimeInterval?
    private let keyboardStack = UIStackView()
    private let trackpadSurface = UIView()
    private var deleteRepeater: Timer?
    private var keyPreview: KeyPreviewView?
    private var alternatePicker: AlternateCharacterPickerView?
    private let alternateSelectionFeedback = UISelectionFeedbackGenerator()
    private var spaceTrackpadStartX: CGFloat = 0
    private var spaceTrackpadOffset = 0
    private let cursorSelectionFeedback = UISelectionFeedbackGenerator()

    var enableInputClicksWhenVisible: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Match the dark system keyboard chrome so the extension flows into
        // iOS's own input-mode / dictation footer without a visible seam.
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
                : UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)
        }
        configureLayout()
        mode = KeyboardPreferences.selectedMode()
        rebuildKeys()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let selectedMode = KeyboardPreferences.selectedMode()
        guard selectedMode != mode else { return }
        commitMarkedComposition()
        mode = selectedMode
        rebuildKeys()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDeleteRepeat()
        hideKeyPreview(animated: false)
        hideAlternatePicker()
        setTrackpadAppearance(active: false, animated: false)
    }

    private func configureLayout() {
        keyboardStack.axis = .vertical; keyboardStack.spacing = 8; keyboardStack.distribution = .fillEqually
        keyboardStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardStack)
        NSLayoutConstraint.activate([
            keyboardStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            keyboardStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            keyboardStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            keyboardStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 204)
        ])
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
        // Four 41–42 pt rows match the compact Sinhala system layout more
        // closely than the previous 44–45 pt rows.
        preferredContentSize = CGSize(width: 0, height: 204)
    }

    private func rebuildKeys() {
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let bottom = needsInputModeSwitchKey ? ["123", "globe", "space", "return"] : ["123", "space", "return"]
        // The native Sinhala reference uses three even 11-key rows. Preserve
        // that geometry while exposing the full direct Wijesekara layer.
        let rows: [[String]] = layer == .letters
            ? [["q","w","e","r","t","y","u","i","o","p","["], ["a","s","d","f","g","h","j","k","l",";"], ["shift","rakaranshaya","x","c","v","b","n","m",",",".","delete"], bottom]
            : [["1","2","3","4","5","6","7","8","9","0"], ["-","/",":",";","(",")","$","&","@","\""], ["#+=",".",",","?","!","kundaliya","delete"], bottom.map { $0 == "123" ? "ABC" : $0 }]
        for (index, row) in rows.enumerated() { keyboardStack.addArrangedSubview(makeRow(row, index: index)) }
    }

    private func makeRow(_ keys: [String], index: Int) -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 6; row.alignment = .fill
        let isBottom = index == 3
        row.distribution = (isBottom || index == 2) ? .fill : .fillEqually
        if index == 2 { row.layoutMargins = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2); row.isLayoutMarginsRelativeArrangement = true }
        var letterButtons: [NativeKeyButton] = []
        for keyName in keys {
            let button = makeKey(keyName)
            row.addArrangedSubview(button)
            if isBottom {
                switch keyName {
                case "123", "ABC": button.widthAnchor.constraint(equalToConstant: 56).isActive = true
                case "globe": button.widthAnchor.constraint(equalToConstant: 46).isActive = true
                case "return": button.widthAnchor.constraint(equalToConstant: 72).isActive = true
                default: break
                }
            } else if index == 2 && keyName == "shift" {
                button.widthAnchor.constraint(equalToConstant: 31).isActive = true
            } else if index == 2 && keyName == "delete" {
                button.widthAnchor.constraint(equalToConstant: 45).isActive = true
            } else if index == 2 {
                letterButtons.append(button)
            }
        }
        for button in letterButtons.dropFirst() { button.widthAnchor.constraint(equalTo: letterButtons[0].widthAnchor).isActive = true }
        return row
    }

    private func makeKey(_ key: String) -> NativeKeyButton {
        let utility = ["shift", "delete", "123", "ABC", "#+=", "globe", "return"].contains(key)
        let button = NativeKeyButton(title: title(for: key), symbol: symbol(for: key), utility: utility)
        if key == "space" {
            // System keyboards keep the current input method unobtrusive in
            // the generous space key rather than treating it like a letter.
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
            button.titleLabel?.minimumScaleFactor = 0.8
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
            commitMarkedComposition()
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
        let preview = keyPreview ?? KeyPreviewView()
        if preview.superview == nil {
            view.addSubview(preview)
            keyPreview = preview
            preview.alpha = 0
        }
        let keyFrame = button.convert(button.bounds, to: view)
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
            case .smartPhonetic: return "අක්ෂර Smart"
            }
        }
        if ["shift", "delete", "globe", "return"].contains(key) { return nil }
        if key == "rakaranshaya" { return shift ? "ZWJ" : "්‍ර" }
        if key == "kundaliya" { return "෴" }
        if key == "yansaya" { return "්‍ය" }
        if key == "h", shift { return "්‍ය" }
        guard key.count == 1, layer == .letters else { return key }
        return mode == .sls ? SinhalaEngine.slsKeyLabel(key, shifted: shift) : (shift ? key.uppercased() : key)
    }

    private func press(_ key: String) {
        UIDevice.current.playInputClick()
        if key != "space" { lastSpaceTimestamp = nil }
        switch key {
        case "delete": deleteOnce()
        case "space": insertSpace()
        case "return": commit(suffix: "\n")
        case "globe": advanceToNextInputMode()
        case "shift": shift.toggle(); rebuildKeys()
        case "123", "ABC", "#+=": layer = layer == .letters ? .symbols : .letters; rebuildKeys()
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

    private func deleteOnce() {
        lastSpaceTimestamp = nil
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
        deleteRepeater = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
            self?.deleteRepeater = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.deleteOnce() }
        }
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
        if markedSource != nil {
            commitMarkedComposition(suffix: suffix)
            rawBuffer = ""
            visibleEntries.removeAll()
            visibleSources.removeAll()
            rebuildKeys()
            return
        }
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        textDocumentProxy.insertText(suffix); rebuildKeys()
    }

    /// Uses the system's marked-text session for multistage Sinhala input.
    /// The provisional glyph stays visible and is replaced in place until the
    /// next unrelated key commits it.
    private func insertLive(_ source: String) {
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
