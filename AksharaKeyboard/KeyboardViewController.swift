import UIKit
import OSLog

/// Keyboard chrome follows KeyboardKit and the system keyboard's split of
/// responsibility — not host sniffing.
///
/// The system keyboard is UIKit chrome in the *host* process. It automatically
/// matches that app's `UIDesignRequiresCompatibility` (glass in Messages,
/// classic in un-updated apps). A third-party extension is a different
/// process. Apple has no public API for the host's design mode; WebKit has to
/// IPC `isLiquidGlassEnabled` from the UI process into WebContent for the
/// same reason. `Bundle.main`'s Info.plist is the extension, not the host.
/// Host bundle-ID SPIs broke in iOS 26.4. Geometry ("no glass lip") misfires
/// on iMessage, which is glass without extra height or glass class names.
///
/// SwiftKey / Gboard stay visually consistent across apps. Reviews recommend
/// them *because* the system keyboard changes per host. They keep a clear
/// canvas so the host-drawn tray (glass capsule or classic card) shows
/// through, and style keys from the OS version.
///
/// KeyboardKit does the same: `isLiquidGlassEnabled` is OS major > 18,
/// `KeyboardViewStyle.background` is nil, and `UIInputView.keyboard` is
/// skipped (it tints a second backdrop and reads as a card in Spotlight).
/// Do not infer classic from a matching height: iMessage's glass lip is the
/// host capsule, and this view is pinned to the key strip so extra ≈ 0 there
/// too. Classic Host still draws its own tray; use Keyboard Chrome → Classic
/// to force Akshara’s pre-glass keys.
private enum KeyboardChromeAppearance {
    static var usesLiquidGlassSurfaces: Bool = {
        if #available(iOS 26.0, *) { return true }
        return false
    }()
}

/// Leftover A/L/Z/M tap diagnostics. Filter Console.app / Xcode for `AKSHARA-HIT`
/// on the **AksharaKeyboard** process (the extension, not the host app).
private enum KeyboardHitTrace {
    static let leftoverKeys: Set<String> = ["a", "l", "z", "m"]
    /// Opt-in diagnostics only. Console I/O in `hitTest` makes fast typing
    /// noticeably less responsive, even in an otherwise optimised build.
    static let isEnabled = ProcessInfo.processInfo.environment["AKSHARA_HIT_TRACE"] == "1"
    private static let logger = Logger(subsystem: "lk.org.akshara.keyboard", category: "HitTest")
    private static var lastHitMessage = ""
    private static var lastHitTime: CFTimeInterval = 0

    static func isTraced(_ key: String) -> Bool { leftoverKeys.contains(key) }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let message = message()
        logger.notice("\(message, privacy: .public)")
        NSLog("[AKSHARA-HIT] %@", message)
    }

    static func logHit(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let message = message()
        let now = CACurrentMediaTime()
        if message == lastHitMessage, now - lastHitTime < 0.08 { return }
        lastHitMessage = message
        lastHitTime = now
        log(message)
    }

    static func fmt(_ point: CGPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    static func fmt(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    static func fmt(_ insets: UIEdgeInsets) -> String {
        String(format: "L%.1f R%.1f", insets.left, insets.right)
    }
}

/// Isolated so iOS 16 does not dyld-crash on `UICornerConfiguration`.
/// Putting those types on always-available methods was enough for the
/// keyboard extension to abort and switch back to the system keyboard.
@available(iOS 26.0, *)
private enum LiquidGlassCornerStyle {
    static var topCapsule: UICornerConfiguration {
        let top = UICornerRadius.containerConcentric(minimum: 8)
        let square = UICornerRadius.fixed(0)
        return .corners(
            topLeftRadius: top,
            topRightRadius: top,
            bottomLeftRadius: square,
            bottomRightRadius: square
        )
    }

    static func applyTopCapsule(to view: UIView, clipOverlay: Bool = false) {
        view.cornerConfiguration = topCapsule
        if clipOverlay {
            view.clipsToBounds = true
        }
    }

    static func reset(to view: UIView) {
        let square = UICornerRadius.fixed(0)
        view.cornerConfiguration = .corners(
            topLeftRadius: square,
            topRightRadius: square,
            bottomLeftRadius: square,
            bottomRightRadius: square
        )
        view.clipsToBounds = false
    }
}

/// Keeps the generators alive for the lifetime of the keyboard. Apple recommends
/// preparing a generator before its event, then preparing it again after firing
/// when another event may follow soon. A keyboard is exactly that interaction.
private final class KeyFeedback {
    private let impact: UIImpactFeedbackGenerator
    private let selection: UISelectionFeedbackGenerator
    private var prepareWorkItem: DispatchWorkItem?
    /// Re-arm the Taptic Engine after typing pauses, not after every letter in
    /// a burst — continuous prepare() contention is a common source of lag.
    private let prepareIdleDelay: TimeInterval = 0.05

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
        guard KeyboardPreferences.hotPath.hapticsEnabled else { return }
        prepareWorkItem?.cancel()
        prepareWorkItem = nil
        impact.prepare()
        selection.prepare()
    }

    func keyPressed() {
        let prefs = KeyboardPreferences.hotPath
        guard prefs.hapticsEnabled else { return }
        // Intensity is snapshotted with the rest of the hot-path prefs so this
        // never opens the App Group suite on a keypress.
        impact.impactOccurred(intensity: CGFloat(prefs.hapticIntensity))
        scheduleIdlePrepare()
    }

    func selectionChanged() {
        guard KeyboardPreferences.hotPath.hapticsEnabled else { return }
        selection.selectionChanged()
        scheduleIdlePrepare()
    }

    /// One extra tick after the key-down impact, so the spacebar wink reads as
    /// a confirmation rather than another letter.
    func signatureWink() {
        guard KeyboardPreferences.hotPath.hapticsEnabled else { return }
        selection.selectionChanged()
        scheduleIdlePrepare()
    }

    private func scheduleIdlePrepare() {
        prepareWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, KeyboardPreferences.hotPath.hapticsEnabled else { return }
            self.impact.prepare()
            self.selection.prepare()
            self.prepareWorkItem = nil
        }
        prepareWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + prepareIdleDelay, execute: work)
    }
}

private final class AlwaysHitLayer: CALayer {
    override func hitTest(_ p: CGPoint) -> CALayer? {
        bounds.contains(p) ? self : nil
    }

    override func contains(_ p: CGPoint) -> Bool {
        bounds.contains(p)
    }
}

/// Fills a key's layout item, including KeyboardKit-style leftover beside
/// the painted cap. iOS 26 does not deliver taps to fully clear pixels, so
/// this view keeps a near-invisible fill in the leftover.
private final class KeyHitFillView: UIView {
    override class var layerClass: AnyClass { AlwaysHitLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}

/// A small UIKit key control tuned for the system keyboard's dense, tactile feel.
private final class NativeKeyButton: UIButton {
    private let isUtility: Bool
    private var longPressWasHandled = false
    private let hintLabel = UILabel()
    /// Stable key identity for in-place Shift updates without rebuilding rows.
    let keyName: String
    /// Called by the controller to mirror the system keyboard's character
    /// preview without making the key itself jump under the finger.
    var highlightChanged: ((NativeKeyButton, Bool) -> Void)?
    /// Fired at touch-down, which is when keyboard feedback needs to occur.
    var touchDown: (() -> Void)?
    /// Authoritative lift. Keyboard hosts often omit `touchUpInside` after a
    /// `deleteBackward` round-trip, so Delete repeat cannot rely on UIControl
    /// events alone.
    var touchEnded: (() -> Void)?
    /// Finger may still be down: a host text change commonly cancels the
    /// original touch. Delete repeat treats this as a possible glitch, not
    /// a lift, until a short grace window expires.
    var touchCancelled: (() -> Void)?
    /// A long press owns the visual feedback after it begins. Keeping this on
    /// the control avoids UIKit highlight transitions resurrecting the normal
    /// character preview behind an alternate picker.
    var suppressesCharacterPreview = false
    /// Extra points around the cap while this control is tracking. Delete
    /// needs a wide slop so a held finger can settle without UIKit treating
    /// the touch as having left the key.
    var trackingHitOutset: CGFloat = 4
    /// KeyboardKit `edgeInsets`: leftover is part of this control's bounds;
    /// only the painted cap is inset (A / L / Z / M).
    private(set) var capInsets: UIEdgeInsets = .zero
    private let capView = UIView()
    private let hitFill = KeyHitFillView()
    private let keycapFill: UIColor
    private var hintTop: NSLayoutConstraint!
    private var hintTrailing: NSLayoutConstraint!

    private var usesIOS16KeyboardAppearance: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    /// KeyboardKit uses liquid keycaps whenever the OS enables Liquid Glass.
    private var usesIOS26KeyboardAppearance: Bool {
        KeyboardChromeAppearance.usesLiquidGlassSurfaces
    }

    init(keyName: String, title: String?, hint: String? = nil, symbol: String? = nil, utility: Bool = false) {
        self.keyName = keyName
        self.isUtility = utility
        self.keycapFill = UIColor { traits in
            let highContrast = KeyboardPreferences.hotPath.highContrastEnabled
            let liquidGlass = KeyboardChromeAppearance.usesLiquidGlassSurfaces
            let greyUtility = utility && (!liquidGlass || highContrast)
            if traits.userInterfaceStyle == .dark {
                if liquidGlass {
                    let opacity: CGFloat = greyUtility
                        ? 0.24
                        : (highContrast ? 0.30 : 0.18)
                    return UIColor(red: 0.90, green: 0.96, blue: 0.96, alpha: opacity)
                }
                // KeyboardKit / Grammarly: white at 0.3 (letters) and 0.1
                // (utility) so dark mode, dark appearance, and translucent
                // hosts share one surface. Opaque grey keys still read as a
                // solid card in Spotlight.
                if highContrast {
                    return greyUtility
                        ? UIColor(white: 1, alpha: 0.18)
                        : UIColor(white: 1, alpha: 0.42)
                }
                return greyUtility
                    ? UIColor(white: 1, alpha: 0.10)
                    : UIColor(white: 1, alpha: 0.30)
            }
            if #unavailable(iOS 17.0) {
                return greyUtility
                    ? UIColor(red: 190 / 255, green: 193 / 255, blue: 202 / 255, alpha: 1)
                    : .white
            }
            if !liquidGlass {
                return greyUtility
                    ? UIColor(red: highContrast ? 0.60 : 0.71, green: highContrast ? 0.62 : 0.73, blue: highContrast ? 0.67 : 0.77, alpha: 1)
                    : .systemBackground
            }
            return greyUtility
                ? UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
                : .systemBackground
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = keyName
        titleLabel?.font = .systemFont(ofSize: utility ? 18 : 22, weight: glyphFontWeight)
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
        capView.isUserInteractionEnabled = false
        capView.isHidden = true
        capView.layer.cornerCurve = .continuous
        capView.layer.shadowColor = UIColor.black.cgColor
        capView.layer.shadowOffset = CGSize(width: 0, height: 1)
        capView.layer.shadowRadius = 0
        hitFill.isUserInteractionEnabled = false
        insertSubview(hitFill, at: 0)
        insertSubview(capView, at: 1)
        addSubview(hintLabel)
        hintTop = hintLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3)
        hintTrailing = hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        NSLayoutConstraint.activate([hintTop, hintTrailing])
        if let symbol {
            setImage(UIImage(systemName: symbol), for: .normal)
            tintColor = .label
            imageView?.preferredSymbolConfiguration = .init(pointSize: 20, weight: glyphSymbolWeight)
        }
        backgroundColor = keycapFill
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        showsTouchWhenHighlighted = false
        adjustsImageWhenHighlighted = false
        applyKeycapChrome(isPad: false)
        addTarget(self, action: #selector(pressBegan), for: .touchDown)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        hitFill.frame = bounds
        if capInsets != .zero {
            capView.frame = bounds.inset(by: capInsets)
        }
        guard keyName == "space", let titleLabel else { return }
        // UIButton sizes the title to its text. A long Wijesekara caption
        // or the signature phrase can otherwise draw past the keycap.
        let inset = bounds.inset(by: contentEdgeInsets).insetBy(dx: 6, dy: 1)
        guard inset.width > 1, inset.height > 1 else { return }
        var frame = titleLabel.frame
        if frame.width > inset.width {
            frame.size.width = inset.width
            switch contentHorizontalAlignment {
            case .right:
                frame.origin.x = inset.maxX - frame.width
            case .left:
                frame.origin.x = inset.minX
            default:
                frame.origin.x = inset.midX - frame.width / 2
            }
        } else {
            frame.origin.x = min(max(frame.origin.x, inset.minX), inset.maxX - frame.width)
        }
        frame.origin.y = min(max(frame.origin.y, inset.minY), max(inset.minY, inset.maxY - frame.height))
        titleLabel.frame = frame
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        refreshDynamicColors()
        applyKeycapChrome(isPad: traitCollection.userInterfaceIdiom == .pad)
    }

    /// UIButton can keep a resolved cap colour across appearance changes.
    /// Re-assigning the dynamic colour forces it to match the new traits.
    func refreshDynamicColors() {
        if capInsets != .zero {
            capView.backgroundColor = nil
            capView.backgroundColor = keycapFill
        } else {
            let cap = backgroundColor
            backgroundColor = nil
            backgroundColor = cap
        }
        tintColor = tintColor
    }

    override var isHighlighted: Bool {
        didSet {
            // Update synchronously. Two UIView animations for every letter
            // create needless main-thread churn during rapid typing, while
            // the system keyboard's pressed state should feel immediate.
            transform = .identity
            alpha = isHighlighted ? 0.62 : 1
            highlightChanged?(self, isHighlighted)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isTracking {
            return bounds.insetBy(dx: -trackingHitOutset, dy: -trackingHitOutset).contains(point)
        }
        return true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        let hit = bounds.contains(point) ? self : nil
        if KeyboardHitTrace.isTraced(keyName) {
            let inCap = bounds.inset(by: capInsets).contains(point)
            KeyboardHitTrace.logHit(
                "btn \(keyName) hitTest pt=\(KeyboardHitTrace.fmt(point)) boundsContains=\(bounds.contains(point)) inCap=\(inCap) leftover=\(!inCap && capInsets != .zero) -> \(hit == nil ? "nil" : "self")"
            )
        }
        return hit
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if KeyboardHitTrace.isTraced(keyName), let touch = touches.first {
            let local = touch.location(in: self)
            let inCap = bounds.inset(by: capInsets).contains(local)
            KeyboardHitTrace.log(
                "btn \(keyName) touchesBegan loc=\(KeyboardHitTrace.fmt(local)) inCap=\(inCap) leftover=\(!inCap && capInsets != .zero) insets=\(KeyboardHitTrace.fmt(capInsets))"
            )
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touchEnded?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchCancelled?()
    }

    @objc private func pressBegan() {
        KeyboardHitTrace.log(
            "btn \(keyName) touchDown/pressBegan insets=\(KeyboardHitTrace.fmt(capInsets))"
        )
        // Haptic must win the touch-down turn before preview or composition.
        touchDown?()
    }

    func markLongPressHandled() { longPressWasHandled = true }

    func consumeLongPressHandled() -> Bool {
        defer { longPressWasHandled = false }
        return longPressWasHandled
    }

    func setHint(_ hint: String?, animated: Bool = false) {
        let apply = {
            self.hintLabel.text = hint
            self.hintLabel.isHidden = hint == nil
            self.hintLabel.alpha = hint == nil ? 0 : 1
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        if hint == nil {
            // Keep the current glyph visible while it fades, then clear.
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.hintLabel.alpha = 0
            } completion: { finished in
                guard finished else { return }
                self.hintLabel.text = nil
                self.hintLabel.isHidden = true
            }
        } else {
            hintLabel.text = hint
            hintLabel.isHidden = false
            hintLabel.alpha = 0
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.hintLabel.alpha = 1
            }
        }
    }

    /// A pending kombuwa already appears in the host. The ring/chip is only
    /// a fallback if that insert has not landed yet.
    func setCompositionPending(_ pending: Bool) {
        if pending {
            layer.borderWidth = 1.5
            layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = UIColor.clear.cgColor
        }
    }

    /// Full-width iPads use materially larger keycaps than phones. Keep that
    /// tuning on the reusable key rather than letting each row invent fonts
    /// and corner radii independently.
    func applyLayoutMetrics(isPad: Bool) {
        let titleSize: CGFloat = isPad ? (isUtility ? 22 : 28) : (isUtility ? 18 : 22)
        titleLabel?.font = .systemFont(ofSize: titleSize, weight: glyphFontWeight)
        // Phonetic Sinhala hints must remain secondary, but 9 pt becomes too
        // faint on modern phone displays. Keep the hierarchy while improving
        // recognition during fast touch typing.
        hintLabel.font = .systemFont(ofSize: isPad ? 12 : 10, weight: .regular)
        applyKeycapChrome(isPad: isPad)
        applyCharacterEdgeInsets(capInsets)
        if let imageView {
            imageView.preferredSymbolConfiguration = .init(
                pointSize: isPad ? 23 : 20,
                weight: glyphSymbolWeight
            )
        }
    }

    /// Latin UK caps on iOS 26 run a touch heavier than `.regular`. Sinhala
    /// letterforms (Wijesekara and both phonetic layouts) fill in at `.medium`
    /// and look bolder than Apple's Sinhala keyboard, so letters stay
    /// `.regular`. Symbols can still follow the native iOS 26 weight.
    private var glyphFontWeight: UIFont.Weight {
        if isUtility { return .medium }
        return .regular
    }

    private var glyphSymbolWeight: UIImage.SymbolWeight {
        if usesIOS26KeyboardAppearance { return .medium }
        return isUtility ? .medium : .regular
    }

    /// Liquid Glass keycaps are rounder and sit on the material, not above it.
    /// KeyboardKit uses 9 pt and no shadow when glass is on; older iOS keeps
    /// the raised 7–8 pt (phone) / 8–10 pt (iPad) caps.
    private func applyKeycapChrome(isPad: Bool) {
        let target = capInsets != .zero ? capView.layer : layer
        if usesIOS26KeyboardAppearance {
            target.cornerRadius = 9
            target.shadowOpacity = 0
            if capInsets != .zero { layer.shadowOpacity = 0 }
            return
        }
        target.cornerRadius = isPad ? (isUtility ? 10 : 8) : (isUtility ? 8 : 7)
        // Transparent dark caps cannot use the raised key shadow: it draws
        // under the key and muddies the host material. Light mode keeps it.
        let dark = traitCollection.userInterfaceStyle == .dark
        target.shadowOpacity = dark ? 0 : (usesIOS16KeyboardAppearance ? 0.18 : 0.23)
        if capInsets != .zero { layer.shadowOpacity = 0 }
    }

    /// KeyboardKit layout items fill the leftover; `edgeInsets` shrink only
    /// the painted cap. The control's bounds still contain the tap.
    func applyCharacterEdgeInsets(_ insets: UIEdgeInsets) {
        capInsets = insets
        contentEdgeInsets = insets
        hintTop.constant = 3 + insets.top
        hintTrailing.constant = -4 - insets.right
        let usesSplitCap = insets != .zero
        capView.isHidden = !usesSplitCap
        if usesSplitCap {
            backgroundColor = .clear
            layer.shadowOpacity = 0
            capView.backgroundColor = keycapFill
            // Compositor bait: leftover is otherwise fully clear, and iOS 26
            // never starts hit-testing those pixels.
            hitFill.backgroundColor = UIColor(white: 0.5, alpha: 0.02)
        } else {
            backgroundColor = keycapFill
            capView.backgroundColor = nil
            hitFill.backgroundColor = .clear
        }
        applyKeycapChrome(isPad: traitCollection.userInterfaceIdiom == .pad)
        setNeedsLayout()
    }

    var isUtilityKey: Bool { isUtility }

    /// Painted cap in the button's own bounds. A/L/Z/M leftover is outside this.
    var paintedCapBounds: CGRect { bounds.inset(by: capInsets) }

    /// System callouts stay solid even when keycaps are glass. Using the
    /// translucent cap colour lets the host show through the balloon.
    var calloutFillColor: UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(white: 0.46, alpha: 1)
            }
            return .white
        }
    }

    var keycapCornerRadius: CGFloat {
        if usesIOS26KeyboardAppearance { return 9 }
        if traitCollection.userInterfaceIdiom == .pad { return isUtility ? 10 : 8 }
        return isUtility ? 8 : 7
    }

    /// Character popups are for typed glyphs. The system keyboard never
    /// shows one on Return/Search/Go — those are controls, even when they
    /// carry a label and the prominent blue fill.
    var supportsCharacterPreview: Bool {
        keyName != "return" && !isUtility && currentTitle != nil && currentTitle != " "
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

    func presentSpaceSignature(_ phrase: String) {
        // Hide first, then snap to the centered phrase. Animating
        // layoutIfNeeded() interpolates from the collapsed lower-right
        // caption, and a long Wijesekara name starts that travel outside
        // the keycap.
        titleLabel?.layer.removeAllAnimations()
        titleLabel?.alpha = 0
        UIView.performWithoutAnimation {
            self.setTitle(phrase, for: .normal)
            self.setTitleColor(.label, for: .normal)
            self.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            self.titleLabel?.transform = .identity
            self.contentHorizontalAlignment = .center
            self.contentVerticalAlignment = .center
            self.contentEdgeInsets = .zero
            self.layoutIfNeeded()
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            titleLabel?.alpha = 1
            return
        }
        titleLabel?.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut]
        ) {
            self.titleLabel?.alpha = 1
            self.titleLabel?.transform = .identity
        }
    }

    func restoreCollapsedSpaceTitle(_ title: String, animated: Bool = true) {
        titleLabel?.layer.removeAllAnimations()
        let applyCollapsedTitle = {
            UIView.performWithoutAnimation {
                self.setTitle(title, for: .normal)
                self.collapseSpaceTitle(animated: false)
            }
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            applyCollapsedTitle()
            return
        }
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.titleLabel?.alpha = 0
        } completion: { [weak self] finished in
            guard let self, finished else { return }
            applyCollapsedTitle()
            self.titleLabel?.alpha = 0
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut]
            ) {
                self.titleLabel?.alpha = 0.64
            }
        }
    }
}

private enum EmojiCategory: CaseIterable, Hashable {
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
    private static let catalogCachePrefix = "AksharaEmojiCatalog.v5"
    private static let groupPrefix = "akshara-emoji-group:"
    private static let orderPrefix = "akshara-emoji-order:"
    private static let topRowFallback = ["😀", "😂", "🥹", "❤️", "👍", "🙏", "🔥", "🎉", "😍", "👏"]
    private static let excludedScalars: Set<UInt32> = [0x23, 0x2A, 0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299]

    private static var catalogCacheKey: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(catalogCachePrefix).\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Build the base list from the Unicode version installed on the device.
    /// This automatically includes single-code-point emoji added by an iOS
    /// release without requiring an app update.
    private static func currentBaseEmoji() -> [String] {
        var result: [String] = []
        for value in UInt32(0x20)...UInt32(0x1FAFF) {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji else { continue }
            guard !excludedScalars.contains(value), !(0x30...0x39).contains(value) else { continue }
            guard !(0x1F1E6...0x1F1FF).contains(value), !(0x1F3FB...0x1F3FF).contains(value) else { continue }
            result.append(String(scalar))
        }
        return result
    }

    /// Category membership and order are fixed for the installed Unicode
    /// version. Cache every iOS-style section once instead of rebuilding it
    /// for every collection-view cell; the Symbols page previously repeated
    /// six full category scans for each emoji it considered.
    private static let categorizedEmoji: [EmojiCategory: [String]] = {
        let defaults = KeyboardPreferences.defaults
        if let cached = defaults.dictionary(forKey: catalogCacheKey) as? [String: [String]],
           let cachedCatalog = catalog(from: cached) {
            return cachedCatalog
        }

        let generatedCatalog = buildCatalog()
        defaults.set(serialized(generatedCatalog), forKey: catalogCacheKey)
        return generatedCatalog
    }()

    private static func buildCatalog() -> [EmojiCategory: [String]] {
        let baseEmoji = currentBaseEmoji()
        let baseSet = Set(baseEmoji)
        // The bundled CLDR index carries the official multi-scalar emoji
        // sequences. Keep only sequences whose emoji scalars are recognized
        // by this iOS runtime, so an older system never receives a newer
        // system's unsupported joined emoji.
        let sequences = searchIndex.keys.filter { emoji in
            guard !baseSet.contains(emoji), emoji.unicodeScalars.contains(where: { $0.properties.isEmoji }) else {
                return false
            }
            // Skin-tone variants are generated at display time from the
            // shared setting, so the catalog only stores the base form.
            guard !emoji.unicodeScalars.contains(where: { $0.properties.isEmojiModifier }) else {
                return false
            }
            return emoji.unicodeScalars.allSatisfy { scalar in
                scalar.properties.isEmoji
                    || scalar.value == 0x200D // zero-width joiner
                    || (0xFE00...0xFE0F).contains(scalar.value) // variation selectors
                    || scalar.value == 0x20E3 // keycap combiner
                    || (0xE0020...0xE007F).contains(scalar.value) // emoji tag sequence
            }
        }.sorted(by: emojiCatalogOrder)
        let allEmoji = Array(Set(baseEmoji + sequences)).sorted(by: emojiCatalogOrder)
        var result = Dictionary(uniqueKeysWithValues: EmojiCategory.allCases.map { ($0, [String]()) })
        for emoji in allEmoji {
            let category = emojiCategory(for: emoji) ?? .symbols
            result[category, default: []].append(emoji)
        }
        return result
    }

    private static func emojiCatalogOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = emojiOrder(for: lhs) ?? Int.max
        let right = emojiOrder(for: rhs) ?? Int.max
        if left != right { return left < right }
        return lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars, by: <)
    }

    private static func emojiCategory(for emoji: String) -> EmojiCategory? {
        guard let group = metadata(for: emoji)?.first(where: { $0.hasPrefix(groupPrefix) }) else { return nil }
        switch String(group.dropFirst(groupPrefix.count)) {
        case "smileys": return .smileys
        case "animals": return .animals
        case "food": return .food
        case "activity": return .activity
        case "travel": return .travel
        case "objects": return .objects
        case "symbols": return .symbols
        case "flags": return .flags
        default: return nil
        }
    }

    private static func emojiOrder(for emoji: String) -> Int? {
        guard let value = metadata(for: emoji)?.first(where: { $0.hasPrefix(orderPrefix) }) else { return nil }
        return Int(value.dropFirst(orderPrefix.count))
    }

    private static func metadata(for emoji: String) -> [String]? {
        if let exact = searchIndex[emoji] { return exact }
        let withEmojiPresentation = emoji + "\u{FE0F}"
        return searchIndex[withEmojiPresentation]
    }

    private static func catalog(from cached: [String: [String]]) -> [EmojiCategory: [String]]? {
        var result: [EmojiCategory: [String]] = [:]
        for category in EmojiCategory.allCases {
            guard let values = cached[category.title] else { return nil }
            result[category] = values
        }
        return result
    }

    private static func serialized(_ catalog: [EmojiCategory: [String]]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: EmojiCategory.allCases.map { category in
            (category.title, catalog[category] ?? [])
        })
    }

    static func emoji(for category: EmojiCategory) -> [String] {
        if category == .recent { return recent() }
        return applyingPreferredSkinTone(to: categorizedEmoji[category] ?? [])
    }

    /// The native keyboard shows one default tone per emoji and exposes the
    /// alternatives through a long press. Akshara mirrors that first choice
    /// with its own shared setting while keeping actual selections intact in
    /// Recents.
    static func applyingPreferredSkinTone(to emoji: [String]) -> [String] {
        EmojiSkinToneApplicator.applyingPreferredSkinTone(to: emoji)
    }

    /// Apply the shared default skin tone to a single suggestion emoji.
    static func withPreferredSkinTone(_ emoji: String) -> String {
        EmojiSkinToneApplicator.withPreferredSkinTone(emoji)
    }

    static func record(_ emoji: String) {
        var values = recent().filter { $0 != emoji }
        values.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(values.prefix(36)), forKey: recentKey)
    }

    static func recent() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? Array(topRowFallback.prefix(8))
    }

    static func topRow() -> [String] {
        let recentEmoji = recent()
        let fallback = applyingPreferredSkinTone(to: topRowFallback.filter { !recentEmoji.contains($0) })
        return Array((recentEmoji + fallback).prefix(10))
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
            // Apply the same tokenisation used for the CLDR keywords.  The
            // previous query path only split spaces and hyphens, so searches
            // such as "heart!" or "face/crying" could never match.
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
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
        return Array(applyingPreferredSkinTone(to: matches.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }.map(\.0)).prefix(40))
    }
}

/// A horizontal emoji catalogue that always has exactly five rows. UIKit's
/// flow layout may recompute its line count while an input-view host is
/// resizing, which is how the picker ended up displaying eight tiny rows.
private final class EmojiFiveRowLayout: UICollectionViewLayout {
    private let rows = 5
    private let columns = 8
    /// Keep the geometry compact. The catalog has thousands of emoji, so
    /// retaining an attribute object for every item makes a horizontal swipe
    /// allocate and filter the complete catalog in the keyboard extension.
    private var sectionOrigins: [CGFloat] = []
    private var sectionItemCounts: [Int] = []
    private var cellSize = CGSize.zero
    private var contentSize = CGSize.zero

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let bounds = collectionView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            sectionOrigins = []
            sectionItemCounts = []
            cellSize = .zero
            contentSize = .zero
            return
        }

        let cellWidth = floor(bounds.width / CGFloat(columns))
        let cellHeight = floor(bounds.height / CGFloat(rows))
        var sectionOriginX: CGFloat = 0
        var nextOrigins: [CGFloat] = []
        var nextItemCounts: [Int] = []

        for section in 0..<collectionView.numberOfSections {
            let itemCount = collectionView.numberOfItems(inSection: section)
            let sectionColumns = max(1, Int(ceil(CGFloat(itemCount) / CGFloat(rows))))
            nextOrigins.append(sectionOriginX)
            nextItemCounts.append(itemCount)
            sectionOriginX += CGFloat(sectionColumns) * cellWidth
        }
        sectionOrigins = nextOrigins
        sectionItemCounts = nextItemCounts
        cellSize = CGSize(width: cellWidth, height: cellHeight)
        contentSize = CGSize(width: max(bounds.width, sectionOriginX), height: bounds.height)
    }

    override var collectionViewContentSize: CGSize { contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard cellSize.width > 0, cellSize.height > 0 else { return [] }
        var visibleAttributes: [UICollectionViewLayoutAttributes] = []

        for section in sectionOrigins.indices {
            let sectionOriginX = sectionOrigins[section]
            let itemCount = sectionItemCounts[section]
            let sectionColumns = max(1, Int(ceil(CGFloat(itemCount) / CGFloat(rows))))
            let sectionRect = CGRect(
                x: sectionOriginX,
                y: 0,
                width: CGFloat(sectionColumns) * cellSize.width,
                height: contentSize.height
            )
            guard sectionRect.intersects(rect) else { continue }

            let firstColumn = max(0, Int(floor((rect.minX - sectionOriginX) / cellSize.width)))
            let lastColumn = min(
                sectionColumns - 1,
                Int(floor((rect.maxX - sectionOriginX) / cellSize.width))
            )
            guard firstColumn <= lastColumn else { continue }
            for column in firstColumn...lastColumn {
                for row in 0..<rows {
                    let item = column * rows + row
                    guard item < itemCount else { break }
                    visibleAttributes.append(attributes(for: IndexPath(item: item, section: section)))
                }
            }
        }
        return visibleAttributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard sectionOrigins.indices.contains(indexPath.section),
              indexPath.item >= 0,
              indexPath.item < sectionItemCounts[indexPath.section] else { return nil }
        return attributes(for: indexPath)
    }

    /// Scrolling changes `bounds.origin`; re-layout is only needed when the
    /// host actually resizes the keyboard.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    private func attributes(for indexPath: IndexPath) -> UICollectionViewLayoutAttributes {
        let column = indexPath.item / rows
        let row = indexPath.item % rows
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(
            x: sectionOrigins[indexPath.section] + CGFloat(column) * cellSize.width,
            y: CGFloat(row) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
        return attributes
    }
}

private final class EmojiPickerView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDeleteHoldBegan: (() -> Void)?
    var onDeleteHoldEnded: (() -> Void)?
    // One long, horizontally scrolling panel contains every category. UIKit
    // only keeps visible cells alive. Seed Recents immediately; load the full
    // catalog off the main thread so opening Emoji does not hitch the keyboard.
    private var emojiSections: [[String]] = EmojiCategory.allCases.map { category in
        category == .recent ? EmojiCatalog.emoji(for: .recent) : []
    }
    private var emojiCatalogLoadGeneration = 0
    private var category: EmojiCategory = .recent {
        didSet {
            updateCategorySelection()
        }
    }
    private var categoryButtons: [EmojiCategory: UIButton] = [:]
    private var categorySelectionIndicators: [EmojiCategory: UIView] = [:]
    private let categoryBar = UIStackView()
    private let collectionView: UICollectionView
    private let titleLabel = UILabel()
    private let searchField = UISearchTextField()
    private let emojiSuggestionRow = UIStackView()
    private let searchKeyboard = KeyboardGridView()
    private var searchQuery = ""
    private var emojiSuggestionButtons: [UIButton] = []
    private enum SearchLayer { case letters, numbers, symbols }
    private var searchLayer: SearchLayer = .letters
    private var searchShift = false
    private var searchKeyMetricConstraints: [(NSLayoutConstraint, () -> CGFloat)] = []
    private var searchKeyRowHeightConstraints: [NSLayoutConstraint] = []
    private var searchKeyCapInsets: [(NativeKeyButton, () -> UIEdgeInsets)] = []
    private var searchKeyboardLeading: NSLayoutConstraint?
    private var searchKeyboardTrailing: NSLayoutConstraint?
    private weak var categoryDeleteButton: UIControl?
    private var searchDeleteRepeater: Timer?
    var documentDeleteControl: UIView? { categoryDeleteButton }

    /// iOS 16's Emoji search field uses a cooler chrome. Letter keys now use
    /// the same phonetic English keycaps as the main keyboard.
    private var usesIOS16EmojiSearchAppearance: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    override init(frame: CGRect) {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: EmojiFiveRowLayout())
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // UIInputView owns the keyboard material and outer shape. Painting a
        // second opaque surface here makes Emoji visibly differ from the
        // primary keyboard, particularly in Dark Mode.
        backgroundColor = .clear

        searchField.placeholder = "Search Emoji"
        searchField.font = .systemFont(ofSize: 18)
        // This picker deliberately manages its own input instead of invoking
        // iOS's keyboard. Set the color explicitly so programmatic updates
        // remain legible in both appearances.
        searchField.textColor = .label
        searchField.tintColor = .systemBlue
        // iOS 26's search field is a low, softly rounded surface rather than
        // the heavily pill-shaped control UIKit supplies by default.
        searchField.borderStyle = .none
        searchField.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.20, alpha: 1)
                : UIColor(white: 0.96, alpha: 1)
        }
        searchField.layer.cornerRadius = 16
        searchField.layer.cornerCurve = .continuous
        searchField.layer.shadowOpacity = 0
        searchField.layer.shadowColor = UIColor.clear.cgColor
        searchField.clipsToBounds = true
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
        letters.contentHorizontalAlignment = .left
        letters.contentEdgeInsets = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        letters.backgroundColor = Self.transparentHitFill
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
            let indicator = UIView()
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.isUserInteractionEnabled = false
            indicator.layer.cornerRadius = 16
            indicator.layer.cornerCurve = .continuous
            indicator.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.34, alpha: 1)
                    : UIColor(red: 0.76, green: 0.77, blue: 0.80, alpha: 1)
            }
            slot.addSubview(indicator)
            categorySelectionIndicators[item] = indicator
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setImage(UIImage(systemName: item.symbolName), for: .normal)
            button.tintColor = .secondaryLabel
            // The system rail uses compact glyphs inside generously sized
            // touch targets. Keep the target size, but match its lighter,
            // slightly smaller category symbols.
            button.setPreferredSymbolConfiguration(.init(pointSize: 15, weight: .regular), forImageIn: .normal)
            button.contentHorizontalAlignment = .center
            button.contentVerticalAlignment = .center
            button.backgroundColor = Self.transparentHitFill
            button.tag = EmojiCategory.allCases.firstIndex(of: item) ?? 0
            button.addTarget(self, action: #selector(selectCategory(_:)), for: .touchUpInside)
            categoryButtons[item] = button
            slot.addSubview(button)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                indicator.widthAnchor.constraint(equalToConstant: 32),
                indicator.heightAnchor.constraint(equalTo: indicator.widthAnchor),
                button.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                button.topAnchor.constraint(equalTo: slot.topAnchor),
                button.bottomAnchor.constraint(equalTo: slot.bottomAnchor)
            ])
        }
        let delete = UIButton(type: .system)
        delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
        delete.tintColor = .label
        delete.setPreferredSymbolConfiguration(.init(pointSize: 21, weight: .regular), forImageIn: .normal)
        delete.contentHorizontalAlignment = .right
        delete.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
        delete.backgroundColor = Self.transparentHitFill
        delete.accessibilityLabel = "Delete"
        delete.isExclusiveTouch = true
        delete.addTarget(self, action: #selector(deleteEmojiInput), for: .touchDown)
        delete.addTarget(self, action: #selector(stopEmojiDeleteHold), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let deleteHold = UILongPressGestureRecognizer(target: self, action: #selector(handleEmojiDeleteHold(_:)))
        deleteHold.minimumPressDuration = 0.42
        deleteHold.allowableMovement = 80
        deleteHold.cancelsTouchesInView = false
        delete.addGestureRecognizer(deleteHold)
        categoryBar.addArrangedSubview(delete)
        delete.widthAnchor.constraint(equalToConstant: 51).isActive = true
        categoryDeleteButton = delete

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceHorizontal = true
        collectionView.alwaysBounceVertical = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "emoji")
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        // Keep one result rail. A second result row steals a full key row's
        // worth of vertical space and collapses the search keyboard's caps.
        // Eight matches are the same compact result count the system exposes
        // above its alphabet keyboard.
        emojiSuggestionRow.axis = .horizontal
        emojiSuggestionRow.distribution = .fillEqually
        emojiSuggestionRow.translatesAutoresizingMaskIntoConstraints = false
        emojiSuggestionRow.isHidden = true
        addSubview(emojiSuggestionRow)
        for _ in 0..<8 {
            let button = UIButton(type: .system)
            button.titleLabel?.font = .systemFont(ofSize: 27)
            // The title is replaced as the query changes. Read it at tap
            // time rather than capturing an initial fallback emoji.
            button.backgroundColor = Self.transparentHitFill
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let emoji = button?.currentTitle, !emoji.isEmpty else { return }
                self?.onSelect?(emoji)
            }, for: .touchUpInside)
            emojiSuggestionRow.addArrangedSubview(button)
            emojiSuggestionButtons.append(button)
        }

        searchKeyboard.axis = .vertical
        searchKeyboard.spacing = 11
        searchKeyboard.distribution = .fillEqually
        searchKeyboard.translatesAutoresizingMaskIntoConstraints = false
        searchKeyboard.isHidden = true
        searchKeyboard.expandsToRowEdges = true
        addSubview(searchKeyboard)
        rebuildSearchKeyboard()
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.heightAnchor.constraint(equalToConstant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            titleLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 5),
            categoryBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            categoryBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            categoryBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            categoryBar.heightAnchor.constraint(equalToConstant: 36),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            collectionView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            collectionView.bottomAnchor.constraint(equalTo: categoryBar.topAnchor, constant: -1),
            emojiSuggestionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            emojiSuggestionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            emojiSuggestionRow.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            emojiSuggestionRow.heightAnchor.constraint(equalToConstant: 38),
            searchKeyboard.topAnchor.constraint(equalTo: emojiSuggestionRow.bottomAnchor, constant: 5),
            searchKeyboard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
        searchKeyboardLeading = searchKeyboard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: searchHorizontalInset)
        searchKeyboardTrailing = searchKeyboard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -searchHorizontalInset)
        searchKeyboardLeading?.isActive = true
        searchKeyboardTrailing?.isActive = true
        updateCategorySelection()
        loadEmojiCatalogInBackground()
    }

    required init?(coder: NSCoder) { nil }
    deinit {
        searchDeleteRepeater?.invalidate()
        onDeleteHoldEnded?()
    }

    private static let transparentHitFill = UIColor(white: 0.5, alpha: 0.02)

    override func layoutSubviews() {
        super.layoutSubviews()
        applySearchKeyboardMetrics()
    }

    private func loadEmojiCatalogInBackground() {
        emojiCatalogLoadGeneration += 1
        let generation = emojiCatalogLoadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Touching any non-recent category materializes the cached Unicode
            // catalog and CLDR index once. Doing that off the main thread keeps
            // the emoji presentation animation smooth.
            let loaded = EmojiCategory.allCases.map { EmojiCatalog.emoji(for: $0) }
            DispatchQueue.main.async {
                guard let self, generation == self.emojiCatalogLoadGeneration else { return }
                self.emojiSections = loaded
                self.collectionView.reloadData()
            }
        }
    }

    @objc private func selectCategory(_ sender: UIButton) {
        let selectedCategory = EmojiCategory.allCases[sender.tag]
        let section = sender.tag
        guard !emojiSections[section].isEmpty else { return }
        category = selectedCategory
        collectionView.scrollToItem(at: IndexPath(item: 0, section: section), at: .left, animated: true)
    }
    @objc private func dismissPicker() { onDismiss?() }
    @objc private func deleteEmojiInput() { onDelete?() }
    @objc private func stopEmojiDeleteHold() {
        stopSearchDeleteRepeat()
        onDeleteHoldEnded?()
    }

    @objc private func handleEmojiDeleteHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            onDeleteHoldBegan?()
        case .ended, .failed:
            stopEmojiDeleteHold()
        case .cancelled:
            if let button = gesture.view as? UIControl, button.isTracking || button.isHighlighted {
                return
            }
            stopEmojiDeleteHold()
        default:
            break
        }
    }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        collectionView.isHidden = true
        titleLabel.isHidden = true
        categoryBar.isHidden = true
        emojiSuggestionRow.isHidden = false
        searchKeyboard.isHidden = false
        rebuildSearchKeyboard()
        updateEmojiSearchResults()
        return false
    }

    private func pressSearchKey(_ key: String) {
        switch key {
        case "delete":
            deleteSearchInputOnce()
            return
        case "space": searchQuery += " "
        case "shift":
            searchShift.toggle()
            refreshSearchKeyAppearance()
            return
        case "123":
            searchLayer = .numbers
            rebuildSearchKeyboard()
            return
        case "#+=":
            searchLayer = .symbols
            rebuildSearchKeyboard()
            return
        case "ABC":
            searchLayer = .letters
            rebuildSearchKeyboard()
            return
        case "emoji":
            endEmojiSearch()
            return
        case "Search":
            // Match iOS: the blue return control exits Emoji Search to the
            // keyboard that opened it. For this extension that is Akshara's
            // active phonetic layout, not the emoji catalogue.
            onDismiss?()
            return
        default:
            if searchShift, key.count == 1, key.first?.isLetter == true {
                searchQuery += key.uppercased()
                searchShift = false
                refreshSearchKeyAppearance()
            } else {
                searchQuery += key
            }
        }
        searchField.text = searchQuery
        updateEmojiSearchResults()
    }

    private func deleteSearchInputOnce() {
        if !searchQuery.isEmpty {
            searchQuery.removeLast()
            searchField.text = searchQuery
            updateEmojiSearchResults()
            return
        }
        onDelete?()
    }

    private func beginSearchDeleteRepeat() {
        searchDeleteRepeater?.invalidate()
        let repeater = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.deleteSearchInputOnce()
        }
        RunLoop.main.add(repeater, forMode: .common)
        searchDeleteRepeater = repeater
    }

    private func stopSearchDeleteRepeat() {
        searchDeleteRepeater?.invalidate()
        searchDeleteRepeater = nil
    }

    private func updateEmojiSearchResults() {
        let matches = EmojiCatalog.search(searchQuery)
        for (index, button) in emojiSuggestionButtons.enumerated() {
            button.setTitle(index < matches.count ? matches[index] : nil, for: .normal)
            button.isEnabled = index < matches.count
        }
    }

    private func endEmojiSearch() {
        stopSearchDeleteRepeat()
        searchQuery = ""
        searchField.text = nil
        searchLayer = .letters
        searchShift = false
        collectionView.isHidden = false
        titleLabel.isHidden = false
        categoryBar.isHidden = false
        emojiSuggestionRow.isHidden = true
        searchKeyboard.isHidden = true
        updateCategorySelection()
    }

    private func searchKeyRows() -> [[String]] {
        switch searchLayer {
        case .letters:
            let letter: (String) -> String = { self.searchShift ? $0.uppercased() : $0 }
            return [
                ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"].map(letter),
                ["a", "s", "d", "f", "g", "h", "j", "k", "l"].map(letter),
                ["shift"] + ["z", "x", "c", "v", "b", "n", "m"].map(letter) + ["delete"],
                ["123", "emoji", "space", "Search"]
            ]
        case .numbers:
            return [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                ["-", "/", ":", ";", "(", ")", "$", "&", "@"],
                ["#+=", ".", ",", "?", "!", "'", "delete"],
                ["ABC", "emoji", "space", "Search"]
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥"],
                ["123", ".", ",", "?", "!", "'", "delete"],
                ["ABC", "emoji", "space", "Search"]
            ]
        }
    }

    private var searchHorizontalInset: CGFloat {
        if usesIOS16EmojiSearchAppearance || bounds.width < 380 { return 5 }
        return KeyboardPreferences.hotPath.keySpacing == .standard ? 20 / 3 : 7
    }

    private var searchGap: CGFloat {
        CGFloat(KeyboardPreferences.hotPath.keySpacingHorizontalGap)
    }

    private var searchGridWidth: CGFloat {
        let width = searchKeyboard.bounds.width
        if width > 1 { return width }
        return max(0, bounds.width - searchHorizontalInset * 2)
    }

    private var searchTenKeyWidth: CGFloat {
        max(0, (searchGridWidth - searchGap * 9) / 10)
    }

    private var searchSecondRowInset: CGFloat {
        max(0, (searchGridWidth - (searchTenKeyWidth * 9 + searchGap * 8)) / 2)
    }

    /// These are the standard-phone phonetic keyboard proportions. Search
    /// used to solve utility widths from whatever space was left, producing
    /// visibly wider Shift/Delete caps than the primary keyboard.
    private var searchUtilityWidth: CGFloat { searchTenKeyWidth * 1.36 }

    private var searchThirdRowInnerGap: CGFloat {
        max(
            searchGap,
            (searchGridWidth - (searchUtilityWidth * 2 + searchTenKeyWidth * 7 + searchGap * 6)) / 2
        )
    }

    private var searchBottomSmallWidth: CGFloat { searchTenKeyWidth * 1.295 }
    private var searchReturnWidth: CGFloat { searchTenKeyWidth * 2.78 }

    private func rebuildSearchKeyboard() {
        searchKeyboard.prepareForKeyRebuild()
        searchKeyMetricConstraints.removeAll()
        searchKeyRowHeightConstraints.removeAll()
        searchKeyCapInsets.removeAll()
        UIView.performWithoutAnimation {
            searchKeyboard.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        searchKeyboard.horizontalGap = searchGap
        searchKeyboard.spacing = 11
        searchKeyboard.expandsToRowEdges = searchLayer == .letters
        for (index, keys) in searchKeyRows().enumerated() {
            let row = makeSearchRow(keys, index: index)
            searchKeyboard.addArrangedSubview(row)
            // Search is a keyboard, not a compressed accessory strip. Keep
            // each row at the same 43 pt cap height as the standard phone
            // layout; the controller requests extra height while searching.
            let height = row.heightAnchor.constraint(equalToConstant: 43)
            height.isActive = true
            searchKeyRowHeightConstraints.append(height)
        }
        applySearchKeyboardMetrics()
    }

    private func makeSearchRow(_ keys: [String], index: Int) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = searchGap
        row.alignment = .fill
        let isLetters = searchLayer == .letters
        let isBottom = keys.contains("space")
        let isControl = keys.contains("shift") || (index == 2 && keys.contains("delete"))
        let isNineKey = isLetters && keys.contains("a") && keys.last == "l"
        row.distribution = (isBottom || (isControl && isLetters) || isNineKey) ? .fill : .fillEqually
        var equalWidthLetterButtons: [NativeKeyButton] = []
        for keyName in keys {
            let button = makeSearchKey(keyName)
            row.addArrangedSubview(button)
            if isNineKey, keyName.lowercased() == "a" {
                addSearchWidth(to: button) { self.searchTenKeyWidth + self.searchSecondRowInset }
                let insets = { UIEdgeInsets(top: 0, left: self.searchSecondRowInset, bottom: 0, right: 0) }
                button.applyCharacterEdgeInsets(insets())
                searchKeyCapInsets.append((button, insets))
            } else if isNineKey, keyName.lowercased() == "l" {
                addSearchWidth(to: button) { self.searchTenKeyWidth + self.searchSecondRowInset }
                let insets = { UIEdgeInsets(top: 0, left: 0, bottom: 0, right: self.searchSecondRowInset) }
                button.applyCharacterEdgeInsets(insets())
                searchKeyCapInsets.append((button, insets))
            } else if isBottom {
                switch keyName {
                case "123", "ABC", "emoji":
                    addSearchWidth(to: button) { self.searchBottomSmallWidth }
                case "Search":
                    addSearchWidth(to: button) { self.searchReturnWidth }
                default:
                    break
                }
            } else if isControl, isLetters, keyName == "shift" || keyName == "delete" {
                addSearchWidth(to: button) { self.searchUtilityWidth }
            } else if isControl, isLetters, keyName.lowercased() == "z" {
                addSearchWidth(to: button) { self.searchTenKeyWidth + self.searchThirdRowInnerGap }
                let insets = { UIEdgeInsets(top: 0, left: self.searchThirdRowInnerGap, bottom: 0, right: 0) }
                button.applyCharacterEdgeInsets(insets())
                searchKeyCapInsets.append((button, insets))
            } else if isControl, isLetters, keyName.lowercased() == "m" {
                addSearchWidth(to: button) { self.searchTenKeyWidth + self.searchThirdRowInnerGap }
                let insets = { UIEdgeInsets(top: 0, left: 0, bottom: 0, right: self.searchThirdRowInnerGap) }
                button.applyCharacterEdgeInsets(insets())
                searchKeyCapInsets.append((button, insets))
            }
            // Match the primary phonetic grid's contiguous utility-to-letter
            // handoff. The visual cap is inset, but its row cell owns the
            // leftover touch area instead of adding a second visible gutter.
            if isControl, isLetters, keyName == "shift" || keyName.lowercased() == "m" {
                row.setCustomSpacing(0, after: button)
            }
            // Mirror `makeRow`: A/L and Z/M own their leftover rails, while
            // all inner letter keys share one exact cap width. Without these
            // constraints UIStackView gives extra width to arbitrary keys
            // such as S and X based on their intrinsic label size.
            let lowercasedKey = keyName.lowercased()
            if isNineKey, lowercasedKey != "a", lowercasedKey != "l" {
                equalWidthLetterButtons.append(button)
            } else if isControl, isLetters,
                      !["shift", "delete", "z", "m"].contains(lowercasedKey) {
                equalWidthLetterButtons.append(button)
            }
        }
        for button in equalWidthLetterButtons.dropFirst() {
            button.widthAnchor.constraint(equalTo: equalWidthLetterButtons[0].widthAnchor).isActive = true
        }
        return row
    }

    private func makeSearchKey(_ key: String) -> NativeKeyButton {
        let utility = ["shift", "delete", "123", "ABC", "#+=", "emoji"].contains(key)
        let title: String?
        let symbol: String?
        switch key {
        case "shift":
            title = nil
            symbol = "shift"
        case "delete":
            title = nil
            symbol = "delete.left"
        case "emoji":
            title = nil
            symbol = "face.smiling"
        case "Search":
            title = nil
            symbol = "checkmark"
        case "space":
            title = nil
            symbol = nil
        default:
            title = key
            symbol = nil
        }
        let button = NativeKeyButton(keyName: key, title: title, symbol: symbol, utility: utility)
        button.applyLayoutMetrics(isPad: traitCollection.userInterfaceIdiom == .pad)
        button.accessibilityLabel = key == "space" ? "space" : (key == "Search" ? "Search" : title ?? key)
        if key == "Search" {
            button.backgroundColor = .systemBlue
            button.tintColor = .white
            button.setTitleColor(.white, for: .normal)
        }
        let liftEvent: UIControl.Event = ["space", "Search", "123", "ABC", "#+=", "emoji", "shift"].contains(key)
            ? .touchUpInside
            : .touchDown
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let key = button?.keyName else { return }
            self?.pressSearchKey(key)
        }, for: liftEvent)
        if key == "delete" {
            button.isExclusiveTouch = true
            button.trackingHitOutset = 44
            button.touchEnded = { [weak self] in self?.stopSearchDeleteRepeat(); self?.onDeleteHoldEnded?() }
            button.touchCancelled = { [weak self] in
                guard let self else { return }
                if self.searchQuery.isEmpty {
                    self.onDeleteHoldEnded?()
                }
            }
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleSearchDeleteHold(_:)))
            hold.minimumPressDuration = 0.42
            hold.allowableMovement = 80
            hold.cancelsTouchesInView = false
            button.addGestureRecognizer(hold)
        }
        return button
    }

    @objc private func handleSearchDeleteHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if searchQuery.isEmpty {
                onDeleteHoldBegan?()
            } else {
                beginSearchDeleteRepeat()
            }
        case .ended, .failed:
            stopSearchDeleteRepeat()
            onDeleteHoldEnded?()
        case .cancelled:
            if let button = gesture.view as? UIControl, button.isTracking || button.isHighlighted {
                return
            }
            stopSearchDeleteRepeat()
            onDeleteHoldEnded?()
        default:
            break
        }
    }

    private func addSearchWidth(to button: UIView, value: @escaping () -> CGFloat) {
        let constraint = button.widthAnchor.constraint(equalToConstant: value())
        constraint.isActive = true
        searchKeyMetricConstraints.append((constraint, value))
    }

    private func applySearchKeyboardMetrics() {
        searchKeyboardLeading?.constant = searchHorizontalInset
        searchKeyboardTrailing?.constant = -searchHorizontalInset
        searchKeyboard.horizontalGap = searchGap
        for case let row as UIStackView in searchKeyboard.arrangedSubviews {
            row.spacing = searchGap
        }
        searchKeyMetricConstraints.forEach { constraint, value in constraint.constant = value() }
        searchKeyCapInsets.forEach { button, value in button.applyCharacterEdgeInsets(value()) }
        searchKeyboard.setNeedsLayout()
    }

    private func refreshSearchKeyAppearance() {
        let letter: (String) -> String = { self.searchShift ? $0.uppercased() : $0 }
        for case let row as UIStackView in searchKeyboard.arrangedSubviews {
            for case let button as NativeKeyButton in row.arrangedSubviews {
                let key = button.keyName
                guard key.count == 1, key.first?.isLetter == true else { continue }
                button.setTitle(letter(key.lowercased()), for: .normal)
            }
        }
    }

    /// Re-resolve keycaps after a light/dark toggle while this picker is up.
    func refreshDynamicSurfaces() {
        rebuildSearchKeyboard()
        updateCategorySelection()
        searchField.textColor = .label
        searchField.tintColor = .systemBlue
    }

    private func updateCategorySelection() {
        titleLabel.text = category.title
        for (item, button) in categoryButtons {
            let selected = item == category
            button.alpha = selected ? 1 : 0.48
            button.tintColor = selected ? .label : .secondaryLabel
            button.backgroundColor = Self.transparentHitFill
            categorySelectionIndicators[item]?.isHidden = !selected
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { EmojiCategory.allCases.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        emojiSections[section].count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath)
        let label: UILabel
        if let existing = cell.contentView.subviews.first as? UILabel { label = existing }
        else {
            label = UILabel()
            // A slightly larger glyph fills more of its five-row cell, which
            // reduces the apparent vertical padding between emoji.
            label.font = .systemFont(ofSize: 32)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor), label.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor), label.topAnchor.constraint(equalTo: cell.contentView.topAnchor), label.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)])
        }
        label.text = emojiSections[indexPath.section][indexPath.item]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let emoji = emojiSections[indexPath.section][indexPath.item]
        EmojiCatalog.record(emoji)
        onSelect?(emoji)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let visibleCenterX = visibleRect.midX
        let closest = collectionView.collectionViewLayout.layoutAttributesForElements(in: visibleRect)?.min {
            abs($0.center.x - visibleCenterX) < abs($1.center.x - visibleCenterX)
        }
        guard let section = closest?.indexPath.section,
              EmojiCategory.allCases.indices.contains(section) else { return }
        let visibleCategory = EmojiCategory.allCases[section]
        if category != visibleCategory { category = visibleCategory }
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

/// Treats the rail as three generous, unbroken selection zones. UIKit can
/// otherwise return the stack view or a divider for a touch landing in the
/// small visual gutters beside a candidate title.
/// QuickType-style suggestion morph. Matching grapheme clusters stay on
/// screen; outgoing clusters fade; new clusters scale-and-fade in from left
/// to right. "good" → "give" therefore keeps `g` still and only animates `ood`.
private final class CandidateMorphLabel: UIView {
    private enum Motion {
        static let appearDuration: TimeInterval = 0.28
        static let disappearDuration: TimeInterval = 0.16
        static let shiftDuration: TimeInterval = 0.22
        static let stagger: TimeInterval = 0.022
        static let appearScale: CGFloat = 0.28
    }

    var font: UIFont = .systemFont(ofSize: 18) {
        didSet {
            guard oldValue != font else { return }
            if bounds.width > 1, !text.isEmpty {
                rebuild(text)
            } else {
                glyphViews.forEach { $0.font = font }
            }
        }
    }

    private(set) var text = ""
    private var glyphViews: [UILabel] = []
    private var retiringViews: [UILabel] = []
    private var lastLayoutSize: CGSize = .zero
    private static let ellipsis: Character = "…"
    private static let horizontalInset: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sizeChanged = abs(bounds.width - lastLayoutSize.width) > 0.5
            || abs(bounds.height - lastLayoutSize.height) > 0.5
        lastLayoutSize = bounds.size
        guard bounds.width > 1 else { return }
        if glyphViews.isEmpty, !text.isEmpty {
            rebuild(text)
            return
        }
        if sizeChanged {
            let run = displayedRun(for: text)
            let current = glyphViews.compactMap(\.text).joined()
            if String(run.characters) != current {
                rebuild(text)
            } else if !run.characters.isEmpty {
                applyFrames(to: glyphViews, characters: run.characters, truncated: run.truncated, animated: false)
            }
        }
    }

    func setText(_ newText: String?, animated: Bool) {
        let incoming = newText ?? ""
        guard incoming != text else { return }
        settleInFlightGlyphs()
        let canAnimate = animated
            && !UIAccessibility.isReduceMotionEnabled
            && bounds.width > 1
            && window != nil
        if !canAnimate {
            rebuild(incoming)
            return
        }
        morph(to: incoming)
    }

    private func settleInFlightGlyphs() {
        retiringViews.forEach { view in
            view.layer.removeAllAnimations()
            view.removeFromSuperview()
        }
        retiringViews.removeAll()
        glyphViews.forEach { view in
            view.layer.removeAllAnimations()
            view.transform = .identity
            view.alpha = 1
        }
        let current = displayedRun(for: text)
        applyFrames(to: glyphViews, characters: current.characters, truncated: current.truncated, animated: false)
    }

    private func rebuild(_ incoming: String) {
        glyphViews.forEach { $0.removeFromSuperview() }
        glyphViews.removeAll()
        text = incoming
        guard !incoming.isEmpty, bounds.width > 1 else { return }
        let run = displayedRun(for: incoming)
        let frames = glyphFrames(for: run.characters, truncated: run.truncated)
        glyphViews = zip(run.characters, frames).map { character, frame in
            let label = makeGlyph(character)
            label.frame = frame
            addSubview(label)
            return label
        }
    }

    private func morph(to incoming: String) {
        let oldRun = displayedRun(for: text)
        let newRun = displayedRun(for: incoming)
        let oldCharacters = oldRun.characters
        let newCharacters = newRun.characters
        guard glyphViews.count == oldCharacters.count else {
            rebuild(incoming)
            return
        }
        if oldCharacters.elementsEqual(newCharacters) {
            text = incoming
            return
        }
        let oldFrames = glyphFrames(for: oldCharacters, truncated: oldRun.truncated)
        let newFrames = glyphFrames(for: newCharacters, truncated: newRun.truncated)
        let overlap = min(oldCharacters.count, newCharacters.count)

        var nextViews = [UILabel?](repeating: nil, count: newCharacters.count)
        var outgoing: [UILabel] = []

        for index in oldCharacters.indices {
            let view = glyphViews[index]
            view.frame = oldFrames[index]
            let isShared = index < overlap && oldCharacters[index] == newCharacters[index]
            if isShared {
                nextViews[index] = view
            } else {
                outgoing.append(view)
            }
        }

        retiringViews.append(contentsOf: outgoing)
        UIView.animate(
            withDuration: Motion.disappearDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]
        ) {
            outgoing.forEach { $0.alpha = 0 }
        } completion: { [weak self] _ in
            guard let self else { return }
            for view in outgoing {
                guard self.retiringViews.contains(where: { $0 === view }) else { continue }
                view.removeFromSuperview()
                self.retiringViews.removeAll { $0 === view }
            }
        }

        var appearOrder = 0
        for index in newCharacters.indices {
            if let kept = nextViews[index] {
                let target = newFrames[index]
                if abs(kept.frame.midX - target.midX) > 0.5 || abs(kept.frame.minY - target.minY) > 0.5 {
                    UIView.animate(
                        withDuration: Motion.shiftDuration,
                        delay: 0,
                        options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
                    ) {
                        kept.frame = target
                    }
                } else {
                    kept.frame = target
                }
                continue
            }

            let label = makeGlyph(newCharacters[index])
            label.frame = newFrames[index]
            label.alpha = 0
            label.transform = CGAffineTransform(scaleX: Motion.appearScale, y: Motion.appearScale)
            addSubview(label)
            nextViews[index] = label
            let delay = Motion.stagger * TimeInterval(appearOrder)
            appearOrder += 1
            UIView.animate(
                withDuration: Motion.appearDuration,
                delay: delay,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                label.alpha = 1
                label.transform = .identity
            }
        }

        glyphViews = nextViews.compactMap { $0 }
        text = incoming
    }

    private func makeGlyph(_ character: Character) -> UILabel {
        let label = UILabel()
        label.text = String(character)
        label.font = font
        label.textColor = .label
        label.textAlignment = .center
        label.baselineAdjustment = .alignCenters
        label.isUserInteractionEnabled = false
        label.backgroundColor = .clear
        return label
    }

    private func applyFrames(to views: [UILabel], characters: [Character], truncated: Bool, animated: Bool) {
        guard views.count == characters.count else { return }
        let frames = glyphFrames(for: characters, truncated: truncated)
        let changes = {
            for (view, frame) in zip(views, frames) {
                view.frame = frame
            }
        }
        guard animated else {
            changes()
            return
        }
        UIView.animate(
            withDuration: Motion.shiftDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }

    private struct DisplayedRun {
        let characters: [Character]
        let truncated: Bool
    }

    /// Keep as many leading grapheme clusters as fit, then a trailing
    /// ellipsis. Measuring clusters (not UTF-16) avoids splitting Sinhala
    /// conjuncts while still clipping the rail the way QuickType does.
    private func displayedRun(for string: String) -> DisplayedRun {
        let characters = Array(string)
        guard !characters.isEmpty else { return DisplayedRun(characters: [], truncated: false) }
        let available = bounds.width - Self.horizontalInset * 2
        guard available > 1 else { return DisplayedRun(characters: characters, truncated: false) }

        let sizes = characters.map { String($0).size(withAttributes: [.font: font]).width }
        let totalWidth = sizes.reduce(CGFloat.zero, +)
        if totalWidth <= available {
            return DisplayedRun(characters: characters, truncated: false)
        }

        let ellipsisWidth = String(Self.ellipsis).size(withAttributes: [.font: font]).width
        var used = ellipsisWidth
        var count = 0
        for width in sizes {
            if used + width > available { break }
            used += width
            count += 1
        }
        if count == 0 {
            return DisplayedRun(
                characters: ellipsisWidth <= available ? [Self.ellipsis] : [],
                truncated: true
            )
        }
        return DisplayedRun(
            characters: Array(characters.prefix(count)) + [Self.ellipsis],
            truncated: true
        )
    }

    private func glyphFrames(for characters: [Character], truncated: Bool) -> [CGRect] {
        guard !characters.isEmpty else { return [] }
        let sizes = characters.map { String($0).size(withAttributes: [.font: font]) }
        let totalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
        // Center the ink box, not the line box. Native QuickType sits on the
        // typographic mid-line; `lineHeight` includes leftover leading that
        // dropped Sinhala (and even Latin) a few points in this short rail.
        let inkHeight = font.ascender - font.descender
        let y = (bounds.height - inkHeight) / 2
        var x = truncated
            ? Self.horizontalInset
            : (bounds.width - totalWidth) / 2
        return sizes.map { size in
            let frame = CGRect(x: x, y: y, width: size.width, height: max(font.lineHeight, inkHeight))
            x += size.width
            return frame
        }
    }
}

private final class CandidateButton: UIButton {
    private let morphLabel = CandidateMorphLabel()
    private(set) var displayedText: String?
    var onActivate: (() -> Void)?

    init() {
        super.init(frame: .zero)
        adjustsImageWhenHighlighted = false
        isEnabled = true
        clipsToBounds = true
        morphLabel.isUserInteractionEnabled = false
        insertSubview(morphLabel, at: 0)
        isAccessibilityElement = false
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel?.isHidden = true
        morphLabel.frame = bounds
    }

    override var isHighlighted: Bool {
        get { super.isHighlighted }
        set {
            super.isHighlighted = newValue
            morphLabel.alpha = newValue ? 0.35 : 1
        }
    }

    override func accessibilityActivate() -> Bool {
        guard displayedText != nil else { return false }
        onActivate?()
        return true
    }

    var candidateFont: UIFont {
        get { morphLabel.font }
        set { morphLabel.font = newValue }
    }

    func setCandidate(_ text: String?, animated: Bool) {
        displayedText = text
        // Stay enabled. Disabling a UIButton mid-touch cancels the gesture,
        // which is what made suggestion taps miss after a phonetic keystroke.
        isEnabled = true
        isAccessibilityElement = text != nil
        accessibilityLabel = text
        morphLabel.setText(text, animated: animated)
    }
}

/// Full-width clipboard cell. The label never takes hits; the cell/contentView
/// owns the whole row so short text still pastes, and UITableView provides
/// familiar, system-standard swipe actions.
private final class ClipboardHistoryCell: UITableViewCell {
    static let reuseID = "ClipboardHistoryCell"

    private let previewLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .default
        separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .systemFont(ofSize: 16)
        previewLabel.textColor = .label
        previewLabel.numberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.isUserInteractionEnabled = false
        contentView.addSubview(previewLabel)

        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            previewLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            previewLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            previewLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, isPinned: Bool) {
        previewLabel.text = text
        accessibilityLabel = text
        accessibilityTraits = .button
        accessoryType = .none
        if isPinned {
            let pin = UIImageView(image: UIImage(systemName: "pin.fill"))
            pin.tintColor = .systemOrange
            pin.preferredSymbolConfiguration = .init(pointSize: 13, weight: .semibold)
            pin.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
            pin.contentMode = .center
            accessoryView = pin
        } else {
            accessoryView = nil
        }
        accessibilityHint = isPinned ? "Pinned clip. Tap to paste." : "Tap to paste. Swipe right to pin."
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewLabel.text = nil
    }
}

private final class ClipboardHistoryView: UIView, UITableViewDataSource, UITableViewDelegate {
    private enum Tab: Int {
        case recent
        case pinned
    }

    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onDeleteRecentAt: ((Int) -> Void)?
    var onPinRecentAt: ((Int) -> Void)?
    var onDeletePinnedAt: ((Int) -> Void)?
    var onItemActionFeedback: (() -> Void)?

    private var recentItems: [String] = []
    private var pinnedItems: [String] = []
    private var hasFullAccess = true
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let tabControl = UISegmentedControl(items: ["Recent", "Pinned"])
    private var selectedTab: Tab = .recent

    private var displayedItems: [String] {
        selectedTab == .recent ? recentItems : pinnedItems
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isUserInteractionEnabled = true

        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.isUserInteractionEnabled = true
        addSubview(toolbar)

        titleLabel.text = "Clipboard"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isUserInteractionEnabled = false
        toolbar.addSubview(titleLabel)

        let backButton = UIButton(type: .system)
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .label
        backButton.setPreferredSymbolConfiguration(
            .init(pointSize: 17, weight: .semibold),
            forImageIn: .normal
        )
        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(dismissPanel), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(backButton)

        let abc = UIButton(type: .system)
        abc.setTitle("ABC", for: .normal)
        abc.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        abc.setTitleColor(.label, for: .normal)
        abc.addTarget(self, action: #selector(dismissPanel), for: .touchUpInside)
        abc.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(abc)

        clearButton.setImage(UIImage(systemName: "trash.fill"), for: .normal)
        // Keep the toolbar neutral; the destructive treatment appears in the
        // menu item itself, where it has context and cannot be misread.
        clearButton.tintColor = .secondaryLabel
        clearButton.setPreferredSymbolConfiguration(
            .init(pointSize: 17, weight: .regular),
            forImageIn: .normal
        )
        clearButton.accessibilityLabel = "Clipboard actions"
        clearButton.menu = UIMenu(children: [
            UIAction(
                title: "Clear Recent Clips",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.onClearHistory?()
            }
        ])
        clearButton.showsMenuAsPrimaryAction = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(clearButton)

        toolbar.bringSubviewToFront(titleLabel)

        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.selectedSegmentIndex = Tab.recent.rawValue
        tabControl.selectedSegmentTintColor = .tertiarySystemFill
        tabControl.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel
        ], for: .normal)
        tabControl.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor.label
        ], for: .selected)
        tabControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabControl.accessibilityLabel = "Clipboard category"
        addSubview(tabControl)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorColor = .separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsSelection = true
        tableView.isScrollEnabled = true
        tableView.alwaysBounceVertical = true
        tableView.delaysContentTouches = false
        tableView.canCancelContentTouches = true
        tableView.keyboardDismissMode = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.tableFooterView = UIView()
        tableView.register(ClipboardHistoryCell.self, forCellReuseIdentifier: ClipboardHistoryCell.reuseID)
        addSubview(tableView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.isHidden = true
        emptyLabel.isUserInteractionEnabled = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -2),

            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -2),
            backButton.widthAnchor.constraint(equalToConstant: 40),
            backButton.heightAnchor.constraint(equalTo: toolbar.heightAnchor),

            abc.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            abc.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -2),
            abc.widthAnchor.constraint(equalToConstant: 48),
            abc.heightAnchor.constraint(equalTo: toolbar.heightAnchor),

            clearButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -2),
            clearButton.widthAnchor.constraint(equalToConstant: 44),
            clearButton.heightAnchor.constraint(equalTo: toolbar.heightAnchor),

            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            tabControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tabControl.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            tabControl.heightAnchor.constraint(equalToConstant: 32),

            tableView.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(recentItems: [String], pinnedItems: [String], hasFullAccess: Bool) {
        self.recentItems = recentItems
        self.pinnedItems = pinnedItems
        self.hasFullAccess = hasFullAccess
        updateTabTitles()
        updateToolbarButtons()
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateTabTitles() {
        tabControl.setTitle("Recent \(recentItems.count)", forSegmentAt: Tab.recent.rawValue)
        tabControl.setTitle("Pinned \(pinnedItems.count)", forSegmentAt: Tab.pinned.rawValue)
    }

    private func updateToolbarButtons() {
        clearButton.isHidden = selectedTab == .pinned
        clearButton.isEnabled = hasFullAccess && !recentItems.isEmpty
        clearButton.alpha = clearButton.isEnabled ? 1 : 0.4
    }

    private func updateEmptyState() {
        if !hasFullAccess {
            emptyLabel.text = "Allow Full Access in Settings → General → Keyboard → Keyboards → Akshara to use clipboard history."
            emptyLabel.isHidden = false
            tableView.isHidden = true
            return
        }
        emptyLabel.text = selectedTab == .recent
            ? "Copy text while Akshara is open to save it here. Swipe a clip right to pin it."
            : "Pinned clips stay here until you delete them. Tap a clip to paste it."
        emptyLabel.isHidden = !displayedItems.isEmpty
        tableView.isHidden = false
        tableView.isScrollEnabled = true
    }

    @objc private func dismissPanel() { onDismiss?() }

    @objc private func tabChanged() {
        selectedTab = Tab(rawValue: tabControl.selectedSegmentIndex) ?? .recent
        updateToolbarButtons()
        tableView.reloadData()
        updateEmptyState()
    }

    private func deleteItem(at indexPath: IndexPath) {
        guard displayedItems.indices.contains(indexPath.row) else { return }
        let index = indexPath.row
        if selectedTab == .recent {
            recentItems.remove(at: index)
            onDeleteRecentAt?(index)
        } else {
            pinnedItems.remove(at: index)
            onDeletePinnedAt?(index)
        }
        onItemActionFeedback?()
        tableView.performBatchUpdates {
            tableView.deleteRows(at: [indexPath], with: .left)
        } completion: { [weak self] _ in
            self?.updateTabTitles()
            self?.updateToolbarButtons()
            self?.updateEmptyState()
        }
    }

    private func pinItem(at indexPath: IndexPath) {
        guard recentItems.indices.contains(indexPath.row) else { return }
        let item = recentItems.remove(at: indexPath.row)
        pinnedItems.removeAll { $0 == item }
        pinnedItems.insert(item, at: 0)
        onPinRecentAt?(indexPath.row)
        onItemActionFeedback?()
        tableView.performBatchUpdates {
            tableView.deleteRows(at: [indexPath], with: .left)
        } completion: { [weak self] _ in
            self?.updateTabTitles()
            self?.updateToolbarButtons()
            self?.updateEmptyState()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        hasFullAccess ? displayedItems.count : 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ClipboardHistoryCell.reuseID,
            for: indexPath
        ) as! ClipboardHistoryCell
        cell.configure(text: displayedItems[indexPath.row], isPinned: selectedTab == .pinned)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard displayedItems.indices.contains(indexPath.row) else { return }
        onSelect?(displayedItems[indexPath.row])
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        hasFullAccess
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard hasFullAccess, displayedItems.indices.contains(indexPath.row) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let delete = UIAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.deleteItem(at: indexPath)
            }
            guard self.selectedTab == .recent else {
                return UIMenu(title: "Pinned Clip", children: [delete])
            }
            let pin = UIAction(title: "Pin", image: UIImage(systemName: "pin")) { [weak self] _ in
                self?.pinItem(at: indexPath)
            }
            return UIMenu(title: "Recent Clip", children: [pin, delete])
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard hasFullAccess else { return nil }
        let delete = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, done in
            self?.deleteItem(at: indexPath)
            done(true)
        }
        delete.image = UIImage(systemName: "trash.fill")
        delete.accessibilityLabel = "Delete"
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard hasFullAccess, selectedTab == .recent else { return nil }
        let pin = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, done in
            guard let self, self.recentItems.indices.contains(indexPath.row) else {
                done(false)
                return
            }
            self.pinItem(at: indexPath)
            done(true)
        }
        pin.backgroundColor = .systemOrange
        pin.image = UIImage(systemName: "pin.fill")
        pin.accessibilityLabel = "Pin"
        return UISwipeActionsConfiguration(actions: [pin])
    }
}

private final class CandidateRailView: UIView {
    var candidateButtons: [CandidateButton] = []
    /// Extra hit area below the rail. Kept at zero while the Q row owns the
    /// sliver above its painted caps; a grazing key tap must not hit a suggestion.
    var hitOutsets: UIEdgeInsets = .zero
    var onSelect: ((CandidateButton) -> Void)?
    private var highlightedButton: CandidateButton?

    private var expandedHitBounds: CGRect {
        bounds.inset(by: UIEdgeInsets(
            top: -hitOutsets.top,
            left: -hitOutsets.left,
            bottom: -hitOutsets.bottom,
            right: -hitOutsets.right
        ))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        expandedHitBounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
              expandedHitBounds.contains(point) else { return nil }
        // Own the touch even when a ranking pass blanks a UIButton. The rail
        // inserts on touch-down from `touchesBegan`, not `touchUpInside`.
        return self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let point = touches.first?.location(in: self),
              let button = suggestionButton(at: point) else { return }
        highlightedButton?.isHighlighted = false
        highlightedButton = button
        button.isHighlighted = true
        onSelect?(button)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let point = touches.first?.location(in: self) else { return }
        let button = suggestionButton(at: point)
        if button !== highlightedButton {
            highlightedButton?.isHighlighted = false
            highlightedButton = button
            button?.isHighlighted = true
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        highlightedButton?.isHighlighted = false
        highlightedButton = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        highlightedButton?.isHighlighted = false
        highlightedButton = nil
    }

    func suggestionButton(at point: CGPoint) -> CandidateButton? {
        let selectable = candidateButtons.filter { $0.displayedText != nil && !$0.isHidden }
        guard !selectable.isEmpty else { return nil }
        for button in selectable {
            let frame = button.convert(button.bounds, to: self)
            if frame.contains(point) {
                return button
            }
        }
        return selectable.min { lhs, rhs in
            abs(lhs.convert(CGPoint(x: lhs.bounds.midX, y: lhs.bounds.midY), to: self).x - point.x)
                < abs(rhs.convert(CGPoint(x: rhs.bounds.midX, y: rhs.bounds.midY), to: self).x - point.x)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bringSubviewToFront(touchOverlay)
        touchOverlay.isHidden = !KeyboardPreferences.hotPath.showTouchAreas
        guard !touchOverlay.isHidden else { return }
        // Overlay matches `expandedHitBounds` 1:1 so the fill is the real
        // hit map, including the strip down to the first key row.
        touchOverlay.frame = expandedHitBounds
        touchOverlay.sliceCount = 3
        touchOverlay.setNeedsDisplay()
    }

    private let touchOverlay = CandidateTouchOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        touchOverlay.isUserInteractionEnabled = false
        addSubview(touchOverlay)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = false
        touchOverlay.isUserInteractionEnabled = false
        addSubview(touchOverlay)
    }

    /// Follow the Liquid Glass keyboard capsule. KeyboardKit does the same
    /// with `KeyboardViewStyle.backgroundCornerRadiusTop` because the system
    /// frame cannot be changed. Only the overlay clips, so the 4 pt hit
    /// strip under the rail still draws.
    func applyLiquidGlassTopCurveIfAvailable() {
        guard #available(iOS 26.0, *) else { return }
        LiquidGlassCornerStyle.applyTopCapsule(to: self)
        LiquidGlassCornerStyle.applyTopCapsule(to: touchOverlay, clipOverlay: true)
    }

    func resetLiquidGlassTopCurveIfAvailable() {
        guard #available(iOS 26.0, *) else { return }
        LiquidGlassCornerStyle.reset(to: self)
        LiquidGlassCornerStyle.reset(to: touchOverlay)
    }
}

private final class CandidateTouchOverlayView: UIView {
    var sliceCount = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let fill = UIColor.systemTeal.withAlphaComponent(0.16)
        let stroke = UIColor.systemTeal.withAlphaComponent(0.7)
        context.setFillColor(fill.cgColor)
        context.fill(bounds)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1)
        // One outer stroke, fully inside bounds so glass does not eat the
        // top edge. Dividers only — no per-slice inset, which left grey
        // gutters between the three suggestions.
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        let count = max(sliceCount, 1)
        guard count > 1 else { return }
        let sliceWidth = bounds.width / CGFloat(count)
        for index in 1..<count {
            let x = sliceWidth * CGFloat(index)
            context.move(to: CGPoint(x: x, y: bounds.minY))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
        }
        context.strokePath()
    }
}

/// Fills gutters between keycaps. Phonetic layouts also expand each key to
/// its full row cell — including the A / L side margins and the leftover
/// beside Shift / Delete, which stays on Z / M. Wijesekara keeps the
/// conservative half-gap snap so a narrow Shift is not stolen by ්‍ර.
private final class KeyboardGridView: UIStackView {
    /// Extra hit area around the stack so side chrome and the strips above
    /// and below the grid still reach an edge key — not a neighbour.
    var hitExpansion: UIEdgeInsets = .zero
    var horizontalGap: CGFloat = 6
    /// Phonetic / Smart Phonetic: each key owns its row cell out to the
    /// midpoints of neighbouring gaps and the row's leading/trailing edge.
    /// A, L, Z, and M also keep the empty leftover beside them at all times.
    var expandsToRowEdges = false
    /// 0...1 next-key weights, keyed by lowercase letter identity.
    var keyTouchWeights: [String: CGFloat] = [:] {
        didSet {
            guard oldValue != keyTouchWeights else { return }
            cachedHitSlots = nil
            touchOverlay.setNeedsDisplay()
        }
    }

    /// Near-invisible fill behind the keys so iOS 26 delivers gutter taps.
    /// Kept off the keycaps; the debug overlay is a separate front view.
    private let hitFillView = UIView()
    private let touchOverlay = KeyTouchOverlayView()
    /// Key frames change only during layout. Reusing this map removes all
    /// frame conversions and slot allocations from the touch-down hot path.
    private var cachedHitSlots: [HitSlot]?

    override init(frame: CGRect) {
        super.init(frame: frame)
        insetsLayoutMarginsFromSafeArea = false
        isLayoutMarginsRelativeArrangement = false
        configureTouchOverlay()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        insetsLayoutMarginsFromSafeArea = false
        isLayoutMarginsRelativeArrangement = false
        configureTouchOverlay()
    }

    private func configureTouchOverlay() {
        clipsToBounds = false
        hitFillView.isUserInteractionEnabled = false
        hitFillView.isOpaque = false
        hitFillView.backgroundColor = UIColor(white: 0.5, alpha: 0.02)
        insertSubview(hitFillView, at: 0)
        touchOverlay.isUserInteractionEnabled = false
        touchOverlay.clearsContextBeforeDrawing = true
        addSubview(touchOverlay)
    }

    /// Drop any cached overlay bitmap before the key rows are replaced.
    /// iOS 26 otherwise composites the previous leftover rails onto the new layer.
    func prepareForKeyRebuild() {
        cachedHitSlots = nil
        touchOverlay.slots = []
        touchOverlay.layer.contents = nil
        touchOverlay.isHidden = true
        touchOverlay.setNeedsDisplay()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        expandedHitBounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else {
            KeyboardHitTrace.logHit(
                "grid hitTest SKIP enabled=\(isUserInteractionEnabled) hidden=\(isHidden) alpha=\(alpha) pt=\(KeyboardHitTrace.fmt(point))"
            )
            return nil
        }
        guard self.point(inside: point, with: event) else {
            KeyboardHitTrace.logHit(
                "grid hitTest OUTSIDE pt=\(KeyboardHitTrace.fmt(point)) expanded=\(KeyboardHitTrace.fmt(expandedHitBounds))"
            )
            return nil
        }

        let slots = hitSlots()
        guard !slots.isEmpty else {
            KeyboardHitTrace.logHit("grid hitTest EMPTY slots pt=\(KeyboardHitTrace.fmt(point))")
            return nil
        }

        var reason = "none"
        var result: NativeKeyButton?
        if let owner = slots.first(where: {
            $0.button.convert($0.button.bounds, to: self).contains(point)
        }) {
            reason = "bounds"
            result = owner.button
        } else if let painted = keyContainingPaintedCap(at: point, slots: slots) {
            reason = "paintedCap"
            result = painted
        } else if expandsToRowEdges {
            if let inflated = keyOwningInflatedCell(at: point, slots: slots) {
                reason = "inflated"
                result = inflated
            } else if let tiled = slots.first(where: { $0.tiled.contains(point) })?.button {
                reason = "tiled"
                result = tiled
            }
        } else if let gutter = nearestKeyInGutter(at: point, slots: slots) {
            reason = "gutter"
            result = gutter
        }

        logHitResolution(point: point, reason: reason, result: result, slots: slots)
        return result
    }

    private func logHitResolution(
        point: CGPoint,
        reason: String,
        result: NativeKeyButton?,
        slots: [HitSlot]
    ) {
        guard KeyboardHitTrace.isEnabled else { return }
        let key = result?.keyName ?? "nil"

        var leftover = false
        var inButtonBounds = false
        var inCap = false
        if let result {
            let local = result.convert(point, from: self)
            inButtonBounds = result.bounds.contains(local)
            inCap = result.bounds.inset(by: result.capInsets).contains(local)
            leftover = result.capInsets != .zero && inButtonBounds && !inCap
        } else {
            leftover = slots.contains {
                KeyboardHitTrace.isTraced($0.button.keyName)
                    && $0.button.convert($0.button.bounds, to: self).inset(by: $0.button.capInsets).contains(point) == false
                    && ($0.tiled.contains(point) || $0.inflated.contains(point))
            }
        }
        KeyboardHitTrace.logHit(
            "grid hitTest pt=\(KeyboardHitTrace.fmt(point)) -> \(key) reason=\(reason) inButtonBounds=\(inButtonBounds) inCap=\(inCap) leftover=\(leftover) uiKitWillAccept=\(inButtonBounds)"
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cachedHitSlots = nil
        sendSubviewToBack(hitFillView)
        hitFillView.frame = expandedHitBounds
        let debug = KeyboardPreferences.hotPath.showTouchAreas
        touchOverlay.showsDebugTouchAreas = debug
        touchOverlay.frame = expandedHitBounds
        guard debug else {
            touchOverlay.slots = []
            touchOverlay.layer.contents = nil
            touchOverlay.isHidden = true
            logLeftoverGeometryIfNeeded()
            return
        }
        touchOverlay.isHidden = false
        bringSubviewToFront(touchOverlay)
        let origin = expandedHitBounds.origin
        touchOverlay.slots = hitSlots().map { slot in
            KeyTouchOverlayView.Slot(
                cap: slot.cap.offsetBy(dx: -origin.x, dy: -origin.y),
                tiled: slot.tiled.offsetBy(dx: -origin.x, dy: -origin.y),
                inflated: slot.inflated.offsetBy(dx: -origin.x, dy: -origin.y),
                weight: slot.weight,
                isLetter: slot.isLetter
            )
        }
        logLeftoverGeometryIfNeeded()
        touchOverlay.setNeedsDisplay()
    }

    private var lastLeftoverGeometryDump = ""

    private func logLeftoverGeometryIfNeeded() {
        guard KeyboardHitTrace.isEnabled else { return }
        let leftover = liveKeysByRow().flatMap { $0 }.filter { KeyboardHitTrace.isTraced($0.button.keyName) }
        guard !leftover.isEmpty else { return }
        let dump = leftover.map { item in
            let cap = item.frame.inset(by: item.button.capInsets)
            return "\(item.button.keyName) frame=\(KeyboardHitTrace.fmt(item.frame)) insets=\(KeyboardHitTrace.fmt(item.button.capInsets)) cap=\(KeyboardHitTrace.fmt(cap))"
        }.joined(separator: " | ")
        let summary = "layout leftover \(dump) expandsToRowEdges=\(expandsToRowEdges) overlayHidden=\(touchOverlay.isHidden)"
        guard summary != lastLeftoverGeometryDump else { return }
        lastLeftoverGeometryDump = summary
        KeyboardHitTrace.log(summary)
    }

    private var expandedHitBounds: CGRect {
        bounds.inset(by: UIEdgeInsets(
            top: -hitExpansion.top,
            left: -hitExpansion.left,
            bottom: -hitExpansion.bottom,
            right: -hitExpansion.right
        ))
    }

    private struct HitSlot {
        let button: NativeKeyButton
        let cap: CGRect
        let tiled: CGRect
        let inflated: CGRect
        let weight: CGFloat
        var isLetter: Bool {
            button.keyName.count == 1 && button.keyName.first?.isLetter == true
        }
    }

    private func hitSlots() -> [HitSlot] {
        if let cachedHitSlots { return cachedHitSlots }
        let slots = buildHitSlots()
        cachedHitSlots = slots
        return slots
    }

    private func buildHitSlots() -> [HitSlot] {
        let keysByRow = liveKeysByRow()
        let rows = arrangedSubviews.compactMap { $0 as? UIStackView }
        let maxInvasionX = horizontalGap / 2
        let maxInvasionY = spacing / 2
        var slots: [HitSlot] = []
        for (rowIndex, rowKeys) in keysByRow.enumerated() {
            guard !rowKeys.isEmpty else { continue }
            let cells: [CGRect]
            if expandsToRowEdges, rows.count == keysByRow.count {
                cells = rowCells(for: rowKeys, rowIndex: rowIndex, rows: rows)
            } else {
                cells = rowKeys.map { snapRect(for: $0.frame) }
            }
            for (item, tiled) in zip(rowKeys, cells) {
                let weight = item.button.keyName.count == 1 && item.button.keyName.first?.isLetter == true
                    ? keyTouchWeights[item.button.keyName, default: 0]
                    : 0
                let inflated = weight > 0
                    ? tiled.insetBy(dx: -(weight * maxInvasionX), dy: -(weight * maxInvasionY))
                    : tiled
                slots.append(HitSlot(
                    button: item.button,
                    cap: item.frame.inset(by: item.button.capInsets),
                    tiled: tiled,
                    inflated: inflated,
                    weight: weight
                ))
            }
        }
        return slots
    }

    private func keyContainingPaintedCap(at point: CGPoint, slots: [HitSlot]) -> NativeKeyButton? {
        var inside: [HitSlot] = []
        for slot in slots where slot.cap.contains(point) {
            inside.append(slot)
        }
        if inside.count == 1 { return inside[0].button }
        if inside.count > 1 {
            return inside.min { lhs, rhs in
                hypot(lhs.cap.midX - point.x, lhs.cap.midY - point.y)
                    < hypot(rhs.cap.midX - point.x, rhs.cap.midY - point.y)
            }?.button
        }
        return nil
    }

    private func keyOwningInflatedCell(at point: CGPoint, slots: [HitSlot]) -> NativeKeyButton? {
        let hits = slots.filter { $0.weight > 0 && $0.isLetter && $0.inflated.contains(point) }
        guard !hits.isEmpty else { return nil }
        return hits.max { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
            return hypot(lhs.cap.midX - point.x, lhs.cap.midY - point.y)
                > hypot(rhs.cap.midX - point.x, rhs.cap.midY - point.y)
        }?.button
    }

    /// System-keyboard cells: each key owns half of the gutter beside it, and
    /// the empty A / L side margins plus the Shift–Z and M–Delete leftover
    /// stay on those letters (not on Shift / Delete).
    private func rowCells(
        for rowKeys: [(button: NativeKeyButton, frame: CGRect)],
        rowIndex: Int,
        rows: [UIStackView]
    ) -> [CGRect] {
        let rowFrame = rows[rowIndex].convert(rows[rowIndex].bounds, to: self)
        let minY: CGFloat
        if rowIndex == 0 {
            minY = rowFrame.minY - hitExpansion.top
        } else {
            let previous = rows[rowIndex - 1].convert(rows[rowIndex - 1].bounds, to: self)
            minY = (previous.maxY + rowFrame.minY) / 2
        }
        let maxY: CGFloat
        if rowIndex == rows.count - 1 {
            maxY = rowFrame.maxY + hitExpansion.bottom
        } else {
            let next = rows[rowIndex + 1].convert(rows[rowIndex + 1].bounds, to: self)
            maxY = (rowFrame.maxY + next.minY) / 2
        }
        let leading = rowFrame.minX - hitExpansion.left
        let trailing = rowFrame.maxX + hitExpansion.right

        var leftEdges = [CGFloat]()
        var rightEdges = [CGFloat]()
        leftEdges.reserveCapacity(rowKeys.count)
        rightEdges.reserveCapacity(rowKeys.count)
        for (index, item) in rowKeys.enumerated() {
            let left = index == 0
                ? leading
                : (rowKeys[index - 1].frame.maxX + item.frame.minX) / 2
            let right = index == rowKeys.count - 1
                ? trailing
                : (item.frame.maxX + rowKeys[index + 1].frame.minX) / 2
            leftEdges.append(left)
            rightEdges.append(right)
        }
        applyDefaultEdgeLetterExpansion(
            rowKeys: rowKeys,
            leftEdges: &leftEdges,
            rightEdges: &rightEdges,
            leading: leading,
            trailing: trailing
        )

        return zip(leftEdges, rightEdges).map { left, right in
            CGRect(x: left, y: minY, width: max(0, right - left), height: max(0, maxY - minY))
        }
    }

    /// Always-on Phonetic leftover: A / L own the second-row side margins,
    /// Z owns the strip up to Shift, and M owns the strip up to Delete.
    /// Independent of next-key weights, so it does not collapse between words.
    private func applyDefaultEdgeLetterExpansion(
        rowKeys: [(button: NativeKeyButton, frame: CGRect)],
        leftEdges: inout [CGFloat],
        rightEdges: inout [CGFloat],
        leading: CGFloat,
        trailing: CGFloat
    ) {
        for (index, item) in rowKeys.enumerated() {
            switch item.button.keyName {
            case "a":
                leftEdges[index] = leading
            case "l" where index == rowKeys.count - 1:
                rightEdges[index] = trailing
            case "z" where index > 0 && rowKeys[index - 1].button.keyName == "shift":
                let boundary = rowKeys[index - 1].frame.maxX
                leftEdges[index] = boundary
                rightEdges[index - 1] = min(rightEdges[index - 1], boundary)
            case "m" where index + 1 < rowKeys.count && rowKeys[index + 1].button.keyName == "delete":
                let boundary = rowKeys[index + 1].frame.minX
                rightEdges[index] = boundary
                leftEdges[index + 1] = max(leftEdges[index + 1], boundary)
            default:
                break
            }
        }
    }

    private func snapRect(for frame: CGRect) -> CGRect {
        frame.insetBy(dx: -(horizontalGap / 2), dy: -(spacing / 2))
    }

    private func nearestKeyInGutter(at point: CGPoint, slots: [HitSlot]) -> NativeKeyButton? {
        let keyUnion = slots.reduce(into: CGRect.null) { $0 = $0.union($1.cap) }
        let inChrome = !keyUnion.insetBy(dx: -0.5, dy: -0.5).contains(point)
        let maxSnapX = inChrome ? max(horizontalGap / 2, hitExpansion.left, hitExpansion.right) : horizontalGap / 2
        let maxSnapY = inChrome ? max(spacing / 2, hitExpansion.top, hitExpansion.bottom) : spacing / 2

        var best: NativeKeyButton?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for slot in slots {
            let frame = slot.cap
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            guard dx <= maxSnapX + 0.5, dy <= maxSnapY + 0.5 else { continue }
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = slot.button
            }
        }
        return best
    }

    private func liveKeysByRow() -> [[(button: NativeKeyButton, frame: CGRect)]] {
        arrangedSubviews.compactMap { $0 as? UIStackView }.map { row in
            row.arrangedSubviews.compactMap { view -> (NativeKeyButton, CGRect)? in
                guard let key = view as? NativeKeyButton,
                      key.isUserInteractionEnabled, !key.isHidden, key.alpha > 0.01 else { return nil }
                let frame = key.convert(key.bounds, to: self)
                guard !frame.isEmpty else { return nil }
                return (key, frame)
            }
        }
    }
}

private final class KeyTouchOverlayView: UIView {
    struct Slot {
        let cap: CGRect
        let tiled: CGRect
        let inflated: CGRect
        let weight: CGFloat
        let isLetter: Bool
    }

    var slots: [Slot] = []
    /// Debug paint for "Show touch areas". Gutter taps use `hitFillView` instead.
    var showsDebugTouchAreas = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = false
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard showsDebugTouchAreas else { return }
        for slot in slots {
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.12).cgColor)
            context.fill(slot.tiled)
            if slot.weight > 0, slot.isLetter {
                context.setFillColor(UIColor.systemOrange.withAlphaComponent(0.12 + 0.35 * slot.weight).cgColor)
                context.fill(slot.inflated)
            }
            context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1)
            context.stroke(slot.cap.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

/// iOS key-pop silhouette: one path, rounded convex corners via tangent
/// arcs, and a vertical S-curve neck between the bubble and the stem.
private struct KeyCalloutShape {
    var stemRect: CGRect
    var bubbleCornerRadius: CGFloat
    var stemCornerRadius: CGFloat
    var neckHeight: CGFloat

    func path(in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let bubbleR = min(bubbleCornerRadius, bounds.width / 2, max(0, stemRect.minY) / 2)
        let stemR = min(stemCornerRadius, stemRect.width / 2, stemRect.height / 2)
        let neck = min(max(neckHeight, 8), max(8, stemRect.height * 0.45))

        let bubbleTopLeft = CGPoint(x: bounds.minX, y: bounds.minY)
        let bubbleTopRight = CGPoint(x: bounds.maxX, y: bounds.minY)
        let bubbleBottomRight = CGPoint(x: bounds.maxX, y: stemRect.minY)
        let stemTopRight = CGPoint(x: stemRect.maxX, y: stemRect.minY + neck)
        let stemBottomRight = CGPoint(x: stemRect.maxX, y: stemRect.maxY)
        let stemBottomLeft = CGPoint(x: stemRect.minX, y: stemRect.maxY)
        let stemTopLeft = CGPoint(x: stemRect.minX, y: stemRect.minY + neck)
        let bubbleBottomLeft = CGPoint(x: bounds.minX, y: stemRect.minY)

        path.move(to: CGPoint(x: bounds.minX + bubbleR, y: bounds.minY))
        path.addArc(tangent1End: bubbleTopRight, tangent2End: bubbleBottomRight, radius: bubbleR)
        path.addLine(to: bubbleBottomRight)
        addVerticalSCurve(to: path, from: bubbleBottomRight, to: stemTopRight)
        path.addArc(tangent1End: stemBottomRight, tangent2End: stemBottomLeft, radius: stemR)
        path.addArc(tangent1End: stemBottomLeft, tangent2End: stemTopLeft, radius: stemR)
        path.addLine(to: stemTopLeft)
        addVerticalSCurve(to: path, from: stemTopLeft, to: bubbleBottomLeft)
        path.addArc(tangent1End: bubbleTopLeft, tangent2End: CGPoint(x: bounds.minX + bubbleR, y: bounds.minY), radius: bubbleR)
        path.closeSubpath()
        return path
    }

    /// Smooth step between two parallel verticals. End tangents stay vertical,
    /// so the neck cannot collapse into a 90° corner.
    private func addVerticalSCurve(to path: CGMutablePath, from start: CGPoint, to end: CGPoint) {
        let handle = (end.y - start.y) * 0.5
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: start.y + handle),
            control2: CGPoint(x: end.x, y: end.y - handle)
        )
    }
}

/// Character preview balloon. Shape is owned by `KeyCalloutShape`.
private final class KeyPreviewView: UIView {
    private let glyphLabel = UILabel()
    private let shapeLayer = CAShapeLayer()
    private var stemWidth: CGFloat = 30
    private var stemCenterX: CGFloat = 30
    private var stemHeight: CGFloat = 42
    private var bubbleHeight: CGFloat = 55
    private var stemCornerRadius: CGFloat = 7
    private var fillColor: UIColor = .white

    static let bubbleCornerRadius: CGFloat = 12
    static let neckHeight: CGFloat = 20
    static let sideOverhang: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 4
        glyphLabel.textAlignment = .center
        glyphLabel.textColor = .label
        glyphLabel.font = Self.calloutFont(forBubbleHeight: 55)
        glyphLabel.adjustsFontSizeToFitWidth = true
        glyphLabel.minimumScaleFactor = 0.7
        addSubview(glyphLabel)
        shapeLayer.strokeColor = nil
        shapeLayer.lineWidth = 0
        layer.insertSublayer(shapeLayer, at: 0)
    }

    required init?(coder: NSCoder) { nil }

    private static func calloutFont(forBubbleHeight height: CGFloat) -> UIFont {
        let largeTitle = UIFont.preferredFont(forTextStyle: .largeTitle).pointSize
        return .systemFont(ofSize: min(largeTitle, max(22, height - 12)), weight: .light)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        glyphLabel.frame = CGRect(
            x: 4,
            y: 0,
            width: max(0, bounds.width - 8),
            height: max(0, bubbleHeight)
        )
        let stemX = min(max(stemCenterX - stemWidth / 2, 0), max(0, bounds.width - stemWidth))
        let shape = KeyCalloutShape(
            stemRect: CGRect(
                x: stemX,
                y: max(0, bounds.height - stemHeight),
                width: min(stemWidth, bounds.width),
                height: min(stemHeight, bounds.height)
            ),
            bubbleCornerRadius: Self.bubbleCornerRadius,
            stemCornerRadius: stemCornerRadius,
            neckHeight: Self.neckHeight
        )
        let path = shape.path(in: bounds)
        shapeLayer.path = path
        layer.shadowPath = path
        applyFill()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFill()
    }

    private func applyFill() {
        let resolved = fillColor.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            shapeLayer.fillColor = UIColor(red: red, green: green, blue: blue, alpha: 1).cgColor
        } else {
            shapeLayer.fillColor = UIColor.white.cgColor
        }
        shapeLayer.opacity = 1
    }

    func display(_ title: String) { glyphLabel.text = title }

    func configure(
        stemWidth: CGFloat,
        stemCenterX: CGFloat,
        stemHeight: CGFloat,
        bubbleHeight: CGFloat,
        stemCornerRadius: CGFloat,
        fillColor: UIColor
    ) {
        self.stemWidth = stemWidth
        self.stemCenterX = stemCenterX
        self.stemHeight = stemHeight
        self.bubbleHeight = bubbleHeight
        self.stemCornerRadius = stemCornerRadius
        self.fillColor = fillColor
        glyphLabel.font = Self.calloutFont(forBubbleHeight: bubbleHeight)
        applyFill()
        setNeedsLayout()
    }
}

/// Compact dead-key chip for a pending Wijesekara kombuwa. Marked text
/// splits Sinhala clusters in many hosts, so the mark lives here until a
/// consonant arrives and we insert the finished syllable once.
private final class PendingCompositionChip: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.46, alpha: 1) : .systemBackground
        }
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 1.5
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .label
        label.font = .systemFont(ofSize: 22, weight: .regular)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func display(_ text: String) { label.text = text }
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
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.46, alpha: 1) : .systemBackground
        }
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 1.5
        selectionLayer.backgroundColor = UIColor.systemBlue.cgColor
        selectionLayer.cornerRadius = 7
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
            label.font = .systemFont(ofSize: 27, weight: .regular)
            label.textAlignment = .center
            stack.addArrangedSubview(label)
            labels.append(label)
        }
        updateLabelColors()
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSelection(animated: false)
    }

    func select(at point: CGPoint) -> Int {
        let contentWidth = (bounds.width - 8) / CGFloat(max(labels.count, 1))
        let index = min(max(Int((point.x - 4) / contentWidth), 0), labels.count - 1)
        guard index != selectedIndex else { return selectedIndex }
        selectedIndex = index
        updateSelection(animated: true)
        updateLabelColors()
        return index
    }

    func select(index: Int) {
        selectedIndex = min(max(index, 0), labels.count - 1)
        updateSelection(animated: false)
        updateLabelColors()
    }

    private func updateSelection(animated: Bool) {
        guard !labels.isEmpty else { return }
        let itemWidth = (bounds.width - 8) / CGFloat(labels.count)
        let frame = CGRect(x: 4 + CGFloat(selectedIndex) * itemWidth, y: 4, width: itemWidth, height: bounds.height - 8)
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

    private func updateLabelColors() {
        labels.enumerated().forEach { index, label in
            label.textColor = index == selectedIndex ? .white : .label
        }
    }
}

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback, UIGestureRecognizerDelegate {
    private static let topEmojiKeyPrefix = "topEmoji:"
    /// Bottom-row URL/email/twitter punctuation. Distinct from letter-row
    /// keys so Wijesekara's `.` → ග mapping does not steal the period.
    private static let contextualKeyPrefix = "context:"
    private static let oneWordEnglishSpaceTitle = "English · one word"
    private static let layoutLogger = Logger(
        subsystem: "lk.org.akshara.keyboard",
        category: "KeyboardLayout"
    )
    /// Layout tracing is intentionally opt-in. Formatting hierarchy snapshots
    /// and writing NSLog lines during constraint passes delays keyboard
    /// presentation even when no developer is reading the console.
    private static let layoutTraceEnabled = ProcessInfo.processInfo.environment["AKSHARA_LAYOUT_TRACE"] == "1"
    private enum Layer { case letters, numbers, symbols }
    /// KeyboardKit's device configurations are a useful model here: a full
    /// iPad keyboard is not a stretched iPhone keyboard.  It has taller keys,
    /// a different action placement, and needs to respond when an iPad enters
    /// Split View or uses the floating keyboard.
    private enum LayoutProfile: Equatable {
        case phonePortrait, phoneLandscape, compactPad, padPortrait, padLandscape
    }

    /// Horizontal proportions are derived from the available keyboard width.
    /// At 393 pt this intentionally lands very close to the previous measured
    /// values, while allowing larger and smaller phones to retain the native
    /// keyboard's relationships.
    private struct KeyboardMetrics {
        let width: CGFloat
        let usesIOS16Appearance: Bool

        var horizontalInset: CGFloat {
            if usesIOS16Appearance || width < 380 { return 5 }
            // The current UK layout's leading edge lands at 20 px on a 3x
            // phone display (6⅔ pt), rather than a rounded 7 pt.
            return KeyboardPreferences.hotPath.keySpacing == .standard ? 20 / 3 : 7
        }

        var horizontalGap: CGFloat { CGFloat(KeyboardPreferences.hotPath.keySpacingHorizontalGap) }

        private var usableWidth: CGFloat {
            max(0, width - horizontalInset * 2)
        }

        var tenKeyWidth: CGFloat {
            // The extension can construct its first view hierarchy while its
            // host input view is still zero-width. Never turn that temporary
            // state into a negative explicit key-width constraint.
            max(0, (usableWidth - horizontalGap * 9) / 10)
        }

        var englishSecondRowInset: CGFloat {
            max(0, (usableWidth - (tenKeyWidth * 9 + horizontalGap * 8)) / 2)
        }

        var englishThirdRowUtilityWidth: CGFloat {
            max(0, (usableWidth - (tenKeyWidth * 7 + horizontalGap * 8)) / 2)
        }

        var standardEnglishThirdRowUtilityWidth: CGFloat { tenKeyWidth * 1.36 }

        var standardEnglishThirdRowInnerGap: CGFloat {
            max(
                horizontalGap,
                (usableWidth - (standardEnglishThirdRowUtilityWidth * 2 + tenKeyWidth * 7 + horizontalGap * 6)) / 2
            )
        }

        var englishBottomSmallKeyWidth: CGFloat { tenKeyWidth * 1.30 }
        var englishReturnKeyWidth: CGFloat { tenKeyWidth * 2.80 }
        var standardEnglishBottomSmallKeyWidth: CGFloat { tenKeyWidth * 1.295 }
        var standardEnglishReturnKeyWidth: CGFloat { tenKeyWidth * 2.78 }
        /// The 123 / #+= and Delete caps bookend the five punctuation keys.
        /// Match the established Sinhala bottom-control width so Backspace is
        /// not compressed while punctuation absorbs the remaining row width.
        var numberSymbolControlWidth: CGFloat { scaledPhoneWidth(56) }
        /// Keep iPad controls proportional to the actual input-view width,
        /// including Split View, instead of pinning them to 58 points.
        var padBottomControlWidth: CGFloat { min(72, max(48, usableWidth * 0.075)) }

        /// Non-English rows have intentionally different key counts. Scale
        /// their existing proportions rather than forcing ten-key metrics
        /// onto a Sinhala-specific arrangement.
        func scaledPhoneWidth(_ reference: CGFloat) -> CGFloat {
            max(0, reference * usableWidth / 379)
        }
    }
    private var layer: Layer = .letters
    private var shift = false
    private var rawBuffer = ""
    private var phoneticBuffer = ""
    private var lastPhoneticRendered = ""
    /// The host context immediately before the unmarked phonetic preview.
    /// It lets us stop deleting exactly at the composition boundary even when
    /// host apps disagree on whether a Sinhala cluster is one or many units.
    private var phoneticCompositionAnchor: String?
    /// The phonetic compositor needs a short look-behind window so a later
    /// vowel can replace a consonant's provisional virama. Commit older,
    /// unambiguous chunks so host editors are not asked to rewrite an
    /// ever-growing unmarked preview.
    private var committedPhoneticSegments: [(source: String, rendered: String)] = []
    private let maximumLivePhoneticSourceLength = PhoneticLiveWindow.defaultMaximumSourceLength
    private var visibleEntries: [String] = []
    private var visibleSources: [String] = []
    /// Local Wijesekara kombuwa / independent-vowel buffer. The current
    /// rendering is already in the host and is rewritten if a later key
    /// completes the syllable.
    private enum PendingCompositionKind { case prebase, independentVowel }
    private var pendingSource: String?
    private var pendingKind: PendingCompositionKind?
    /// Exact glyphs already written for the pending cluster, if any.
    private var pendingHostRendered: String?
    /// Host context captured before that cluster, so a rewrite of කෙ → කේ
    /// can stop deleting if a host treats the syllable as one unit.
    private var pendingHostAnchor: String?
    /// Key that started the dead-key, used to keep the chip and ring in place.
    private var pendingAnchorKey: String?
    private var lastLetterKey: String?
    private var pendingCompositionChip: PendingCompositionChip?
    private var lastInputTimestamp: TimeInterval = 0
    /// Own `insertText` / `deleteBackward` calls notify `textDidChange`.
    /// Ignore those so the next letter does not read proxy context.
    private var isApplyingOwnEdit = false
    private var ownEditDepth = 0
    private var ownEditGeneration = 0
    private var ownEditClearWork: DispatchWorkItem?
    private var selectedSinhalaMode: SinhalaEngine.Mode = .sls
    private var language: KeyboardLanguage = .sinhala
    private var mode: SinhalaEngine.Mode {
        get { language == .english ? .smartPhonetic : selectedSinhalaMode }
        set { selectedSinhalaMode = newValue }
    }
    private var englishEnabled = false
    private lazy var englishProvider = EnglishPredictionProvider()
    private var englishOwnedWord = ""
    private var englishCanLearnWord = false
    private var englishDisplayedContext: EnglishWordContext?
    private var englishCorrection: (context: EnglishWordContext, replacement: String)?
    private weak var languageTransitionOverlay: UIView?
    private var activePredictionProvider: SinhalaPredictionProviding {
        language == .english ? englishProvider : SinhalaPredictionProviderRegistry.shared.activeProvider
    }
    private var lastSpaceTimestamp: TimeInterval?
    /// One reversible replacement, valid only while the cursor remains after
    /// the corrected word and delimiter. It is never inferred from host text.
    private struct PendingAutocorrection {
        let original: String
        let replacement: String
        let suffix: String
    }
    private var pendingAutocorrection: PendingAutocorrection?
    /// After Space following `(`, `"`, or similar, the next character eats
    /// that gap so `" hello` becomes `"hello` without a context read on every
    /// later letter.
    private var collapseSpaceAfterOpeningPunctuation = false
    /// Bottom-anchored keyboard strip. Subviews may overflow the top into
    /// the Liquid Glass lip; default UIView hit-testing would miss those taps.
    private final class OverflowHitView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            if super.point(inside: point, with: event) { return true }
            for subview in subviews where subview.isUserInteractionEnabled && !subview.isHidden {
                let local = convert(point, to: subview)
                if subview.point(inside: local, with: event) { return true }
            }
            return false
        }
    }

    /// UIKit can temporarily give a keyboard extension a full-screen root
    /// frame while it attaches to a host. Keep the actual keyboard in this
    /// bottom-anchored, fixed-height container so it is usable immediately
    /// without allowing equal-height rows to stretch into that transient frame.
    private let keyboardContentContainer = OverflowHitView()
    /// Pre-iOS 26 keyboard colour. Left clear so the host material — including
    /// Spotlight translucency — is the only backdrop. Same on iOS 26.
    private let keyboardChrome = UIView()
    private let keyboardStack = KeyboardGridView()
    // Attached to the root, which survives replacing the keys during a hold.
    private lazy var numberDragRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleNumberDrag(_:)))
        recognizer.minimumPressDuration = 0.25
        recognizer.allowableMovement = 40
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }()
    private var numberDragActive = false
    private weak var numberDragSelection: NativeKeyButton?
    private let candidateBar = CandidateRailView()
    private var candidateBarHeight: NSLayoutConstraint!
    private var candidateBarTopInset: NSLayoutConstraint!
    private var keyboardStackTopInset: NSLayoutConstraint!
    private var keyboardStackBottomInset: NSLayoutConstraint!
    private var keyboardContentBottomInset: NSLayoutConstraint!
    private var keyboardContentHeight: NSLayoutConstraint!
    /// Host height at priority 999. Created in `configureLayout` but not
    /// activated until `updateViewConstraints()` after `viewWillAppear`, so
    /// it does not interrupt UIKit's initial remote-keyboard size negotiation.
    private var keyboardHostHeight: NSLayoutConstraint?
    /// Gates host-height activation. `updateViewConstraints` can run during
    /// load, before the keyboard host has finished its first layout pass.
    private var isPreparingToAppear = false
    private var keyboardLeadingInset: NSLayoutConstraint!
    private var keyboardTrailingInset: NSLayoutConstraint!
    private var metricConstraints: [(NSLayoutConstraint, () -> CGFloat)] = []
    private var metricMargins: [(UIStackView, () -> UIEdgeInsets)] = []
    private var metricCapInsets: [(NativeKeyButton, () -> UIEdgeInsets)] = []
    private var candidateButtons: [CandidateButton] = []
    /// Up to two emoji chips that share the right third of the suggestion rail.
    private var emojiCandidateButtons: [CandidateButton] = []
    private var emojiCandidateStack: UIStackView?
    private var candidates: [String?] = [nil, nil, nil]
    private var emojiCandidates: [String?] = [nil, nil]
    private var predictionPrefix = ""
    /// When an edit resumes inside an already-written word, UIKit only gives
    /// us the text before the caret. Keep that prefix for this local composing
    /// session so prediction starts from the complete word rather than the
    /// first newly typed letter (for example, `ගෙද` + Backspace + `ර`).
    private var inheritedPredictionPrefix = ""
    /// Empty-context openers stay off the rail until the user types. Next-word
    /// and completions can run after that.
    private var hasEnteredTextThisAppearance = false
    private let predictionQueue = DispatchQueue(label: "lk.org.akshara.prediction", qos: .userInitiated)
    private var predictionGeneration = 0
    private var pendingPredictionToken: PredictionCancellationToken?
    /// Set by UIKit when the host editor can have changed independently of
    /// this extension. A live composition also validates its host rendering
    /// before the next key: some hosts send their reset callback while an
    /// extension-owned edit is still being coalesced.
    private var documentStateMayHaveChanged = true
    /// Last `UITextDocumentProxy.documentIdentifier` observed while attached.
    /// A change is a new field even when document context is nil.
    private var lastDocumentIdentifier: UUID?
    /// Preceding-word context for ranking. Refreshed only when the host may
    /// have changed or a word boundary commits — not on every letter.
    private var cachedPrecedingWords: [String] = []
    private var precedingWordsCacheValid = false
    // Transliteration must render in the same touch turn. Candidate ranking is
    // secondary UI, so coalesce it while the user is actively spelling a word
    // instead of scanning the dictionary and redrawing three buttons per key.
    private var pendingPredictionUpdate: DispatchWorkItem?
    /// Guards VoiceOver activate + touch-down from inserting the same chip twice.
    private var lastPredictionInsertAt: TimeInterval = 0
    private var lastInsertedPrediction: String?
    private var emojiPicker: EmojiPickerView?
    private var clipboardHistoryPanel: ClipboardHistoryView?
    private var clipboardRefreshTimer: Timer?
    private let clipboardButton = UIButton(type: .system)
    private var candidateSegmentsLeading: NSLayoutConstraint!
    private var pasteboardObserver: NSObjectProtocol?
    private let clipboardButtonWidth: CGFloat = 36
    private let trackpadSurface = UIView()
    private var deleteRepeater: Timer?
    /// True for the whole hold, including the brief gap where the character
    /// timer is replaced by the slower word timer.
    private var isDeleteRepeatActive = false
    /// First Delete touch-down of the current hold, used to switch from
    /// character repeat to word repeat like the system keyboard.
    private var deleteRepeatBeganAt: TimeInterval = 0
    private var deleteRepeatUsesWords = false
    /// The control that started this hold. Used to keep repeating if the
    /// long-press recognizer is cancelled while the finger is still down.
    private weak var deleteRepeatAnchor: UIView?
    private weak var deleteRepeatRecognizer: UILongPressGestureRecognizer?
    /// Backup hold starter that does not depend on UILongPress surviving the
    /// first `deleteBackward` host round-trip.
    private var deleteHoldWork: DispatchWorkItem?
    /// Brief tracking gaps after a host cancel must not kill an in-progress hold.
    private var deleteRepeatLostTouchAt: TimeInterval?
    private var keyPreview: KeyPreviewView?
    private var alternatePicker: AlternateCharacterPickerView?
    private var presentedAlternateChoices: [(display: String, input: String)] = []
    private var keyFeedback: KeyFeedback?
    // The language-label transition is an input-session introduction, not a
    // key-layer transition. Rebuilding for Shift or 123 must keep it quiet.
    private var shouldAnimateSpaceLabel = true
    private var isSpaceTrackpadActive = false
    private var spaceTrackpadLastX: CGFloat = 0
    private var spaceTrackpadRemainder: CGFloat = 0
    private var spaceTrackpadLastTimestamp: TimeInterval = 0
    private var spaceSignatureHoldPending = false
    private var spaceSignatureHoldConsumed = false
    private var spaceSignatureHoldTimer: DispatchWorkItem?
    private var spaceSignatureStartLocation: CGPoint = .zero
    private var spaceSignatureTapCount = 0
    private var spaceSignatureTapTimestamp: TimeInterval = 0
    private var spaceSignatureRestoreWork: DispatchWorkItem?
    private var temporaryLatinWordActive = false
    private var appliedLayoutProfile: LayoutProfile?
    private var appliedLayoutWidth: CGFloat = 0
    private var appliedLayoutHeight: CGFloat = 0
    private var appliedInputViewHeight: CGFloat = 0
    private var appliedSuperviewHeight: CGFloat = 0
    private var lastLoggedLayoutBounds: CGSize = .zero
    /// When the host tray resizes without a disappear/appear cycle, bounce the
    /// height constraint through `updateViewConstraints` the same way switching
    /// keyboards does. Deduped by `lastHostHeightReassertSignature`.
    private var needsHostHeightReassert = false
    private var lastHostHeightReassertSignature = ""
    private var needsKeyRebuildWhenGeometryIsStable = true
    private var appliedReturnKeyTitle: String?
    private var appliedKeyboardType: UIKeyboardType?
    private var appliedAllowsPredictions: Bool?
    // Querying `needsInputModeSwitchKey` before the extension is connected to
    // a host produces a false answer (and a UIKit warning). Wait for both a
    // usable input-view width and the host's `textDidChange` callback.
    private var showsInputModeSwitchKey = false
    private var hasHostTextInputConnection = false
    private var inputModeSwitchKeyRefreshScheduled = false
    /// Last scheme applied to keys. Appearance toggles while the keyboard is
    /// up must rebuild caps; UIButton and SF Symbols otherwise keep the old
    /// resolved colours until the input is switched.
    private var lastSyncedInterfaceStyle: UIUserInterfaceStyle = .unspecified
    private var appearanceRebuildScheduled = false

    private var usesIOS16KeyboardAppearance: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    private var keyboardMetrics: KeyboardMetrics {
        KeyboardMetrics(
            width: max(0, view.bounds.width - oneHandedContentInset),
            usesIOS16Appearance: usesIOS16KeyboardAppearance
        )
    }

    private var oneHandedContentInset: CGFloat {
        switch KeyboardPreferences.oneHandedPosition() {
        case .centered: return 0
        case .left, .right: return 64
        }
    }

    private var layoutProfile: LayoutProfile {
        // An input view is a shallow horizontal strip in every orientation;
        // comparing its own width and height classifies almost every portrait
        // device as landscape. Use the enclosing window scene instead.
        let isLandscape = view.window?.windowScene?.interfaceOrientation.isLandscape
            ?? (view.bounds.width > view.bounds.height)
        // Floating and narrow Split View iPad keyboards are compact even when
        // the enclosing scene is landscape. Their own width is authoritative.
        if UIDevice.current.userInterfaceIdiom == .pad, view.bounds.width < 600 {
            return .compactPad
        }
        let isFullWidthPad = UIDevice.current.userInterfaceIdiom == .pad
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
        case .phonePortrait, .phoneLandscape, .compactPad: return false
        }
    }

    private var candidateHeight: CGFloat {
        switch layoutProfile {
        case .padPortrait, .padLandscape: return 44
        case .phoneLandscape: return 28
        // Liquid Glass matches the compact UK rail. Classic trays keep a
        // real QuickType band; 26 pt left Sinhala and emoji clipped in
        // Classic Host.
        case .phonePortrait:
            if usesLiquidGlassKeyboardChrome { return 26 }
            return 36
        case .compactPad:
            return usesLiquidGlassKeyboardChrome ? 25.5 : 32
        }
    }

    /// Clearance below rounded chrome on pre-glass keyboards. Liquid Glass
    /// uses `liquidGlassTopLip` instead: the host already clips to the capsule,
    /// and a second layout inset just leaves a dead strip under the curve.
    private var contentTopInset: CGFloat {
        if usesLiquidGlassKeyboardChrome { return 0 }
        guard layoutProfile == .phonePortrait || layoutProfile == .compactPad else { return 0 }
        // iOS 26 compatibility trays still round the top of the keyboard
        // card. 4 pt was enough before glass; 8 pt keeps chips under the clip.
        if #available(iOS 26.0, *) { return 8 }
        return 4
    }

    /// Extra points the host added above the calibrated strip. Visibility
    /// treats ±8 pt as settled, so a few points of Liquid Glass lip can sit
    /// unused above the rail. Attach frames are hundreds of points and are
    /// ignored. KeyboardKit cannot change that system frame either; it only
    /// matches the capsule with a top corner radius.
    ///
    /// Take the largest in-range extra from view / input view / superview.
    /// Our height constraint pins `view`, so that frame alone hides the lip.
    private var liquidGlassTopLip: CGFloat {
        guard usesLiquidGlassKeyboardChrome, showsCandidateBar else { return 0 }
        let extra = glassLipExtra
        guard extra > 0.5 else { return 0 }
        return extra
    }

    /// Positive extra height on a settled keyboard tray. Fullscreen attach
    /// frames are ignored so they cannot look like a lip or like Classic Host.
    private var glassLipExtra: CGFloat {
        let preferred = normalKeyboardHeight
        let frames = [
            view.bounds.height,
            inputView?.bounds.height ?? 0,
            view.superview?.bounds.height ?? 0
        ]
        return frames
            .filter { $0 > 160 && $0 < 400 }
            .map { $0 - preferred }
            .filter { $0 > 0 && $0 < 36 }
            .max() ?? 0
    }

    /// The input view / superview is the tray the user sees. `view` is often
    /// shorter because we pin it to the calibrated key strip.
    private var hostTrayHeight: CGFloat {
        max(inputView?.bounds.height ?? 0, view.superview?.bounds.height ?? 0, view.bounds.height)
    }

    /// Gap between the candidate rail and the first key row. Keep iOS 17+ at
    /// 7 pt so Standard spacing remains the measured UK height; the old +4 pt
    /// transform (and the 11 pt stand-in) made the extension taller than UK.
    private var keyGridTopInset: CGFloat {
        usesIOS16KeyboardAppearance ? 11 : 7
    }

    /// Visual 4 pt shift of the UK grid on a standard portrait phone.
    private var keyGridVerticalNudge: CGFloat {
        usesStandardPhoneGeometry ? 4 : 0
    }

    /// How far the first key row's pale-blue cells extend above the painted
    /// caps. While suggestions are showing this is only a sliver, so a tap
    /// that grazes Q / W / E is still a key.
    private var firstKeyRowTopHit: CGFloat {
        if showsCandidateBar {
            return keyGridVerticalNudge + min(4, keyGridTopInset)
        }
        return keyGridTopInset
    }

    /// Layout gap between the rail and the key stack. The Q row's hit
    /// expansion covers this plus `keyGridVerticalNudge`.
    private var suggestionRailReleasedToKeys: CGFloat {
        guard showsCandidateBar else { return 0 }
        return max(0, firstKeyRowTopHit - keyGridVerticalNudge)
    }

    /// Space under the bottom row, matching the UK dock gap above the globe.
    /// iOS 16 clips about a point of the bottom row; later versions already
    /// have enough inset that this must not change.
    private var keyGridBottomInset: CGFloat {
        usesIOS16KeyboardAppearance ? 3 : 7
    }

    /// Test lift so the bottom row clears the host clip. iOS 26 is already
    /// aligned and must not move.
    private var preLiquidGlassBottomLift: CGFloat {
        if #available(iOS 26.0, *) { return 0 }
        if usesIOS16KeyboardAppearance { return 1 }
        if #available(iOS 18.0, *) { return 1 }
        return 0
    }

    /// The rail view owns the toolbar band down to a sliver above the Q row.
    /// That sliver stays on the keys so a grazing tap is not a suggestion.
    /// Chips stay in the middle via layout margins. Total keyboard height is
    /// unchanged because the stack's top inset absorbs what the rail releases,
    /// and the glass lip is host oversize rather than extra reported height.
    private var candidateBarOccupiedHeight: CGFloat {
        guard showsCandidateBar else { return 0 }
        let railBottomPadding = max(0, keyGridTopInset - suggestionRailReleasedToKeys)
        return candidateHeight + contentTopInset + railBottomPadding + liquidGlassTopLip
    }

    private func applyCandidateBarLayout() {
        let showing = showsCandidateBar
        // The content container already includes the lip in its height, so
        // the rail sits at the top of that strip. A second negative inset
        // would park the chips in the curve and clip the well colour.
        let topInset = showing ? 0 : contentTopInset
        let height = showing ? candidateBarOccupiedHeight : 0
        let stackInset = showing ? suggestionRailReleasedToKeys : keyGridTopInset
        var changed = false
        if candidateBarTopInset?.constant != topInset {
            candidateBarTopInset?.constant = topInset
            changed = true
        }
        if candidateBarHeight?.constant != height {
            candidateBarHeight?.constant = height
            changed = true
        }
        if keyboardStackTopInset?.constant != stackInset {
            keyboardStackTopInset?.constant = stackInset
            changed = true
        }
        if changed { candidateBar.setNeedsLayout() }
    }

    /// True on iOS 26, matching KeyboardKit's OS-version glass flag.
    private var usesLiquidGlassKeyboardChrome: Bool {
        KeyboardChromeAppearance.usesLiquidGlassSurfaces
    }

    /// Preserve the calibrated standard-keyboard geometry from the release
    /// before layout customisation. The system still owns presentation, while
    /// this provides the content height needed for the established keycaps.
    private var normalKeyboardBaseHeight: CGFloat {
        let topRowHeight: CGFloat = KeyboardPreferences.topRow() == .disabled
            ? 0
            : (usesPadLayout
                ? 58
                : (layoutProfile == .phoneLandscape
                    ? 39
                    : (usesStandardPhoneGeometry ? 54 : 52)))
        switch layoutProfile {
        case .padPortrait: return 292 + topRowHeight
        case .padLandscape: return 374 + topRowHeight
        case .phoneLandscape: return 162 + topRowHeight
        // UK on the iPhone 17 Pro uses four 43 pt key rows with three 11 pt
        // gaps. With the candidate rail and the existing top/bottom insets,
        // 219 pt preserves that geometry exactly for Standard spacing.
        case .phonePortrait: return (usesStandardPhoneGeometry ? 219 : 214) + topRowHeight + contentTopInset
        case .compactPad: return 214 + topRowHeight + contentTopInset
        }
    }

    private var usesStandardPhoneGeometry: Bool {
        layoutProfile == .phonePortrait && KeyboardPreferences.hotPath.keySpacing == .standard
    }

    /// Uniform UK portrait key height. Phonetic, Smart Phonetic, and
    /// Wijesekara share this; only key widths differ by layout.
    private var standardPhoneRowHeight: CGFloat? {
        usesStandardPhoneGeometry ? 43 : nil
    }

    /// All Sinhala layouts share the candidate rail. Direct Wijesekara input
    /// does not need transliteration candidates, but it does use this rail for
    /// word prediction once a local prediction provider is enabled.
    private var showsCandidateBar: Bool {
        KeyboardPreferences.hotPath.suggestionsEnabled && inputFieldAllowsPredictions
    }

    /// Structured fields and search UI hide QuickType on the system keyboard.
    /// Match that so Spotlight, in-app search, passwords, and identifier
    /// fields do not get a Sinhala suggestion rail.
    private var inputFieldAllowsPredictions: Bool {
        let proxy = textDocumentProxy
        if proxy.isSecureTextEntry == true { return false }
        if proxy.autocorrectionType == .no { return false }
        switch proxy.keyboardType {
        case .URL, .webSearch, .emailAddress, .twitter,
             .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad:
            return false
        default:
            break
        }
        switch proxy.returnKeyType {
        case .search, .google, .yahoo:
            return false
        default:
            break
        }
        if let contentType = proxy.textContentType {
            switch contentType {
            case .username, .password, .newPassword, .oneTimeCode,
                 .emailAddress, .URL, .telephoneNumber, .creditCardNumber,
                 .postalCode, .flightNumber, .shipmentTrackingNumber:
                return false
            default:
                break
            }
        }
        return true
    }

    private var normalKeyboardHeight: CGFloat {
        self.normalKeyboardBaseHeight + (showsCandidateBar ? candidateHeight : 0)
    }

    /// Apple's emoji picker expands the input view instead of squeezing the
    /// same four rows into the alphabet keyboard's height.  Keep the extra
    /// working room local to Emoji mode so the calibrated Sinhala layout is
    /// unchanged.  On a portrait phone, 60 pt matches the observed system
    /// emoji-selector lift; wider layouts need less vertical compensation.
    private var emojiPickerAdditionalHeight: CGFloat {
        switch layoutProfile {
        case .phonePortrait: return 60
        case .compactPad: return 52
        case .padPortrait, .padLandscape: return 44
        case .phoneLandscape: return 28
        }
    }

    private var presentedKeyboardHeight: CGFloat {
        normalKeyboardHeight
            + (emojiPicker == nil ? 0 : emojiPickerAdditionalHeight)
    }

    /// Reported host height plus any Liquid Glass lip the host already added.
    /// The content strip stays bottom-anchored at `normalKeyboardHeight` for
    /// key geometry; this extra height only fills the capsule above the rail
    /// so the well colour is not cut off inside the curve.
    private var keyboardContentOccupiedHeight: CGFloat {
        presentedKeyboardHeight + (emojiPicker == nil ? liquidGlassTopLip : 0)
    }

    private var lastLoggedHostHeightReport: CGFloat?

    private var isKeyboardOverlayPresented: Bool {
        emojiPicker != nil || clipboardHistoryPanel != nil
    }

    private func applyHostHeightConstraint(reason: String) {
        let height = presentedKeyboardHeight
        let contentHeight = keyboardContentOccupiedHeight
        let constantChanged = abs((keyboardHostHeight?.constant ?? 0) - height) > 0.5
        keyboardHostHeight?.constant = height
        preferredContentSize = CGSize(width: max(view.bounds.width, 1), height: height)
        keyboardContentHeight?.constant = contentHeight
        if !isKeyboardOverlayPresented {
            applyCandidateBarLayout()
        }
        if isPreparingToAppear, keyboardHostHeight?.isActive == false {
            view.setNeedsUpdateConstraints()
        } else if constantChanged, keyboardHostHeight?.isActive == true {
            // Preferred height changed while visible (suggestions on/off,
            // rotation). The host often keeps the old tray until this
            // constraint is requested again through `updateViewConstraints`.
            requestHostHeightReassert(reason: reason, force: true)
        }
        if Self.layoutTraceEnabled, lastLoggedHostHeightReport != height {
            lastLoggedHostHeightReport = height
            Self.layoutLogger.debug(
                "hostHeight \(reason, privacy: .public) reported=\(Int(height), privacy: .public) active=\(self.keyboardHostHeight?.isActive == true, privacy: .public)"
            )
            NSLog(
                "[AKSHARA-HEIGHT] hostHeight %@ reported=%d active=%d",
                reason,
                Int(height),
                keyboardHostHeight?.isActive == true ? 1 : 0
            )
        }
    }

    /// The container fixes the content height, so width is the only geometry
    /// required before it is safe to build keys. Keys stay bottom-anchored in
    /// UIKit's temporary full-height attachment frame without stretching.
    private var hasUsableKeyboardWidth: Bool {
        view.bounds.width > 0
    }

    /// Host chrome (glass lip, classic tray, accessory / call bar) can resize
    /// the input view or our superview without changing this controller's
    /// requested height. Those frames are what users see as "layout height
    /// that is not ours."
    private func hostTrayHeightChanged() -> Bool {
        let inputH = inputView?.bounds.height ?? 0
        let superH = view.superview?.bounds.height ?? 0
        if appliedInputViewHeight == 0, appliedSuperviewHeight == 0 {
            return false
        }
        return abs(inputH - appliedInputViewHeight) > 0.5
            || abs(superH - appliedSuperviewHeight) > 0.5
    }

    private func rememberHostTrayHeight() {
        appliedInputViewHeight = inputView?.bounds.height ?? 0
        appliedSuperviewHeight = view.superview?.bounds.height ?? 0
    }

    /// Ask the host to re-read our height request without a keyboard switch.
    /// Skips UIKit's provisional full-screen attach frame, and dedupes so a
    /// settled glass lip does not bounce every layout pass.
    private func requestHostHeightReassert(reason: String, force: Bool) {
        guard isPreparingToAppear, emojiPicker == nil else { return }
        guard keyboardHostHeight?.isActive == true else { return }
        guard hasUsableKeyboardWidth else { return }
        let preferred = normalKeyboardHeight
        let actual = view.bounds.height
        let extra = actual - preferred
        // Fullscreen attach (often ~874 pt) must not bounce the constraint.
        if extra >= 80 { return }
        // Classic hosts often ignore an 8 pt shortfall and clip the rail.
        // Reassert as soon as the tray is actually shorter than requested.
        let tooShort = extra < (usesLiquidGlassKeyboardChrome ? -8 : -1)
        guard force || tooShort else { return }
        let inputH = inputView?.bounds.height ?? actual
        let superH = view.superview?.bounds.height ?? actual
        let signature = "\(Int(preferred))|\(Int(actual))|\(Int(inputH))|\(Int(superH))"
        guard signature != lastHostHeightReassertSignature else { return }
        lastHostHeightReassertSignature = signature
        needsHostHeightReassert = true
        view.setNeedsUpdateConstraints()
        logKeyboardLayout("host-height reassert \(reason)")
    }

    private func logKeyboardLayout(_ event: String) {
        guard Self.layoutTraceEnabled else { return }
        let bounds = view.bounds.size
        let frame = view.frame.size
        let inputBounds = inputView?.bounds.size ?? .zero
        let profile = String(describing: layoutProfile)
        let contentH = keyboardContentHeight?.constant ?? -1
        let hostH = keyboardHostHeight?.constant ?? -1
        let hostActive = keyboardHostHeight?.isActive == true
        let containerH = keyboardContentContainer.bounds.height
        let superH = view.superview?.bounds.height ?? -1
        let windowSize = view.window?.bounds.size ?? .zero
        let preferred = normalKeyboardHeight
        let oversize = max(0, bounds.height - preferred)
        let preparing = isPreparingToAppear
        Self.layoutLogger.debug(
            """
            \(event, privacy: .public) \
            bounds=\(Int(bounds.width), privacy: .public)x\(Int(bounds.height), privacy: .public) \
            frame=\(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public) \
            input=\(Int(inputBounds.width), privacy: .public)x\(Int(inputBounds.height), privacy: .public) \
            preferredHeight=\(Int(preferred), privacy: .public) \
            contentH=\(Int(contentH), privacy: .public) \
            hostH=\(Int(hostH), privacy: .public) \
            hostActive=\(hostActive, privacy: .public) \
            preparing=\(preparing, privacy: .public) \
            containerH=\(Int(containerH), privacy: .public) \
            superH=\(Int(superH), privacy: .public) \
            window=\(Int(windowSize.width), privacy: .public)x\(Int(windowSize.height), privacy: .public) \
            oversize=\(Int(oversize), privacy: .public) \
            glassLip=\(Int(self.liquidGlassTopLip), privacy: .public) \
            alpha=\(String(format: "%.2f", self.view.alpha), privacy: .public) \
            glass=\(self.usesLiquidGlassKeyboardChrome, privacy: .public) \
            ready=\(self.hasUsableKeyboardWidth, privacy: .public) \
            profile=\(profile, privacy: .public) \
            pending=\(self.needsKeyRebuildWhenGeometryIsStable, privacy: .public)
            """
        )
        NSLog(
            "[AKSHARA-HEIGHT] %@ view=%.0fx%.0f input=%.0fx%.0f window=%.0fx%.0f hostActive=%d preparing=%d preferred=%.0f oversize=%.0f",
            event,
            bounds.width,
            bounds.height,
            inputBounds.width,
            inputBounds.height,
            windowSize.width,
            windowSize.height,
            hostActive ? 1 : 0,
            preparing ? 1 : 0,
            preferred,
            oversize
        )
    }

    /// When the host is tall, dump the view chain so we can tell whether the
    /// flash is our controller, UIInputView, or a sibling system backdrop.
    private func logTallHostHierarchy(_ reason: String) {
        guard Self.layoutTraceEnabled else { return }
        var parts: [String] = []
        var node: UIView? = view
        for depth in 0..<10 {
            guard let current = node else { break }
            let name = String(describing: type(of: current))
            let bg: String
            if let color = current.backgroundColor {
                bg = String(format: "bg=%.2f", color.cgColor.alpha)
            } else {
                bg = "bg=nil"
            }
            parts.append(
                "[\(depth)]\(name) \(Int(current.bounds.width))x\(Int(current.bounds.height)) \(bg) alpha=\(String(format: "%.2f", current.alpha)) hidden=\(current.isHidden)"
            )
            if let parent = current.superview {
                for sibling in parent.subviews where sibling !== current {
                    let siblingName = String(describing: type(of: sibling))
                    if sibling.bounds.height > normalKeyboardHeight + 72
                        || siblingName.localizedCaseInsensitiveContains("backdrop")
                        || siblingName.localizedCaseInsensitiveContains("glass")
                        || siblingName.contains("UIKB") {
                        parts.append(
                            "  sibling:\(siblingName) \(Int(sibling.bounds.width))x\(Int(sibling.bounds.height))"
                        )
                    }
                }
            }
            node = current.superview
        }
        let chain = parts.joined(separator: " | ")
        Self.layoutLogger.debug(
            "tall hierarchy reason=\(reason, privacy: .public) \(chain, privacy: .public)"
        )
    }

    var enableInputClicksWhenVisible: Bool { KeyboardPreferences.hotPath.keyClicksEnabled }

    override func loadView() {
        // KeyboardKit does not wrap the extension in `UIInputView.keyboard`.
        // That style tints a second backdrop and reads as a solid card in
        // translucent hosts (Spotlight, Safari). A plain view lets the host
        // draw the only surface. iOS 26 already uses this path for Liquid Glass.
        if #available(iOS 26.0, *) {
            let root = UIView(frame: .zero)
            root.backgroundColor = .clear
            root.clipsToBounds = false
            view = root
        } else {
            let root = UIView(frame: .zero)
            root.backgroundColor = .clear
            root.isOpaque = false
            root.clipsToBounds = false
            view = root
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        logKeyboardLayout("viewDidLoad")
        KeyboardPreferences.refreshHotPathCache()
        updateKeyboardAppearance()
        mode = KeyboardPreferences.selectedMode()
        language = KeyboardPreferences.activeLanguage()
        englishEnabled = KeyboardPreferences.englishKeyboardEnabled()
        configureLayout()
        view.addGestureRecognizer(numberDragRecognizer)
        keyFeedback = KeyFeedback(view: view)
        keyFeedback?.prepare()
        needsKeyRebuildWhenGeometryIsStable = true
        registerForUserInterfaceStyleChanges()
        logKeyboardLayout("viewDidLoad after configure")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isPreparingToAppear = true
        hasEnteredTextThisAppearance = false
        applyHostHeightConstraint(reason: "viewWillAppear")
        // Compatibility hosts on iOS 26 sometimes skip `updateViewConstraints`
        // for the first presentation. Activate here so the tray is not stuck
        // at a stub height that clips the rail and the first key row.
        if let constraint = keyboardHostHeight, !constraint.isActive {
            constraint.constant = normalKeyboardHeight
            constraint.isActive = true
        }
        view.setNeedsUpdateConstraints()
        logKeyboardLayout("viewWillAppear")
        KeyboardPreferences.reload()
        documentStateMayHaveChanged = true
        precedingWordsCacheValid = false
        KeyboardPreferences.setFullAccessConfirmed(hasFullAccess)
        let selectedMode = KeyboardPreferences.selectedMode()
        var needsRebuild = keyboardStack.arrangedSubviews.isEmpty
        let newLanguage = KeyboardPreferences.activeLanguage()
        let newEnglishEnabled = KeyboardPreferences.englishKeyboardEnabled()
        if newLanguage != language || newEnglishEnabled != englishEnabled {
            cancelLocalCompositionWithoutCommit()
            language = newLanguage
            englishEnabled = newEnglishEnabled
            layer = .letters
            needsRebuild = true
        }
        if selectedMode != selectedSinhalaMode {
            cancelLocalCompositionWithoutCommit()
            mode = selectedMode
            needsRebuild = true
        }
        if noteDocumentIdentifierChange() {
            cancelLocalCompositionWithoutCommit()
        }
        shouldAnimateSpaceLabel = true
        updateKeyboardAppearance()
        lastSyncedInterfaceStyle = view.traitCollection.userInterfaceStyle
        refreshKeyboardChrome(rebuildIfStyleChanged: false)
        keyFeedback?.prepare()
        let title = returnKeyTitle
        let keyboardType = textDocumentProxy.keyboardType
        let allowsPredictions = inputFieldAllowsPredictions
        if appliedKeyboardType != nil, keyboardType != appliedKeyboardType {
            cancelLocalCompositionWithoutCommit()
        }
        if title != appliedReturnKeyTitle
            || keyboardType != appliedKeyboardType
            || appliedAllowsPredictions != allowsPredictions {
            appliedReturnKeyTitle = title
            appliedKeyboardType = keyboardType
            appliedAllowsPredictions = allowsPredictions
            needsRebuild = true
        }
        if needsRebuild {
            rebuildKeys()
        } else {
            applyKeyboardMetrics()
            updateClipboardButtonVisibility()
        }
        startClipboardCaptureIfNeeded()
    }

    override func updateViewConstraints() {
        if isPreparingToAppear, let constraint = keyboardHostHeight {
            constraint.constant = presentedKeyboardHeight
            if needsHostHeightReassert, constraint.isActive {
                // Drop and re-add so the host re-reads the request. Switching
                // keyboards does the same via disappear → appear.
                constraint.isActive = false
                needsHostHeightReassert = false
                logKeyboardLayout("updateViewConstraints bouncing host height")
            }
            if !constraint.isActive {
                logKeyboardLayout("updateViewConstraints activating host height")
                constraint.isActive = true
            }
        }
        logKeyboardLayout("updateViewConstraints")
        super.updateViewConstraints()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        logKeyboardLayout("viewDidAppear")
        applyHostHeightConstraint(reason: "viewDidAppear")
        refreshKeyboardChrome(rebuildIfStyleChanged: true)
        if keyboardStack.arrangedSubviews.isEmpty {
            rebuildKeys()
        }
        if englishEnabled {
            let provider = englishProvider
            predictionQueue.async { provider.prepareIfNeeded() }
        }
        if showsCandidateBar, language == .sinhala {
            SinhalaPredictionProviderRegistry.shared.prepareBundledModelsInBackground()
        }
        if showsCandidateBar || KeyboardPreferences.hotPath.autocorrectEnabled {
            DispatchQueue.global(qos: .utility).async {
                SinhalaAutocorrectionService.shared.prepareIfNeeded()
            }
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let bounds = view.bounds.size
        if abs(bounds.width - lastLoggedLayoutBounds.width) > 0.5
            || abs(bounds.height - lastLoggedLayoutBounds.height) > 0.5 {
            logKeyboardLayout("viewWillLayoutSubviews")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds.size
        if abs(bounds.width - lastLoggedLayoutBounds.width) > 0.5
            || abs(bounds.height - lastLoggedLayoutBounds.height) > 0.5 {
            lastLoggedLayoutBounds = bounds
            logKeyboardLayout("viewDidLayoutSubviews")
            if bounds.height > normalKeyboardHeight + 8 {
                logTallHostHierarchy("viewDidLayoutSubviews")
            }
        }
        syncKeyboardAppearanceIfNeeded(rebuild: true)
        refreshKeyboardChrome(rebuildIfStyleChanged: true)
        guard hasUsableKeyboardWidth else {
            needsKeyRebuildWhenGeometryIsStable = true
            keyboardStack.isHidden = true
            candidateBar.isHidden = true
            updateClipboardButtonVisibility()
            logKeyboardLayout("deferred zero-width geometry")
            return
        }
        let profile = layoutProfile
        let widthChanged = abs(view.bounds.width - appliedLayoutWidth) > 0.5
        let heightChanged = abs(view.bounds.height - appliedLayoutHeight) > 0.5
        let hostHeightChanged = hostTrayHeightChanged()
        let profileChanged = profile != appliedLayoutProfile
        guard needsKeyRebuildWhenGeometryIsStable
            || profileChanged
            || widthChanged
            || heightChanged
            || hostHeightChanged else { return }
        appliedLayoutProfile = profile
        appliedLayoutWidth = view.bounds.width
        appliedLayoutHeight = view.bounds.height
        rememberHostTrayHeight()
        applyKeyboardMetrics()
        if hostHeightChanged {
            requestHostHeightReassert(reason: "host-tray", force: true)
        } else if heightChanged {
            requestHostHeightReassert(reason: "view-height", force: false)
        }
        refreshInputModeSwitchKeyWhenConnected()
        if needsKeyRebuildWhenGeometryIsStable || profileChanged {
            rebuildKeys()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard isPreparingToAppear, hasUsableKeyboardWidth, emojiPicker == nil else { return }
        applyKeyboardMetrics()
        requestHostHeightReassert(reason: "safe-area", force: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPreparingToAppear = false
        finishNumberDrag()
        stopDeleteRepeat()
        hideKeyPreview(animated: false)
        hideAlternatePicker()
        hideEmojiPicker()
        hideClipboardHistory()
        stopClipboardCapture()
        setTrackpadAppearance(active: false, animated: false)
        pendingPredictionUpdate?.cancel()
        pendingPredictionUpdate = nil
        pendingPredictionToken?.cancel()
        cancelSpaceSignatureHold()
        spaceSignatureRestoreWork?.cancel()
        spaceSignatureRestoreWork = nil
        resetSpaceSignatureTaps()
        hidePendingCompositionChrome()
        cancelLocalCompositionWithoutCommit()
        SinhalaPredictionProviderRegistry.shared.flushPendingPersistence()
        if englishEnabled {
            let provider = englishProvider
            predictionQueue.async { provider.flushPendingPersistence() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Drop the host-height request so the next presentation can wait for
        // `viewWillAppear` → `updateViewConstraints` again.
        keyboardHostHeight?.isActive = false
        needsHostHeightReassert = false
        lastHostHeightReassertSignature = ""
        appliedLayoutHeight = 0
        appliedInputViewHeight = 0
        appliedSuperviewHeight = 0
        pendingAutocorrection = nil
        logKeyboardLayout("viewDidDisappear")
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        guard !isApplyingOwnEdit else { return }
        documentStateMayHaveChanged = true
        updateInputTraitsIfNeeded()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        hasHostTextInputConnection = true
        refreshInputModeSwitchKeyWhenConnected()
        guard !isApplyingOwnEdit else { return }
        // Host-originated edits only. Own inserts also notify some editors;
        // treating those as host changes forces a proxy-context read on the
        // next keystroke.
        documentStateMayHaveChanged = true
        pendingAutocorrection = nil
        updateInputTraitsIfNeeded()
        collapseSpaceAfterOpeningPunctuation = false
        reconcileCompositionStateWithDocument()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard !isApplyingOwnEdit else { return }
        documentStateMayHaveChanged = true
        pendingAutocorrection = nil
        collapseSpaceAfterOpeningPunctuation = false
        reconcileCompositionStateWithDocument()
    }

    private func refreshInputModeSwitchKeyWhenConnected() {
        guard hasHostTextInputConnection,
              hasUsableKeyboardWidth,
              !inputModeSwitchKeyRefreshScheduled else { return }
        inputModeSwitchKeyRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inputModeSwitchKeyRefreshScheduled = false
            guard self.hasHostTextInputConnection, self.hasUsableKeyboardWidth else { return }
            let needsSwitchKey = self.needsInputModeSwitchKey
            guard needsSwitchKey != self.showsInputModeSwitchKey else { return }
            self.showsInputModeSwitchKey = needsSwitchKey
            self.logKeyboardLayout("input mode switch key refreshed")
            self.rebuildKeys()
        }
    }

    private func updateInputTraitsIfNeeded() {
        updateKeyboardAppearance()
        let title = returnKeyTitle
        let keyboardType = textDocumentProxy.keyboardType
        let allowsPredictions = inputFieldAllowsPredictions
        let keyboardTypeChanged = appliedKeyboardType != nil && keyboardType != appliedKeyboardType
        guard title != appliedReturnKeyTitle
            || keyboardType != appliedKeyboardType
            || appliedAllowsPredictions != allowsPredictions else { return }
        if keyboardTypeChanged {
            cancelLocalCompositionWithoutCommit(refreshingPredictions: true)
        }
        appliedReturnKeyTitle = title
        appliedKeyboardType = keyboardType
        appliedAllowsPredictions = allowsPredictions
        rebuildKeys()
    }

    /// A host text field may request a keyboard appearance that differs from
    /// the containing app's trait collection. iOS pushes that onto this
    /// controller's traits. Pinning `overrideUserInterfaceStyle` to
    /// `textDocumentProxy.keyboardAppearance` freezes the scheme from when
    /// the keyboard opened, so Control Center light/dark toggles leave mixed
    /// glass and keycaps until the input is switched.
    private func updateKeyboardAppearance() {
        let style: UIUserInterfaceStyle
        switch KeyboardPreferences.appearance() {
        case .light: style = .light
        case .dark: style = .dark
        case .system: style = .unspecified
        }
        inputView?.overrideUserInterfaceStyle = style
        view.overrideUserInterfaceStyle = style
    }

    private func registerForUserInterfaceStyleChanges() {
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardViewController, _) in
                self.syncKeyboardAppearanceIfNeeded(rebuild: true)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #available(iOS 17.0, *) { return }
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        syncKeyboardAppearanceIfNeeded(rebuild: true)
    }

    private func syncKeyboardAppearanceIfNeeded(rebuild: Bool) {
        updateKeyboardAppearance()
        let style = traitCollection.userInterfaceStyle
        guard style != lastSyncedInterfaceStyle else { return }
        lastSyncedInterfaceStyle = style
        applyKeyboardChromeSurface()
        guard rebuild else { return }
        scheduleAppearanceRebuild()
    }

    private func scheduleAppearanceRebuild() {
        guard !appearanceRebuildScheduled else { return }
        appearanceRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceRebuildScheduled = false
            if let picker = self.emojiPicker {
                picker.refreshDynamicSurfaces()
                return
            }
            guard !self.keyboardStack.arrangedSubviews.isEmpty else { return }
            self.rebuildKeys()
        }
    }

    /// KeyboardKit leaves `KeyboardViewStyle.background` nil so the system
    /// surface shows through. Pre-iOS 26 and iOS 26 both use that clear canvas.
    private func refreshKeyboardChrome(rebuildIfStyleChanged: Bool) {
        let previous = KeyboardChromeAppearance.usesLiquidGlassSurfaces
        let glass = detectLiquidGlassKeyboardChrome()
        KeyboardChromeAppearance.usesLiquidGlassSurfaces = glass
        applyKeyboardChromeSurface()
        applyLiquidGlassCornerConfiguration()
        applySuggestionRailMargins()
        applyCandidateBarLayout()
        keyboardStackBottomInset?.constant = -keyGridBottomInset
        keyboardContentBottomInset?.constant = -preLiquidGlassBottomLift
        if !isKeyboardOverlayPresented {
            applyHostHeightConstraint(reason: "chrome-refresh")
        }
        guard rebuildIfStyleChanged, previous != glass else { return }
        DispatchQueue.main.async { [weak self] in
            self?.rebuildKeys()
        }
    }

    /// KeyboardKit leaves `KeyboardViewStyle.background` nil so the system
    /// surface shows through. Pre-iOS 26 uses that same clear canvas; a tinted
    /// fill still read as a card in Spotlight. iOS 26 glass hosts stay clear.
    /// The debug Classic override paints the pre-glass tray so keys are not
    /// sitting on the host's glass surface.
    private func applyKeyboardChromeSurface() {
        view.backgroundColor = .clear
        keyboardChrome.isUserInteractionEnabled = false
        keyboardChrome.layer.cornerRadius = 0
        view.isOpaque = false
        keyboardContentContainer.isOpaque = false
        if usesLiquidGlassKeyboardChrome {
            keyboardChrome.isOpaque = false
            keyboardChrome.backgroundColor = .clear
            return
        }
        if #available(iOS 26.0, *) {
            keyboardChrome.isOpaque = true
            keyboardChrome.backgroundColor = UIColor { traits in
                if traits.userInterfaceStyle == .dark {
                    return UIColor(white: 0.17, alpha: 1)
                }
                return UIColor(red: 210 / 255, green: 213 / 255, blue: 219 / 255, alpha: 1)
            }
            return
        }
        keyboardChrome.isOpaque = false
        keyboardChrome.backgroundColor = .clear
    }

    /// KeyboardKit keys glass off the OS (`isLiquidGlassEnabled` when the
    /// major version is > 18). Automatic follows that flag. Matching our
    /// requested height is not classic: iMessage's glass capsule is a visual
    /// lip on the host tray, not extra bounds on this pinned view.
    private func detectLiquidGlassKeyboardChrome() -> Bool {
        switch KeyboardPreferences.keyboardChromeOverride() {
        case .classic:
            return false
        case .automatic, .liquidGlass:
            if #available(iOS 26.0, *) { return true }
            return false
        }
    }

    private func applySuggestionRailMargins() {
        candidateBar.insetsLayoutMarginsFromSafeArea = false
        candidateBar.layoutMargins = UIEdgeInsets(
            top: contentTopInset + liquidGlassTopLip,
            left: 0,
            bottom: showsCandidateBar ? max(0, keyGridTopInset - suggestionRailReleasedToKeys) : 0,
            right: 0
        )
    }

    /// Match the system keyboard capsule. KeyboardKit's `KeyboardViewStyle`
    /// applies `backgroundCornerRadiusTop` for the same reason: the glass
    /// frame is owned by the host. Concentric corners keep the rail in the
    /// curve instead of sitting in a rectangle inset from it. Classic chrome
    /// resets those corners so the rail is not clipped to a missing capsule.
    private func applyLiquidGlassCornerConfiguration() {
        guard #available(iOS 26.0, *) else { return }
        if usesLiquidGlassKeyboardChrome {
            LiquidGlassCornerStyle.applyTopCapsule(to: keyboardContentContainer)
            candidateBar.applyLiquidGlassTopCurveIfAvailable()
        } else {
            LiquidGlassCornerStyle.reset(to: keyboardContentContainer)
            candidateBar.resetLiquidGlassTopCurveIfAvailable()
        }
    }

    private func configureLayout() {
        view.backgroundColor = .clear
        // Paint pre-iOS 26 chrome only on the calibrated content strip. Pinning
        // it to `view` fills UIKit's temporary tall attach frame with empty gray.
        keyboardContentContainer.translatesAutoresizingMaskIntoConstraints = false
        keyboardContentContainer.clipsToBounds = false
        keyboardContentContainer.backgroundColor = .clear
        view.addSubview(keyboardContentContainer)
        keyboardChrome.translatesAutoresizingMaskIntoConstraints = false
        keyboardChrome.isUserInteractionEnabled = false
        keyboardContentContainer.insertSubview(keyboardChrome, at: 0)
        NSLayoutConstraint.activate([
            keyboardChrome.leadingAnchor.constraint(equalTo: keyboardContentContainer.leadingAnchor),
            keyboardChrome.trailingAnchor.constraint(equalTo: keyboardContentContainer.trailingAnchor),
            keyboardChrome.topAnchor.constraint(equalTo: keyboardContentContainer.topAnchor),
            keyboardChrome.bottomAnchor.constraint(equalTo: keyboardContentContainer.bottomAnchor)
        ])
        applyKeyboardChromeSurface()

        keyboardContentHeight = keyboardContentContainer.heightAnchor.constraint(equalToConstant: normalKeyboardHeight)
        keyboardContentHeight.priority = UILayoutPriority(999)
        let hostHeight = view.heightAnchor.constraint(equalToConstant: normalKeyboardHeight)
        hostHeight.priority = UILayoutPriority(999)
        keyboardHostHeight = hostHeight
        keyboardContentBottomInset = keyboardContentContainer.bottomAnchor.constraint(
            equalTo: view.bottomAnchor,
            constant: -preLiquidGlassBottomLift
        )
        NSLayoutConstraint.activate([
            keyboardContentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardContentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardContentContainer.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
            keyboardContentBottomInset,
            keyboardContentHeight
        ])
        applyHostHeightConstraint(reason: "configureLayout")

        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.isUserInteractionEnabled = true
        candidateBar.isMultipleTouchEnabled = false
        candidateBar.isExclusiveTouch = true
        candidateBar.backgroundColor = .clear
        candidateBar.insetsLayoutMarginsFromSafeArea = false
        candidateBar.onSelect = { [weak self] button in
            self?.selectPrediction(button)
        }
        applySuggestionRailMargins()
        keyboardContentContainer.addSubview(candidateBar)
        let segments = UIStackView()
        segments.axis = .horizontal
        segments.distribution = .fillEqually
        segments.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.addSubview(segments)
        candidateSegmentsLeading = segments.leadingAnchor.constraint(
            equalTo: candidateBar.layoutMarginsGuide.leadingAnchor
        )
        NSLayoutConstraint.activate([
            candidateSegmentsLeading,
            segments.trailingAnchor.constraint(equalTo: candidateBar.layoutMarginsGuide.trailingAnchor),
            segments.topAnchor.constraint(equalTo: candidateBar.layoutMarginsGuide.topAnchor),
            segments.bottomAnchor.constraint(equalTo: candidateBar.layoutMarginsGuide.bottomAnchor)
        ])

        clipboardButton.translatesAutoresizingMaskIntoConstraints = false
        clipboardButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        clipboardButton.tintColor = .label
        clipboardButton.setPreferredSymbolConfiguration(
            .init(pointSize: 15, weight: .regular),
            forImageIn: .normal
        )
        clipboardButton.accessibilityLabel = "Clipboard History"
        clipboardButton.isHidden = true
        clipboardButton.addTarget(self, action: #selector(clipboardButtonPressed), for: .touchUpInside)
        keyboardContentContainer.addSubview(clipboardButton)
        NSLayoutConstraint.activate([
            clipboardButton.leadingAnchor.constraint(
                equalTo: candidateBar.layoutMarginsGuide.leadingAnchor
            ),
            clipboardButton.topAnchor.constraint(equalTo: candidateBar.layoutMarginsGuide.topAnchor),
            clipboardButton.bottomAnchor.constraint(equalTo: candidateBar.layoutMarginsGuide.bottomAnchor),
            clipboardButton.widthAnchor.constraint(equalToConstant: clipboardButtonWidth)
        ])
        for index in 0..<3 {
            if index < 2 {
                let button = CandidateButton()
                button.candidateFont = .systemFont(ofSize: 18, weight: index == 1 ? .medium : .regular)
                button.contentVerticalAlignment = .center
                button.tag = index
                button.isUserInteractionEnabled = false
                button.onActivate = { [weak self, weak button] in
                    guard let button else { return }
                    self?.selectPrediction(button)
                }
                segments.addArrangedSubview(button)
                candidateButtons.append(button)
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.isUserInteractionEnabled = false
                separator.backgroundColor = UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(white: 0.36, alpha: 0.7)
                        : UIColor(red: 0.77, green: 0.79, blue: 0.83, alpha: 0.75)
                }
                button.addSubview(separator)
                NSLayoutConstraint.activate([
                    separator.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    separator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    separator.heightAnchor.constraint(equalToConstant: 20),
                    separator.widthAnchor.constraint(equalToConstant: 1)
                ])
                continue
            }

            // Right third: either the 3rd word chip or up to two emoji chips.
            let thirdColumn = UIView()
            thirdColumn.translatesAutoresizingMaskIntoConstraints = false
            segments.addArrangedSubview(thirdColumn)

            let wordButton = CandidateButton()
            wordButton.candidateFont = .systemFont(ofSize: 18, weight: .regular)
            wordButton.contentVerticalAlignment = .center
            wordButton.tag = 2
            wordButton.isUserInteractionEnabled = false
            wordButton.translatesAutoresizingMaskIntoConstraints = false
            wordButton.onActivate = { [weak self, weak wordButton] in
                guard let wordButton else { return }
                self?.selectPrediction(wordButton)
            }
            thirdColumn.addSubview(wordButton)
            candidateButtons.append(wordButton)

            let emojiStack = UIStackView()
            emojiStack.axis = .horizontal
            emojiStack.distribution = .fillEqually
            emojiStack.translatesAutoresizingMaskIntoConstraints = false
            emojiStack.isHidden = true
            thirdColumn.addSubview(emojiStack)
            emojiCandidateStack = emojiStack

            for emojiIndex in 0..<2 {
                let button = CandidateButton()
                button.candidateFont = .systemFont(ofSize: 22, weight: .regular)
                button.contentVerticalAlignment = .center
                button.tag = 100 + emojiIndex
                button.isUserInteractionEnabled = false
                button.onActivate = { [weak self, weak button] in
                    guard let button else { return }
                    self?.selectPrediction(button)
                }
                emojiStack.addArrangedSubview(button)
                emojiCandidateButtons.append(button)
            }

            NSLayoutConstraint.activate([
                wordButton.leadingAnchor.constraint(equalTo: thirdColumn.leadingAnchor),
                wordButton.trailingAnchor.constraint(equalTo: thirdColumn.trailingAnchor),
                wordButton.topAnchor.constraint(equalTo: thirdColumn.topAnchor),
                wordButton.bottomAnchor.constraint(equalTo: thirdColumn.bottomAnchor),
                emojiStack.leadingAnchor.constraint(equalTo: thirdColumn.leadingAnchor),
                emojiStack.trailingAnchor.constraint(equalTo: thirdColumn.trailingAnchor),
                emojiStack.topAnchor.constraint(equalTo: thirdColumn.topAnchor),
                emojiStack.bottomAnchor.constraint(equalTo: thirdColumn.bottomAnchor)
            ])
        }
        candidateBar.candidateButtons = candidateButtons + emojiCandidateButtons
        candidateBarHeight = candidateBar.heightAnchor.constraint(equalToConstant: candidateBarOccupiedHeight)
        candidateBarTopInset = candidateBar.topAnchor.constraint(
            equalTo: keyboardContentContainer.topAnchor,
            constant: showsCandidateBar ? 0 : contentTopInset
        )
        NSLayoutConstraint.activate([
            candidateBar.leadingAnchor.constraint(equalTo: keyboardContentContainer.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: keyboardContentContainer.trailingAnchor),
            candidateBarTopInset,
            candidateBarHeight
        ])
        keyboardStack.axis = .vertical; keyboardStack.spacing = 8; keyboardStack.distribution = .fillEqually
        keyboardStack.translatesAutoresizingMaskIntoConstraints = false
        keyboardContentContainer.addSubview(keyboardStack)
        keyboardLeadingInset = keyboardStack.leadingAnchor.constraint(equalTo: keyboardContentContainer.leadingAnchor, constant: keyboardMetrics.horizontalInset)
        keyboardTrailingInset = keyboardStack.trailingAnchor.constraint(equalTo: keyboardContentContainer.trailingAnchor, constant: -keyboardMetrics.horizontalInset)
        keyboardStackTopInset = keyboardStack.topAnchor.constraint(
            equalTo: candidateBar.bottomAnchor,
            constant: showsCandidateBar ? suggestionRailReleasedToKeys : keyGridTopInset
        )
        keyboardStackBottomInset = keyboardStack.bottomAnchor.constraint(
            equalTo: keyboardContentContainer.bottomAnchor,
            constant: -keyGridBottomInset
        )
        NSLayoutConstraint.activate([
            keyboardLeadingInset,
            keyboardTrailingInset,
            keyboardStackTopInset,
            keyboardStackBottomInset
        ])
        trackpadSurface.translatesAutoresizingMaskIntoConstraints = false
        trackpadSurface.isUserInteractionEnabled = false
        trackpadSurface.layer.cornerRadius = 7
        trackpadSurface.layer.cornerCurve = .continuous
        trackpadSurface.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.58, alpha: 1) : UIColor(white: 0.72, alpha: 1)
        }
        trackpadSurface.alpha = 0
        keyboardContentContainer.addSubview(trackpadSurface)
        NSLayoutConstraint.activate([
            trackpadSurface.leadingAnchor.constraint(equalTo: keyboardStack.leadingAnchor),
            trackpadSurface.trailingAnchor.constraint(equalTo: keyboardStack.trailingAnchor),
            trackpadSurface.topAnchor.constraint(equalTo: keyboardStack.topAnchor),
            trackpadSurface.bottomAnchor.constraint(equalTo: keyboardStack.bottomAnchor)
        ])
        // Keys sit in front of the rail in the default z-order, and their
        // expanded hit area can steal the bottom of a suggestion. Keep the
        // rail above the grid so a visible candidate is always tappable.
        // The clipboard button must sit above the rail: CandidateRailView
        // owns every touch inside its bounds.
        keyboardContentContainer.bringSubviewToFront(candidateBar)
        keyboardContentContainer.bringSubviewToFront(clipboardButton)
        applyLiquidGlassCornerConfiguration()
        updateClipboardButtonVisibility()
    }

    private func rebuildKeys() {
        // Destroying the Delete key mid-hold cancels its long-press and
        // stops repeat. Defer until the finger lifts.
        if isDeleteRepeatActive {
            needsKeyRebuildWhenGeometryIsStable = true
            return
        }
        if !isKeyboardOverlayPresented {
            applyHostHeightConstraint(reason: "rebuildKeys")
        }
        guard hasUsableKeyboardWidth else {
            needsKeyRebuildWhenGeometryIsStable = true
            keyboardStack.isHidden = true
            candidateBar.isHidden = true
            updateClipboardButtonVisibility()
            logKeyboardLayout("rebuild deferred")
            return
        }
        needsKeyRebuildWhenGeometryIsStable = false
        applyCandidateBarLayout()
        candidateBar.isHidden = isKeyboardOverlayPresented || !showsCandidateBar
        keyboardStack.isHidden = isKeyboardOverlayPresented
        updateClipboardButtonVisibility()
        logKeyboardLayout("rebuild keys")
        spaceSignatureRestoreWork?.cancel()
        spaceSignatureRestoreWork = nil
        hideKeyPreview(animated: false)
        hideAlternatePicker()
        hidePendingCompositionChrome()
        keyboardStack.prepareForKeyRebuild()
        metricConstraints.removeAll()
        metricMargins.removeAll()
        metricCapInsets.removeAll()
        // Drop highlight before teardown. iOS 26 Liquid Glass keeps a press
        // overlay on the input session when a highlighted key is destroyed
        // mid-touch; switching IME is what used to clear it.
        UIView.performWithoutAnimation {
            let rows = keyboardStack.arrangedSubviews
            for case let row as UIStackView in rows {
                for case let button as NativeKeyButton in row.arrangedSubviews {
                    button.highlightChanged = nil
                    button.isHighlighted = false
                }
                row.removeFromSuperview()
            }
        }
        // Match the native English fourth row: the emoji affordance sits
        // between the number key and Space. URL/email punctuation sits to
        // the right of Space, as on the system web keyboard. A keyboard
        // extension can ask iOS to advance input modes, but cannot select
        // Emoji directly.
        let bottom = KeyboardBottomRow.keys(isPad: usesPadLayout,
            emoji: KeyboardPreferences.emojiEnabled(), language: englishEnabled,
            globe: showsInputModeSwitchKey, punctuation: contextualPunctuationKeys)
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
            let topRow: [[String]]
            switch KeyboardPreferences.topRow() {
            case .disabled:
                topRow = []
            case .numbers:
                topRow = [["1","2","3","4","5","6","7","8","9","0"]]
            case .emoji:
                topRow = [EmojiCatalog.topRow().map { Self.topEmojiKeyPrefix + $0 }]
            }
            rows = topRow + letterRows + [bottom]
        case .numbers:
            rows = usesPadLayout
                ? [["1","2","3","4","5","6","7","8","9","0","delete"], ["-","/",":",";","(",")","$","&","@","\"","return"], ["#+=",".",",","?","!","'","kundaliya","#+="], bottom.map { $0 == "123" ? "ABC" : $0 }]
                : [["1","2","3","4","5","6","7","8","9","0"], ["-","/",":",";","(",")","$","&","@","\""], ["#+=",".",",","?","!","'","kundaliya","delete"], bottom.map { $0 == "123" ? "ABC" : $0 }]
        case .symbols:
            rows = usesPadLayout
                ? [["[","]","{","}","#","%","^","*","+","=","delete"], ["_","\\","|","~","<",">","€","£","¥","•","return"], ["123",".",",","?","!","'","kundaliya","123"], bottom.map { $0 == "123" ? "ABC" : $0 }]
                : [["[","]","{","}","#","%","^","*","+","="], ["_","\\","|","~","<",">","€","£","¥","•"], ["123",".",",","?","!","'","kundaliya","delete"], bottom.map { $0 == "123" ? "ABC" : $0 }]
        }
        for (index, row) in rows.enumerated() { keyboardStack.addArrangedSubview(makeRow(row, index: index)) }
        applyKeyboardMetrics()
        refreshPendingCompositionChrome()
        if layer != .letters || mode == .sls {
            applyKeyTouchWeights([:])
        }
    }

    private func applyKeyboardMetrics() {
        if !isKeyboardOverlayPresented {
            applyHostHeightConstraint(reason: "applyMetrics")
        } else {
            applyCandidateBarLayout()
        }
        let baseInset = keyboardMetrics.horizontalInset
        switch KeyboardPreferences.oneHandedPosition() {
        case .centered:
            keyboardLeadingInset?.constant = baseInset
            keyboardTrailingInset?.constant = -baseInset
        case .left:
            keyboardLeadingInset?.constant = baseInset
            keyboardTrailingInset?.constant = -(baseInset + oneHandedContentInset)
        case .right:
            keyboardLeadingInset?.constant = baseInset + oneHandedContentInset
            keyboardTrailingInset?.constant = -baseInset
        }
        let baseVerticalGap: CGFloat = usesPadLayout ? 10 : (layoutProfile == .phoneLandscape ? 5 : 8)
        if usesStandardPhoneGeometry {
            keyboardStack.spacing = 11
            keyboardStack.distribution = .fillEqually
        } else {
            keyboardStack.spacing = max(3, baseVerticalGap + CGFloat(KeyboardPreferences.hotPath.keySpacing.verticalAdjustment))
            keyboardStack.distribution = .fillEqually
        }
        // The matched UK grid sits four points lower inside the keyboard
        // chrome on a portrait phone. This is a visual placement adjustment;
        // row dimensions remain constrained to the measured 43 pt height.
        // Phonetic, Smart Phonetic, and Wijesekara all use this placement.
        applySuggestionRailMargins()
        applyCandidateBarLayout()
        keyboardStackBottomInset?.constant = -keyGridBottomInset
        keyboardContentBottomInset?.constant = -preLiquidGlassBottomLift
        keyboardStack.transform = usesStandardPhoneGeometry
            ? CGAffineTransform(translationX: 0, y: keyGridVerticalNudge)
            : .identity
        keyboardStack.horizontalGap = keyboardMetrics.horizontalGap
        keyboardStack.expandsToRowEdges = mode != .sls
        // Pale-blue Q-row cells reach a sliver above the caps. The rail stops
        // above that sliver so a grazing tap is a key, not a suggestion.
        keyboardStack.hitExpansion = UIEdgeInsets(
            top: firstKeyRowTopHit,
            left: keyboardMetrics.horizontalInset,
            bottom: keyGridBottomInset,
            right: keyboardMetrics.horizontalInset
        )
        candidateBar.hitOutsets = .zero
        metricConstraints.forEach { constraint, value in constraint.constant = value() }
        metricMargins.forEach { row, value in row.layoutMargins = value() }
        metricCapInsets.forEach { button, value in button.applyCharacterEdgeInsets(value()) }
        candidateButtons.enumerated().forEach { index, button in
            button.candidateFont = .systemFont(ofSize: usesPadLayout ? 20 : 18, weight: index == 1 ? .medium : .regular)
        }
        let emojiSize: CGFloat = usesPadLayout ? 24 : 22
        emojiCandidateButtons.forEach {
            $0.candidateFont = .systemFont(ofSize: emojiSize, weight: .regular)
        }
        keyboardStack.setNeedsLayout()
        candidateBar.setNeedsLayout()
    }

    private func addMetricWidth(to button: UIView, value: @escaping () -> CGFloat) {
        let constraint = button.widthAnchor.constraint(equalToConstant: value())
        constraint.isActive = true
        metricConstraints.append((constraint, value))
    }

    private func addCharacterEdgeInsets(to button: NativeKeyButton, value: @escaping () -> UIEdgeInsets) {
        button.applyCharacterEdgeInsets(value())
        metricCapInsets.append((button, value))
    }

    private func makeRow(_ keys: [String], index: Int) -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = keyboardMetrics.horizontalGap; row.alignment = .fill
        if let standardPhoneRowHeight {
            row.heightAnchor.constraint(equalToConstant: standardPhoneRowHeight).isActive = true
        }
        let isBottom = keys.contains("space")
        let isThirdLetterRow = layer == .letters && keys.contains("shift")
        let isControlRow = isThirdLetterRow || (layer != .letters && index == 2)
        let isEnglishAlphabet = layer == .letters && mode != .sls
        let isEnglishNineKeyRow = isEnglishAlphabet && keys.contains("a") && keys.last == "l"
        if isEnglishNineKeyRow || (isControlRow && isEnglishAlphabet) {
            KeyboardHitTrace.log(
                "makeRow[\(index)] keys=\(keys.joined()) nineKey=\(isEnglishNineKeyRow) control=\(isControlRow) stdPhone=\(usesStandardPhoneGeometry) aLInset=\(Int(keyboardMetrics.englishSecondRowInset)) zMGap=\(Int(keyboardMetrics.standardEnglishThirdRowInnerGap))"
            )
        }
        row.distribution = usesPadLayout && !isBottom ? .fillEqually : ((isBottom || isControlRow || isEnglishNineKeyRow) ? .fill : .fillEqually)
        if usesPadLayout && isControlRow && keys.count < 10 {
            // Sparse phonetic and numeric rows are centred on iPad instead of
            // becoming much wider than the upper rows. Seven-key symbol rows
            // need a larger inset than the nine-key phonetic row.
            let fraction: CGFloat = keys.count <= 7 ? 0.24 : 0.14
            let margins = { UIEdgeInsets(top: 0, left: max(42, self.view.bounds.width * fraction), bottom: 0, right: max(42, self.view.bounds.width * fraction)) }
            row.layoutMargins = margins()
            row.isLayoutMarginsRelativeArrangement = true
            metricMargins.append((row, margins))
        } else if isControlRow {
            row.layoutMargins = UIEdgeInsets(top: 0, left: isEnglishAlphabet ? 0 : 2, bottom: 0, right: isEnglishAlphabet ? 0 : 2)
            row.isLayoutMarginsRelativeArrangement = true
        }
        var letterButtons: [NativeKeyButton] = []
        for keyName in keys {
            let button = makeKey(keyName)
            row.addArrangedSubview(button)
            if isEnglishNineKeyRow, keyName == "a" {
                addMetricWidth(to: button) {
                    self.keyboardMetrics.tenKeyWidth + self.keyboardMetrics.englishSecondRowInset
                }
                addCharacterEdgeInsets(to: button) {
                    UIEdgeInsets(top: 0, left: self.keyboardMetrics.englishSecondRowInset, bottom: 0, right: 0)
                }
                KeyboardHitTrace.log(
                    "row A extraWidth=\(Int(keyboardMetrics.englishSecondRowInset)) tenKey=\(Int(keyboardMetrics.tenKeyWidth))"
                )
            } else if isEnglishNineKeyRow, keyName == "l" {
                addMetricWidth(to: button) {
                    self.keyboardMetrics.tenKeyWidth + self.keyboardMetrics.englishSecondRowInset
                }
                addCharacterEdgeInsets(to: button) {
                    UIEdgeInsets(top: 0, left: 0, bottom: 0, right: self.keyboardMetrics.englishSecondRowInset)
                }
                KeyboardHitTrace.log(
                    "row L extraWidth=\(Int(keyboardMetrics.englishSecondRowInset)) tenKey=\(Int(keyboardMetrics.tenKeyWidth))"
                )
            }
            if isBottom {
                if keyName != "space" {
                    addMetricWidth(to: button) {
                        let metrics = self.keyboardMetrics
                        let small = self.usesPadLayout ? metrics.padBottomControlWidth
                            : (self.usesStandardPhoneGeometry ? metrics.standardEnglishBottomSmallKeyWidth : metrics.englishBottomSmallKeyWidth)
                        let enter = self.usesStandardPhoneGeometry ? metrics.standardEnglishReturnKeyWidth : metrics.englishReturnKeyWidth
                        let scale = KeyboardBottomRow.controlScale(keys: keys,
                            availableWidth: metrics.width - 2 * metrics.horizontalInset,
                            gap: metrics.horizontalGap, smallWidth: small, returnWidth: enter)
                        return (keyName == "return" ? enter : small) * scale
                    }
                }
            } else if !usesPadLayout && isControlRow && keyName == "shift" {
                // The phonetic layout has seven letter keys here. Giving its
                // system controls the remaining width makes those letters the
                // same width as the ten keys above, just like iOS.
                addMetricWidth(to: button) { isEnglishAlphabet ? (self.usesStandardPhoneGeometry ? self.keyboardMetrics.standardEnglishThirdRowUtilityWidth : self.keyboardMetrics.englishThirdRowUtilityWidth) : self.keyboardMetrics.scaledPhoneWidth(31) }
            } else if !usesPadLayout, isControlRow,
                      keyName == "delete" || (layer != .letters && ["#+=", "123"].contains(keyName)) {
                addMetricWidth(to: button) {
                    if self.layer != .letters {
                        return self.keyboardMetrics.numberSymbolControlWidth
                    }
                    return isEnglishAlphabet
                        ? (self.usesStandardPhoneGeometry
                            ? self.keyboardMetrics.standardEnglishThirdRowUtilityWidth
                            : self.keyboardMetrics.englishThirdRowUtilityWidth)
                        : self.keyboardMetrics.scaledPhoneWidth(31)
                }
            } else if usesStandardPhoneGeometry, isEnglishAlphabet, isControlRow, keyName == "z" {
                addMetricWidth(to: button) {
                    self.keyboardMetrics.tenKeyWidth + self.keyboardMetrics.standardEnglishThirdRowInnerGap
                }
                addCharacterEdgeInsets(to: button) {
                    UIEdgeInsets(top: 0, left: self.keyboardMetrics.standardEnglishThirdRowInnerGap, bottom: 0, right: 0)
                }
                KeyboardHitTrace.log(
                    "row Z extraWidth=\(Int(keyboardMetrics.standardEnglishThirdRowInnerGap)) tenKey=\(Int(keyboardMetrics.tenKeyWidth))"
                )
            } else if usesStandardPhoneGeometry, isEnglishAlphabet, isControlRow, keyName == "m" {
                addMetricWidth(to: button) {
                    self.keyboardMetrics.tenKeyWidth + self.keyboardMetrics.standardEnglishThirdRowInnerGap
                }
                addCharacterEdgeInsets(to: button) {
                    UIEdgeInsets(top: 0, left: 0, bottom: 0, right: self.keyboardMetrics.standardEnglishThirdRowInnerGap)
                }
                KeyboardHitTrace.log(
                    "row M extraWidth=\(Int(keyboardMetrics.standardEnglishThirdRowInnerGap)) tenKey=\(Int(keyboardMetrics.tenKeyWidth))"
                )
            } else if isControlRow || (isEnglishNineKeyRow && keyName != "a" && keyName != "l") {
                letterButtons.append(button)
            }
            if usesStandardPhoneGeometry, isEnglishAlphabet, isControlRow, keyName == "shift" || keyName == "m" {
                row.setCustomSpacing(0, after: button)
            }
        }
        for button in letterButtons.dropFirst() { button.widthAnchor.constraint(equalTo: letterButtons[0].widthAnchor).isActive = true }
        return row
    }

    private func makeKey(_ key: String) -> NativeKeyButton {
        // Default and Next use the grey system/utility surface. Only the
        // submit-style actions Apple paints blue get the prominent treatment.
        let utility = ["shift", "delete", "123", "ABC", "#+=", "globe", "dismiss", "language"].contains(key)
            || (key == "return" && !usesProminentReturnKey)
        let button = NativeKeyButton(
            keyName: key,
            title: title(for: key),
            hint: hint(for: key),
            symbol: symbol(for: key),
            utility: utility
        )
        button.applyLayoutMetrics(isPad: usesPadLayout)
        if key == "return" {
            if usesReturnKeyArrowSymbol {
                button.accessibilityLabel = returnKeyTitle ?? "Go"
                button.imageView?.preferredSymbolConfiguration = .init(
                    pointSize: usesPadLayout ? 20 : 18,
                    weight: .semibold
                )
            } else if let actionTitle = returnKeyTitle {
                // Return actions are labels, not characters. They must not inherit
                // the 22 pt alphabetic-key font: labels such as "Search" otherwise
                // look oversized next to the system keyboard.
                let fontSize: CGFloat
                switch actionTitle.count {
                case ...4: fontSize = usesPadLayout ? 18 : 16
                case 5...7: fontSize = usesPadLayout ? 17 : 15
                default: fontSize = usesPadLayout ? 15 : 13
                }
                button.titleLabel?.font = .systemFont(ofSize: fontSize, weight: .medium)
                button.titleLabel?.minimumScaleFactor = 0.75
            }
            if usesProminentReturnKey {
                button.backgroundColor = .systemBlue
                button.setTitleColor(.white, for: .normal)
                button.tintColor = .white
                button.layer.shadowOpacity = 0
            }
        }
        button.touchDown = { [weak self] in
            // If iOS failed to deliver an old Delete touch-up (for example
            // after a host-app cursor move), any new contact is authoritative.
            if key != "delete" {
                self?.stopDeleteRepeat()
            }
            // Haptic first — before click, preview, or composition work.
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
            guard key != "space", key != "return", button.supportsCharacterPreview else { return }
            guard !button.suppressesCharacterPreview else {
                self?.hideKeyPreview(animated: false)
                return
            }
            guard KeyboardPreferences.hotPath.characterPreviewEnabled else {
                self?.hideKeyPreview(animated: false)
                return
            }
            if highlighted {
                self?.showKeyPreview(for: button)
            } else {
                self?.hideKeyPreview()
                self?.refreshPendingCompositionChrome()
            }
        }
        if key == "language" {
            button.accessibilityLabel = language == .english ? "Switch to Sinhala" : "Switch to English"
        }
        if key == "123", layer == .letters {
            button.accessibilityHint = "Tap for numbers. Hold and drag to enter one number or symbol."
        }
        if key == "globe" {
            // This gives the system every touch phase it needs to show the
            // native long-press input-mode list as well as ordinary switching.
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        } else {
            let triggerEvent: UIControl.Event = shouldCommitOnTouchDown(key) ? .touchDown : .touchUpInside
            button.addAction(UIAction { [weak self, weak button] _ in
                guard button?.consumeLongPressHandled() != true else { return }
                self?.press(key)
            }, for: triggerEvent)
        }
        if key == "delete" {
            // Start repeat only after UIKit has positively recognized a hold.
            // A touch-down timer can outlive a rapid tap when the host app
            // changes lines, causing unexpected deletion after the finger has
            // already lifted.
            button.isExclusiveTouch = true
            button.trackingHitOutset = 44
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleDeleteLongPress(_:)))
            longPress.minimumPressDuration = 0.42
            longPress.allowableMovement = 80
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            button.addGestureRecognizer(longPress)
            button.touchEnded = { [weak self] in self?.stopDeleteRepeat() }
            button.touchCancelled = { [weak self] in self?.handleDeleteTouchCancellation() }
            button.addAction(UIAction { [weak self] _ in
                self?.stopDeleteRepeat()
            }, for: [.touchUpInside, .touchUpOutside])
        }
        if key == "space" {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSpaceTrackpad(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.cancelsTouchesInView = false
            button.addGestureRecognizer(longPress)
            if language == .sinhala, KeyboardPreferences.englishForOneWordEnabled(), mode == .smartPhonetic {
                let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSpaceEnglishWordSwipe(_:)))
                swipeUp.direction = .up
                swipeUp.delegate = self
                button.addGestureRecognizer(swipeUp)
                let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSpaceEnglishWordSwipe(_:)))
                swipeDown.direction = .down
                swipeDown.delegate = self
                button.addGestureRecognizer(swipeDown)
                button.accessibilityHint = "Swipe up for English, one word. Swipe down to cancel."
            }
        }
        if layer == .letters, mode == .sls, wijesekaraAlternates(for: key) != nil {
            button.accessibilityIdentifier = key
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSanyakayaLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.cancelsTouchesInView = false
            button.addGestureRecognizer(longPress)
        } else if KeyboardPreferences.hotPath.longPressPunctuationEnabled, punctuationAlternates(for: key) != nil {
            button.accessibilityIdentifier = key
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handlePunctuationLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.cancelsTouchesInView = false
            button.addGestureRecognizer(longPress)
        }
        return button
    }

    /// A normal tap keeps Numbers open; a recognized hold temporarily opens
    /// it and uses the existing grid hit regions to select one printable key.
    @objc private func handleNumberDrag(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            numberDragActive = true
            layer = .numbers
            rebuildKeys()
            view.layoutIfNeeded()
            updateNumberDragSelection(at: recognizer.location(in: keyboardStack))
        case .changed:
            guard numberDragActive else { return }
            updateNumberDragSelection(at: recognizer.location(in: keyboardStack))
        case .ended:
            guard numberDragActive else { return }
            updateNumberDragSelection(at: recognizer.location(in: keyboardStack))
            let key = numberDragSelection?.keyName
            // Clear state before editing the host, which can cancel touches.
            numberDragSelection?.isHighlighted = false
            numberDragSelection = nil
            numberDragActive = false
            if let key { press(key) }
            layer = .letters
            rebuildKeys()
        case .cancelled, .failed:
            finishNumberDrag()
        default: break
        }
    }

    private func updateNumberDragSelection(at point: CGPoint) {
        let hit = keyboardStack.hitTest(point, with: nil) as? NativeKeyButton
        // Utility controls never execute during a one-character gesture.
        // Sliding onto #+= reveals the additional symbols in the same hold.
        if hit?.keyName == "#+=", layer == .numbers {
            numberDragSelection?.isHighlighted = false
            numberDragSelection = nil
            layer = .symbols
            rebuildKeys()
            view.layoutIfNeeded()
            return
        }
        let selection = hit.flatMap { button -> NativeKeyButton? in
            button.keyName.count == 1 || button.keyName == "kundaliya" ? button : nil
        }
        guard selection !== numberDragSelection else { return }
        numberDragSelection?.isHighlighted = false
        numberDragSelection = selection
        selection?.isHighlighted = true
    }

    private func finishNumberDrag() {
        guard numberDragActive else { return }
        numberDragSelection?.isHighlighted = false
        numberDragSelection = nil
        numberDragActive = false
        layer = .letters
        rebuildKeys()
    }

    /// The system keyboard visibly commits normal taps as the finger lands.
    /// Space stays on touch-up because a hold enters cursor control. Return
    /// stays on touch-up so Search/Go/Send can be cancelled by sliding off,
    /// matching the system control. Layer switches rebuild the whole grid, so
    /// 123 / ABC / #+= wait for lift — tearing those keys down on touch-down
    /// leaves iOS 26's glass press overlay until the input session is replaced.
    /// Keys with long-press alternates also stay on touch-up so the picker can
    /// choose a value before anything is inserted into the host.
    private func shouldCommitOnTouchDown(_ key: String) -> Bool {
        guard key != "space", key != "return" else { return false }
        if key == "123" || key == "ABC" || key == "#+=" || key == "language" { return false }
        return !(layer == .letters && mode == .sls && wijesekaraAlternates(for: key) != nil)
            && !(KeyboardPreferences.hotPath.longPressPunctuationEnabled && punctuationAlternates(for: key) != nil)
    }

    /// Mirrors the system keyboard's long-press Space behavior. UIKit gives a
    /// keyboard extension cursor movement through UITextDocumentProxy rather
    /// than exposing the host text view directly.
    ///
    /// A stationary hold on the collapsed language caption is the spacebar
    /// signature instead of trackpad. Sliding off that corner still enters
    /// cursor control, so ordinary Space-hold cursor movement is unchanged.
    @objc private func handleSpaceTrackpad(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? NativeKeyButton else { return }
        switch recognizer.state {
        case .began:
            spaceSignatureStartLocation = recognizer.location(in: view)
            if language == .sinhala, isIdleComposition, isSpaceSignatureLabelRegion(in: button, location: recognizer.location(in: button)) {
                spaceSignatureHoldPending = true
                spaceSignatureHoldConsumed = false
                let work = DispatchWorkItem { [weak self, weak button] in
                    guard let self, let button, self.spaceSignatureHoldPending else { return }
                    self.spaceSignatureHoldPending = false
                    self.spaceSignatureHoldConsumed = true
                    button.markLongPressHandled()
                    self.revealSpacebarSignature()
                }
                spaceSignatureHoldTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
                return
            }
            beginSpaceTrackpad(from: recognizer, button: button)
        case .changed:
            if spaceSignatureHoldConsumed { return }
            if spaceSignatureHoldPending {
                let location = recognizer.location(in: view)
                let distance = hypot(
                    location.x - spaceSignatureStartLocation.x,
                    location.y - spaceSignatureStartLocation.y
                )
                if distance > 10 {
                    cancelSpaceSignatureHold()
                    beginSpaceTrackpad(from: recognizer, button: button)
                }
                return
            }
            let location = recognizer.location(in: view)
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = max(now - spaceTrackpadLastTimestamp, 1.0 / 240.0)
            let horizontalMovement = location.x - spaceTrackpadLastX
            let velocity = abs(horizontalMovement / CGFloat(elapsed))
            spaceTrackpadLastX = location.x
            spaceTrackpadLastTimestamp = now

            // Fine movement remains deliberate, while a quick sweep crosses
            // longer text without repeated, full-width drags. UIKit exposes
            // only character offsets to keyboard extensions, so this is the
            // closest public-API equivalent to the native trackpad's speed.
            let speedMultiplier: CGFloat
            switch velocity {
            case 0..<90: speedMultiplier = 1
            case 90..<220: speedMultiplier = 1.35
            case 220..<420: speedMultiplier = 1.85
            default: speedMultiplier = 2.5
            }
            let basePointsPerCharacter: CGFloat = usesPadLayout ? 14 : 7.5
            let pointsPerCharacter = basePointsPerCharacter / speedMultiplier
            spaceTrackpadRemainder += horizontalMovement
            let delta = Int(spaceTrackpadRemainder / pointsPerCharacter)
            guard delta != 0 else { return }
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
            spaceTrackpadRemainder -= CGFloat(delta) * pointsPerCharacter
            keyFeedback?.selectionChanged()
        case .ended, .cancelled, .failed:
            if spaceSignatureHoldPending {
                cancelSpaceSignatureHold()
                return
            }
            if spaceSignatureHoldConsumed {
                spaceSignatureHoldConsumed = false
                return
            }
            spaceTrackpadRemainder = 0
            spaceTrackpadLastTimestamp = 0
            setTrackpadAppearance(active: false)
        default:
            break
        }
    }

    private func beginSpaceTrackpad(from recognizer: UILongPressGestureRecognizer, button: NativeKeyButton) {
        button.markLongPressHandled()
        endTemporaryLatinWordMode()
        commitActiveComposition()
        resetSpaceSignatureTaps()
        setTrackpadAppearance(active: true)
        spaceTrackpadLastX = recognizer.location(in: view).x
        spaceTrackpadRemainder = 0
        spaceTrackpadLastTimestamp = ProcessInfo.processInfo.systemUptime
        keyFeedback?.prepare()
    }

    /// The collapsed IME caption sits in the lower-right of Space. Holding
    /// anywhere else keeps the system trackpad gesture.
    private func isSpaceSignatureLabelRegion(in button: NativeKeyButton, location: CGPoint) -> Bool {
        let bounds = button.bounds
        let region = CGRect(x: bounds.midX, y: bounds.midY, width: bounds.width / 2, height: bounds.height / 2)
        return region.contains(location)
    }

    private func cancelSpaceSignatureHold() {
        spaceSignatureHoldTimer?.cancel()
        spaceSignatureHoldTimer = nil
        spaceSignatureHoldPending = false
    }

    private func setTrackpadAppearance(active: Bool, animated: Bool = true) {
        isSpaceTrackpadActive = active
        setKeyGlyphsHidden(active, animated: animated)
        // The space touch is already owned by its long-press recognizer. A
        // nearly invisible overlay blocks any *new* touches from reaching
        // other keys until that touch ends. UIKit does not hit-test views
        // whose alpha is below 0.01, hence the deliberately tiny value.
        trackpadSurface.isUserInteractionEnabled = active
        trackpadSurface.alpha = active ? 0.011 : 0
        candidateBar.isUserInteractionEnabled = !active
    }

    @objc private func handleSpaceEnglishWordSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended,
              KeyboardPreferences.englishForOneWordEnabled(),
              mode == .smartPhonetic,
              layer == .letters,
              let button = recognizer.view as? NativeKeyButton else { return }
        guard !isSpaceTrackpadActive, !spaceSignatureHoldPending, !spaceSignatureHoldConsumed else { return }
        // Swipe already cancels this touch (`cancelsTouchesInView`). Do not
        // leave `longPressWasHandled` set — the cancelled touch never runs
        // `consumeLongPressHandled()`, so the *next* Space tap would be eaten.
        _ = button.consumeLongPressHandled()
        if temporaryLatinWordActive {
            // Swipe up or down cancels without inserting a space.
            endTemporaryLatinWordMode()
            return
        }
        // Enter only on swipe up.
        guard recognizer.direction == .up else { return }
        beginTemporaryLatinWordMode()
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
        // KeyboardKit only shows input callouts on phone.
        guard !usesPadLayout else { return }
        let capFrame = button.convert(button.paintedCapBounds, to: view)
        let isLandscape = layoutProfile == .phoneLandscape
        // KeyboardKit `inputItemMinSize` height is 55; landscape uses the key height.
        let preferredBubbleHeight: CGFloat = isLandscape ? capFrame.height : 55
        // When the suggestion rail is hidden, the first row starts directly
        // below the keyboard chrome. A custom-keyboard host clips anything
        // above that boundary, so a shortened callout looks broken. Suppress
        // it rather than drawing a cropped bubble; lower rows still preview.
        let previewTopBoundary = keyboardContentContainer.frame.minY
        let availableAbove = capFrame.minY - previewTopBoundary
        guard availableAbove >= preferredBubbleHeight else { return }
        let bubbleHeight = preferredBubbleHeight
        let preview = keyPreview ?? KeyPreviewView()
        if preview.superview == nil {
            view.addSubview(preview)
            keyPreview = preview
            preview.alpha = 0
        }
        let previewWidth = capFrame.width + KeyPreviewView.sideOverhang
        let previewHeight = capFrame.height + bubbleHeight
        let minX = view.bounds.minX + 2
        let maxX = view.bounds.maxX - previewWidth - 2
        let x = min(max(capFrame.midX - previewWidth / 2, minX), maxX)
        preview.configure(
            stemWidth: capFrame.width,
            stemCenterX: capFrame.midX - x,
            stemHeight: capFrame.height,
            bubbleHeight: bubbleHeight,
            stemCornerRadius: button.keycapCornerRadius,
            fillColor: button.calloutFillColor
        )
        preview.frame = CGRect(
            x: x,
            y: capFrame.minY - bubbleHeight,
            width: previewWidth,
            height: previewHeight
        )
        preview.display(title)
        preview.layoutIfNeeded()
        view.bringSubviewToFront(preview)
        preview.alpha = 1
        preview.transform = .identity
    }

    private func hideKeyPreview(animated: Bool = true) {
        guard let preview = keyPreview, preview.superview != nil else { return }
        let changes = { preview.alpha = 0; preview.transform = .identity }
        let remove = { [weak self, weak preview] in
            guard let preview, preview.alpha == 0 else { return }
            preview.removeFromSuperview()
            if self?.keyPreview === preview {
                self?.keyPreview = nil
            }
        }
        if animated {
            UIView.animate(
                withDuration: 0.08,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseIn],
                animations: changes,
                completion: { _ in remove() }
            )
        } else {
            changes()
            preview.removeFromSuperview()
            keyPreview = nil
        }
    }

    private func symbol(for key: String) -> String? {
        if key.hasPrefix(Self.topEmojiKeyPrefix) { return nil }
        switch key {
        case "shift": return "shift"
        case "delete": return "delete.left"
        case "emoji": return "face.smiling"
        case "globe": return "globe"
        case "return":
            if usesReturnKeyArrowSymbol { return "arrow.right" }
            return returnKeyTitle == nil ? "return" : nil
        case "dismiss": return "keyboard.chevron.compact.down"
        default: return nil
        }
    }

    private func title(for key: String) -> String? {
        if key == "language" { return language == .english ? "සිං" : "EN" }
        if language == .english, key == "space" { return "English" }
        if key.hasPrefix(Self.topEmojiKeyPrefix) {
            return String(key.dropFirst(Self.topEmojiKeyPrefix.count))
        }
        if let character = contextualCharacter(for: key) { return character }
        if key == "space" {
            if temporaryLatinWordActive {
                return Self.oneWordEnglishSpaceTitle
            }
            switch mode {
            case .sls: return "අක්ෂර Wijesekara"
            case .phonetic: return "අක්ෂර Phonetic"
            case .smartPhonetic: return "අක්ෂර Smart Phonetic"
            }
        }
        if key == "return" {
            return usesReturnKeyArrowSymbol ? nil : returnKeyTitle
        }
        if ["shift", "delete", "emoji", "globe", "dismiss"].contains(key) { return nil }
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
        if language == .english { return nil }
        if temporaryLatinWordActive { return nil }
        if mode == .sls, layer == .letters, let alternate = wijesekaraAlternates(for: key)?.first {
            // Show the held-character result in the same quiet upper-right
            // position used for phonetic transliteration hints.
            return alternate.display
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
        if KeyboardHitTrace.isTraced(key) {
            KeyboardHitTrace.log("controller press(\(key))")
        }
        guard !isSpaceTrackpadActive, !numberDragActive else { return }
        // A host can send, clear, or select text without dismissing this
        // keyboard.  In that case our per-key history still describes the
        // previous draft.  Reconcile it before interpreting the next action:
        // otherwise a new letter can extend the sent word, and Delete can
        // consume a selection followed by characters before that selection.
        reconcileCompositionStateWithDocument()
        let prefs = KeyboardPreferences.hotPath
        if prefs.keyClicksEnabled {
            if prefs.hapticsEnabled {
                // Haptic already fired on touch-down. Defer the click so the
                // two feedback systems do not contend on the same turn.
                DispatchQueue.main.async { UIDevice.current.playInputClick() }
            } else {
                UIDevice.current.playInputClick()
            }
        }
        if key != "space" {
            lastSpaceTimestamp = nil
            resetSpaceSignatureTaps()
        }
        if key.hasPrefix(Self.topEmojiKeyPrefix) {
            let emoji = String(key.dropFirst(Self.topEmojiKeyPrefix.count))
            EmojiCatalog.record(emoji)
            commit(suffix: emoji)
            return
        }
        if let character = contextualCharacter(for: key) {
            commit(suffix: character)
            return
        }
        switch key {
        case "delete":
            deleteRepeatAnchor = keyButton(named: "delete")
            deleteRepeatBeganAt = CACurrentMediaTime()
            startDeleteHoldCountdown()
            // Mutating the host in the same turn as touch-down often cancels
            // the original touch, which then kills hold-to-delete. Finish
            // establishing the touch first.
            DispatchQueue.main.async { [weak self] in
                self?.deleteOnce()
            }
        case "space":
            insertSpace()
            // Match the system keyboard: Space on Numbers/Symbols returns to
            // the alphabetic layer after inserting the space.
            if layer != .letters {
                layer = .letters
                rebuildKeys()
            }
        case "return":
            performReturnKey()
        case "emoji": showEmojiPicker()
        case "globe": break // Routed through handleInputModeList(_:with:).
        case "dismiss":
            cancelLocalCompositionWithoutCommit()
            dismissKeyboard()
        case "shift":
            shift.toggle()
            refreshShiftedKeyAppearance()
        case "language": switchKeyboardLanguage()
        case "123": layer = .numbers; rebuildKeys()
        case "#+=": layer = .symbols; rebuildKeys()
        case "ABC": layer = .letters; rebuildKeys()
        case "rakaranshaya":
            lastLetterKey = key
            insertLive(shift ? "\u{200D}" : "\u{E004}")
            if shift {
                shift = false
                refreshShiftedKeyAppearance()
            }
        case "kundaliya": commit(suffix: "෴")
        case "yansaya":
            lastLetterKey = key
            insertLive("\u{E005}")
        default:
            let input = shift ? key.uppercased() : key
            if layer == .letters {
                lastLetterKey = key
                insertLive(mode == .sls ? SinhalaEngine.slsCharacter(for: key, shifted: shift) : input)
                // Rebuilding all controls after every character creates a
                // brief dead zone during rapid typing. Update titles in place
                // when Shift releases after a letter.
                if shift {
                    shift = false
                    refreshShiftedKeyAppearance()
                }
            }
            else { commit(suffix: input) }
        }
    }

    /// Shift only changes labels and a few glyphs. Walk existing keys instead
    /// of tearing down the whole grid (which drops touches mid-burst).
    private func refreshShiftedKeyAppearance() {
        guard layer == .letters else {
            rebuildKeys()
            return
        }
        for case let row as UIStackView in keyboardStack.arrangedSubviews {
            for case let button as NativeKeyButton in row.arrangedSubviews {
                let key = button.keyName
                if key == "rakaranshaya" {
                    if shift {
                        button.setTitle(nil, for: .normal)
                        button.setImage(joinerKeyImage(), for: .normal)
                        button.tintColor = .label
                        button.accessibilityLabel = "Zero Width Joiner"
                    } else {
                        button.setImage(nil, for: .normal)
                        button.setTitle(title(for: key), for: .normal)
                        button.accessibilityLabel = nil
                    }
                    button.setHint(hint(for: key))
                    continue
                }
                if key == "shift" {
                    let symbolName = shift ? "shift.fill" : "shift"
                    button.setImage(UIImage(systemName: symbolName), for: .normal)
                    continue
                }
                if ["delete", "emoji", "language", "globe", "dismiss", "return", "space", "123", "ABC", "#+="].contains(key)
                    || key.hasPrefix(Self.topEmojiKeyPrefix)
                    || key.hasPrefix(Self.contextualKeyPrefix) {
                    continue
                }
                if key == "rakaranshaya" { continue }
                button.setImage(nil, for: .normal)
                button.setTitle(title(for: key), for: .normal)
                button.setHint(hint(for: key))
            }
        }
        if mode != .sls, layer == .letters, showsCandidateBar {
            updatePredictions(for: predictionPrefix)
        }
    }

    private func showEmojiPicker() {
        guard emojiPicker == nil else { return }
        hideClipboardHistory()
        commitActiveComposition()
        let picker = EmojiPickerView()
        picker.onSelect = { [weak self] emoji in self?.commit(suffix: emoji) }
        picker.onDismiss = { [weak self] in self?.hideEmojiPicker() }
        picker.onDelete = { [weak self, weak picker] in
            self?.deleteRepeatAnchor = picker?.documentDeleteControl
            self?.deleteRepeatBeganAt = CACurrentMediaTime()
            self?.startDeleteHoldCountdown()
            DispatchQueue.main.async { [weak self] in
                self?.deleteOnce()
            }
        }
        picker.onDeleteHoldBegan = { [weak self, weak picker] in
            self?.deleteRepeatAnchor = picker?.documentDeleteControl
            self?.beginDeleteRepeat()
        }
        picker.onDeleteHoldEnded = { [weak self] in self?.stopDeleteRepeat() }
        emojiPicker = picker
        // Set the extension's preferred size before adding the overlay.  This
        // is what moves the host's composer up, matching the system picker.
        applyHostHeightConstraint(reason: "showEmojiPicker")
        view.setNeedsUpdateConstraints()
        candidateBar.isHidden = true
        keyboardStack.isHidden = true
        updateClipboardButtonVisibility()
        // `keyboardContentContainer` stays bottom-anchored to the regular
        // Sinhala key strip. Emoji has a taller host height, so placing the
        // picker there made its new upper area empty. Attach it to `view` so
        // the search field and emoji grid fill the complete expanded tray.
        view.addSubview(picker)
        view.bringSubviewToFront(picker)
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
        applyHostHeightConstraint(reason: "hideEmojiPicker")
        view.setNeedsUpdateConstraints()
        candidateBar.isHidden = !showsCandidateBar
        keyboardStack.isHidden = false
        updateClipboardButtonVisibility()
    }


    private var showsClipboardButton: Bool {
        showsCandidateBar
            && KeyboardPreferences.clipboardHistoryEnabled()
            && emojiPicker == nil
            && clipboardHistoryPanel == nil
            && hasUsableKeyboardWidth
            && !candidateBar.isHidden
    }

    private func updateClipboardButtonVisibility() {
        let showing = showsClipboardButton
        if clipboardButton.isHidden == showing {
            clipboardButton.isHidden = !showing
        }
        let leading = showing ? clipboardButtonWidth : 0
        if candidateSegmentsLeading?.constant != leading {
            candidateSegmentsLeading?.constant = leading
        }
        if showing {
            keyboardContentContainer.bringSubviewToFront(clipboardButton)
        }
    }

    @objc private func clipboardButtonPressed() {
        showClipboardHistory()
    }

    private func showClipboardHistory() {
        guard clipboardHistoryPanel == nil, emojiPicker == nil else { return }
        guard KeyboardPreferences.clipboardHistoryEnabled() else { return }
        commitActiveComposition()
        captureClipboardIfNeeded()
        let panel = ClipboardHistoryView()
        panel.onSelect = { [weak self] text in
            self?.hideClipboardHistory()
            self?.commit(suffix: text)
        }
        panel.onDismiss = { [weak self] in self?.hideClipboardHistory() }
        panel.onClearHistory = { [weak self] in
            ClipboardHistoryStore.clearHistory()
            self?.clipboardHistoryPanel?.configure(
                recentItems: [],
                pinnedItems: ClipboardHistoryStore.pinnedItems(),
                hasFullAccess: self?.hasFullAccess ?? false
            )
        }
        panel.onDeleteRecentAt = { index in
            ClipboardHistoryStore.remove(at: index)
        }
        panel.onPinRecentAt = { index in
            ClipboardHistoryStore.pin(at: index)
        }
        panel.onDeletePinnedAt = { index in
            ClipboardHistoryStore.removePinned(at: index)
        }
        panel.onItemActionFeedback = { [weak self] in
            self?.keyFeedback?.selectionChanged()
        }
        panel.configure(
            recentItems: ClipboardHistoryStore.items(),
            pinnedItems: ClipboardHistoryStore.pinnedItems(),
            hasFullAccess: hasFullAccess
        )
        clipboardHistoryPanel = panel
        candidateBar.isHidden = true
        keyboardStack.isHidden = true
        updateClipboardButtonVisibility()
        view.addSubview(panel)
        view.bringSubviewToFront(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func hideClipboardHistory() {
        clipboardHistoryPanel?.removeFromSuperview()
        clipboardHistoryPanel = nil
        candidateBar.isHidden = !showsCandidateBar
        keyboardStack.isHidden = false
        updateClipboardButtonVisibility()
    }

    private func startClipboardCaptureIfNeeded() {
        stopClipboardCapture()
        guard KeyboardPreferences.clipboardHistoryEnabled() else { return }
        refreshClipboardHistoryIfNeeded()
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshClipboardHistoryIfNeeded()
        }

        // General-pasteboard notifications are not delivered reliably to every
        // keyboard-extension host. Polling its change count while the keyboard
        // is onscreen provides the same live update without re-reading text
        // unless the board actually changed.
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refreshClipboardHistoryIfNeeded()
        }
        clipboardRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopClipboardCapture() {
        clipboardRefreshTimer?.invalidate()
        clipboardRefreshTimer = nil
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
            self.pasteboardObserver = nil
        }
    }

    private func captureClipboardIfNeeded() {
        _ = refreshClipboardHistoryIfNeeded()
    }

    @discardableResult
    private func refreshClipboardHistoryIfNeeded() -> Bool {
        let secure = textDocumentProxy.isSecureTextEntry == true
        let changed = ClipboardHistoryStore.captureFromPasteboardIfNeeded(
            hasFullAccess: hasFullAccess,
            isSecureField: secure
        )
        guard changed else { return false }
        clipboardHistoryPanel?.configure(
            recentItems: ClipboardHistoryStore.items(),
            pinnedItems: ClipboardHistoryStore.pinnedItems(),
            hasFullAccess: hasFullAccess
        )
        return true
    }

    /// Finish the in-progress word, then insert a bare newline. Custom
    /// keyboards have no Return-key event; `insertText("\n")` is how UIKit
    /// delivers Search, Go, Send, Done, and a plain newline to the host.
    /// Search bars typically resign first responder after that — which is
    /// how the system keyboard disappears. We never call `dismissKeyboard()`.
    private func performReturnKey() {
        if language == .english { commitEnglish(suffix: "\n"); return }
        if temporaryLatinWordActive {
            endTemporaryLatinWordMode()
        }
        flushPendingComposition()
        learnActiveWord()
        commitActiveComposition()
        // Keep `\n` in its own insert. Appending it to the word in one
        // `insertText` makes some hosts treat the whole string as typed
        // text instead of a Return press.
        insertIntoDocument("\n")
        cancelLocalCompositionWithoutCommit(refreshingPredictions: true)
    }

    /// `UITextDocumentProxy` changes as focus moves between host controls.
    /// Use its return trait so the key matches the action users expect.
    private var returnKeyTitle: String? {
        switch textDocumentProxy.returnKeyType {
        case .default, .none: return nil
        case .go: return "Go"
        case .google: return "Google"
        case .join: return "Join"
        case .next: return "Next"
        case .route: return "Route"
        case .search: return "Search"
        case .send: return "Send"
        case .yahoo: return "Yahoo"
        case .done: return "Done"
        // Keep the label short enough for the return key's width; the system
        // keyboard likewise avoids the full "Emergency Call" string here.
        case .emergencyCall: return "Call"
        case .continue: return "Continue"
        @unknown default: return nil
        }
    }

    /// The system keyboard only paints submit-style Return keys blue. `.next`
    /// stays on the standard grey surface (e.g. Wi‑Fi username → password).
    private var usesProminentReturnKey: Bool {
        switch textDocumentProxy.returnKeyType {
        case .go, .google, .join, .route, .search, .send, .yahoo, .done, .emergencyCall, .continue:
            return true
        case .default, .none, .next:
            return false
        @unknown default:
            return false
        }
    }

    /// Surface the punctuation that hosts conventionally expect for URL and
    /// email fields without changing the Sinhala letter rows themselves.
    private var contextualPunctuationKeys: [String] {
        switch textDocumentProxy.keyboardType {
        case .URL, .webSearch: return [contextualKey("."), contextualKey("/")]
        case .emailAddress: return [contextualKey("@"), contextualKey(".")]
        case .twitter: return [contextualKey("@"), contextualKey("#")]
        default: return []
        }
    }

    private func contextualKey(_ character: String) -> String {
        Self.contextualKeyPrefix + character
    }

    private func contextualCharacter(for key: String) -> String? {
        guard key.hasPrefix(Self.contextualKeyPrefix) else { return nil }
        return String(key.dropFirst(Self.contextualKeyPrefix.count))
    }

    /// iOS 26's URL/web Go key is a trailing arrow rather than the word "Go".
    private var usesReturnKeyArrowSymbol: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return textDocumentProxy.returnKeyType == .go
    }

    private func switchKeyboardLanguage() {
        guard englishEnabled else { return }
        view.layoutIfNeeded()
        languageTransitionOverlay?.removeFromSuperview()
        let sourceButton = keyButton(named: "language")
        let revealOrigin = sourceButton.map {
            $0.convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: keyboardContentContainer)
        } ?? CGPoint(x: keyboardContentContainer.bounds.midX, y: keyboardContentContainer.bounds.maxY)
        let previousKeyboard = keyboardContentContainer.snapshotView(afterScreenUpdates: false)
        stopDeleteRepeat()
        commitActiveComposition()
        endTemporaryLatinWordMode()
        cancelLocalCompositionWithoutCommit()
        language = language == .english ? .sinhala : .english
        KeyboardPreferences.setActiveLanguage(language)
        shift = false
        layer = .letters
        rebuildKeys()
        updatePredictions(for: "")
        animateLanguageReveal(from: revealOrigin, coveringWith: previousKeyboard)
    }

    /// Reveal the newly selected keyboard through a quick circular wipe that
    /// starts at the language key. The old snapshot is only visual and never
    /// intercepts input after the transition completes.
    private func animateLanguageReveal(from origin: CGPoint, coveringWith oldSnapshot: UIView?) {
        guard let oldSnapshot, !keyboardContentContainer.bounds.isEmpty else { return }
        keyboardContentContainer.layoutIfNeeded()
        oldSnapshot.frame = keyboardContentContainer.bounds
        oldSnapshot.isUserInteractionEnabled = false
        keyboardContentContainer.addSubview(oldSnapshot)
        languageTransitionOverlay = oldSnapshot

        let removeOverlay = { [weak self, weak oldSnapshot] in
            oldSnapshot?.removeFromSuperview()
            if self?.languageTransitionOverlay === oldSnapshot {
                self?.languageTransitionOverlay = nil
            }
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.animate(withDuration: 0.12, animations: { oldSnapshot.alpha = 0 }, completion: { _ in removeOverlay() })
            return
        }

        let bounds = oldSnapshot.bounds
        let localOrigin = keyboardContentContainer.convert(origin, to: oldSnapshot)
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
        let maximumRadius = corners.map { hypot($0.x - localOrigin.x, $0.y - localOrigin.y) }.max() ?? bounds.width
        let initialRadius = max(sourceLanguageKeyRadius(), 2)
        func cutoutPath(radius: CGFloat) -> CGPath {
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(ovalIn: CGRect(x: localOrigin.x - radius, y: localOrigin.y - radius,
                                                    width: radius * 2, height: radius * 2)))
            path.usesEvenOddFillRule = true
            return path.cgPath
        }

        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.fillColor = UIColor.black.cgColor
        mask.path = cutoutPath(radius: maximumRadius)
        oldSnapshot.layer.mask = mask
        let wipe = CABasicAnimation(keyPath: "path")
        wipe.fromValue = cutoutPath(radius: initialRadius)
        wipe.toValue = cutoutPath(radius: maximumRadius)
        wipe.duration = 0.20
        wipe.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // Fade the outgoing keyboard as its circular cutout grows. This keeps
        // the wipe legible without leaving a hard moving edge across keycaps.
        oldSnapshot.layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.20
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock(removeOverlay)
        mask.add(wipe, forKey: "languageReveal")
        oldSnapshot.layer.add(fade, forKey: "languageFade")
        CATransaction.commit()
    }

    private func sourceLanguageKeyRadius() -> CGFloat {
        guard let button = keyButton(named: "language") else { return 2 }
        return max(button.bounds.width, button.bounds.height) * 0.48
    }

    private func englishContext() -> EnglishWordContext? {
        let proxy = textDocumentProxy
        // UIKit commonly represents an empty side of the caret with nil.
        // If an owned word exists but its preceding context is unavailable,
        // withhold replacements rather than guessing that the text survived.
        guard let before = proxy.documentContextBeforeInput ?? (englishOwnedWord.isEmpty ? "" : nil) else { return nil }
        return .init(before: before, after: proxy.documentContextAfterInput ?? "",
                     hasSelection: !(proxy.selectedText?.isEmpty ?? true))
    }

    private func insertEnglish(_ source: String) {
        noteInput()
        pendingAutocorrection = nil
        englishCorrection = nil
        let context = englishContext()
        if englishOwnedWord.isEmpty {
            englishCanLearnWord = context?.prefix.isEmpty == true && context?.canReplace == true
        }
        if context?.hasSelection == true { englishOwnedWord = ""; englishCanLearnWord = false }
        englishOwnedWord += source
        insertIntoDocument(source, applyingSmartSpacing: true)
        let expected = context.flatMap { $0.hasSelection ? nil : EnglishWordContext(before: $0.before + source, after: $0.after) }
        requestEnglishPredictions(delay: 0.025, context: expected)
    }

    private func requestEnglishPredictions(delay: TimeInterval, context supplied: EnglishWordContext? = nil) {
        guard !isDeleteRepeatActive else { return }
        pendingPredictionUpdate?.cancel()
        pendingPredictionToken?.cancel()
        predictionGeneration += 1
        let generation = predictionGeneration
        englishCorrection = nil
        let showRail = showsCandidateBar
        let correct = KeyboardPreferences.hotPath.autocorrectEnabled && inputFieldAllowsPredictions
        guard (showRail || correct), let context = supplied ?? englishContext(), !context.hasSelection else {
            englishDisplayedContext = nil
            clearCandidateRailDisplay()
            applyKeyTouchWeights([:])
            return
        }
        let prefix = context.prefix
        if !prefix.isEmpty { hasEnteredTextThisAppearance = true }
        predictionPrefix = prefix
        if !showRail { clearCandidateRailDisplay(); applyKeyTouchWeights([:]) }
        if showRail && !isKeyboardOverlayPresented {
            applyCandidateBarLayout()
            candidateBar.isHidden = false
            updateClipboardButtonVisibility()
        }
        let inflate = showRail && KeyboardPreferences.hotPath.predictiveTouchAreas && layer == .letters
        let request = SinhalaPredictionRequest(composingText: prefix, precedingWords: context.preceding, maximumResults: inflate ? 24 : 3)
        let provider = englishProvider
        let emojis = KeyboardPreferences.hotPath.emojiSuggestionsEnabled && showRail
        let tone = KeyboardPreferences.hotPath.emojiSkinTone
        let shifted = shift
        let token = PredictionCancellationToken()
        pendingPredictionToken = token
        let queue = predictionQueue
        let work = DispatchWorkItem { [weak self] in
            guard self != nil, !token.isCancelled else { return }
            queue.async {
                guard !token.isCancelled else { return }
                let ranked = showRail ? provider.candidates(for: request) : []
                guard !token.isCancelled else { return }
                let correction = correct && context.canAutocorrectAtBoundary ? provider.correction(for: prefix) : nil
                let emoji = emojis ? provider.emoji(for: prefix, bestWord: ranked.first?.text).map {
                    EmojiSkinToneApplicator.withPreferredSkinTone($0, tone: tone)
                } : []
                guard !token.isCancelled else { return }
                let weights = inflate ? provider.nextKeyWeights(latinBuffer: prefix, mode: .smartPhonetic,
                    shifted: shifted, from: ranked, precedingWords: context.preceding) : [:]
                DispatchQueue.main.async { [weak self] in
                    guard let self, !token.isCancelled, self.language == .english,
                          self.predictionGeneration == generation, self.englishContext() == context else { return }
                    self.englishCorrection = correction.map { (context, $0) }
                    self.englishDisplayedContext = context
                    if showRail {
                        var display = ranked.map(\.text)
                        if let correction, !display.contains(correction) { display.insert(correction, at: 0) }
                        self.applyPredictions(Array(display.prefix(3)), emoji: emoji, weights: weights,
                                              for: prefix, generation: generation)
                    }
                }
            }
        }
        pendingPredictionUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commitEnglish(suffix: String) {
        let formatted = smartTypography(for: suffix)
        // Apostrophes/hyphens belong to the token, but are deliberately not
        // eligible for automatic correction of either fragment.
        if !formatted.isEmpty, formatted.allSatisfy(EnglishWordContext.isWordCharacter) {
            insertEnglish(formatted)
            return
        }
        let context = englishContext()
        let ready = englishCorrection
        pendingPredictionToken?.cancel()
        englishCorrection = nil
        pendingAutocorrection = nil
        var committed = context?.prefix ?? ""
        if isAutocorrectionBoundary(formatted), KeyboardPreferences.hotPath.autocorrectEnabled,
           inputFieldAllowsPredictions, let context, context.canAutocorrectAtBoundary,
           let ready, ready.context == context,
           !KeyboardPreferences.isAutocorrectProtected(context.prefix) {
            deleteDocumentText(context.prefix)
            insertIntoDocument(ready.replacement)
            committed = ready.replacement
            pendingAutocorrection = .init(original: context.prefix, replacement: committed, suffix: formatted)
        }
        if inputFieldAllowsPredictions, englishCanLearnWord, context?.canAutocorrectAtBoundary == true,
           context?.prefix == englishOwnedWord {
            recordCommittedPredictionWord(committed, after: context?.preceding.last)
        }
        englishOwnedWord = ""
        englishCanLearnWord = false
        englishDisplayedContext = nil
        // Keep Return in its own proxy insert so host Search/Send works.
        insertIntoDocument(formatted, applyingSmartSpacing: formatted != "\n")
        // Smart punctuation may append a space. Record the actual delimiter
        // for immediate undo instead of assuming the raw key's length.
        if let pending = pendingAutocorrection, let before = textDocumentProxy.documentContextBeforeInput,
           let range = before.range(of: pending.replacement, options: .backwards) {
            pendingAutocorrection = .init(original: pending.original, replacement: pending.replacement,
                                          suffix: String(before[range.upperBound...]))
        }
        lastSpaceTimestamp = formatted == " " ? CACurrentMediaTime() : nil
        requestEnglishPredictions(delay: 0)
    }

    private func selectEnglishCandidate(_ candidate: String, isEmoji: Bool, sourceView: UIView) {
        guard let context = englishContext(), context == englishDisplayedContext,
              context.canReplaceWholeWord else { return }
        pendingAutocorrection = nil
        englishCorrection = nil
        replaceWordAroundCaret(context, with: candidate + " ")
        animateSuggestionAcceptance(from: sourceView)
        if isEmoji { EmojiCatalog.record(candidate) }
        else { recordPredictionSelection(candidate, after: context.preceding.last) }
        englishOwnedWord = ""
        englishCanLearnWord = false
        englishDisplayedContext = nil
        requestEnglishPredictions(delay: 0)
    }

    /// Replace the complete token intersected by the caret. Moving to the end
    /// first lets the ordinary backward-delete path remove both the edited
    /// prefix and the untouched suffix without retaining either fragment.
    private func replaceWordAroundCaret(_ context: EnglishWordContext, with replacement: String) {
        performDocumentEdit {
            if !context.suffix.isEmpty {
                self.textDocumentProxy.adjustTextPosition(byCharacterOffset: context.suffix.count)
            }
            self.deleteDocumentTextWhileEditing(context.wholeWord)
            self.textDocumentProxy.insertText(replacement)
        }
    }

    /// A short chip motion confirms that the visible suggestion performed a
    /// replacement. Host-app text is outside the extension's view hierarchy,
    /// so the feedback originates from the tapped candidate instead.
    private func animateSuggestionAcceptance(from sourceView: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled,
              let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = sourceView.convert(sourceView.bounds, to: keyboardContentContainer)
        snapshot.isUserInteractionEnabled = false
        keyboardContentContainer.addSubview(snapshot)
        UIView.animateKeyframes(withDuration: 0.20, delay: 0, options: [.calculationModeCubic, .beginFromCurrentState]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.35) {
                snapshot.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.35, relativeDuration: 0.65) {
                snapshot.transform = CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.94, y: 0.94)
                snapshot.alpha = 0
            }
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }

    private func schedulePredictions(for prefix: String) {
        requestPredictions(for: prefix, delay: 0.025)
    }

    private func updatePredictions(for prefix: String) {
        requestPredictions(for: prefix, delay: 0)
    }

    private func updatePredictionsAfterDelete(for prefix: String) {
        updatePredictions(for: prefix)
    }

    /// Gather host context on the main thread, rank on a dedicated queue, and
    /// return only the newest result to UIKit. Typing and transliteration
    /// therefore never wait for a dictionary scan or candidate animation.
    private func requestPredictions(for prefix: String, delay: TimeInterval) {
        if language == .english { requestEnglishPredictions(delay: delay); return }
        let prefix = inheritedPredictionPrefix + prefix
        guard !isDeleteRepeatActive else { return }
        pendingPredictionUpdate?.cancel()
        pendingPredictionUpdate = nil
        pendingPredictionToken?.cancel()
        predictionGeneration += 1
        let generation = predictionGeneration
        guard showsCandidateBar else {
            predictionPrefix = ""
            clearCandidateRailDisplay()
            applyKeyTouchWeights([:])
            return
        }
        // The attachment path temporarily hides the rail while the input view
        // has no width. A queued prediction refresh can outlive that phase, so
        // restore the visible state here rather than relying only on a key
        // rebuild to do it.
        if !isKeyboardOverlayPresented {
            applyCandidateBarLayout()
            candidateBar.isHidden = false
            updateClipboardButtonVisibility()
        }
        if !prefix.isEmpty {
            hasEnteredTextThisAppearance = true
        }
        // Keep the rail, but leave it blank until the user actually types.
        // Empty-context openers on appear made the keyboard look busy.
        if prefix.isEmpty && !hasEnteredTextThisAppearance {
            predictionPrefix = ""
            clearCandidateRailDisplay()
            applyKeyTouchWeights([:])
            return
        }
        predictionPrefix = prefix
        // Keep the previous rail visible while the next ranking runs. Blanking
        // all three slots on every keystroke made the bar flicker; selection
        // still rejects stale words that no longer match the live prefix.
        let latinBuffer = activePhoneticSource
        let inflateLetters = KeyboardPreferences.hotPath.predictiveTouchAreas
            && layer == .letters
            && mode != .sls
            && !latinBuffer.isEmpty
            && !prefix.isEmpty
        let request = SinhalaPredictionRequest(
            composingText: prefix,
            precedingWords: predictionContext(for: prefix),
            // Predictive hit areas only need enough candidates to distinguish
            // likely next letters; 24 avoids ranking a deep tail on every tap.
            maximumResults: inflateLetters ? 24 : 3
        )
        let provider = activePredictionProvider
        let emojiSuggestionsEnabled = KeyboardPreferences.hotPath.emojiSuggestionsEnabled
        let preferredEmojiSkinTone = KeyboardPreferences.hotPath.emojiSkinTone
        let token = PredictionCancellationToken()
        pendingPredictionToken = token
        let queue = predictionQueue
        let work = DispatchWorkItem { [weak self] in
            guard let self, !token.isCancelled else { return }
            let currentMode = self.mode
            let isShifted = self.shift
            let stillInflating = inflateLetters
                && self.layer == .letters
                && currentMode != .sls
                && !self.phoneticBuffer.isEmpty
            queue.async {
                guard !token.isCancelled else { return }
                let ranked = provider.candidates(for: request)
                guard !token.isCancelled else { return }
                let correctionCandidates = prefix.isEmpty
                    ? []
                    : SinhalaAutocorrectionService.shared.suggestions(for: prefix, maximumResults: 3)
                var displayRanked = ranked
                for correction in correctionCandidates.reversed() where !displayRanked.contains(where: { $0.text == correction.text }) {
                    displayRanked.insert(.init(text: correction.text, score: Double.greatestFiniteMagnitude), at: 0)
                }
                let emojiHits: [String]
                if emojiSuggestionsEnabled, !prefix.isEmpty {
                    emojiHits = SinhalaEmojiSuggestions.emoji(
                        forComposing: prefix,
                        bestWord: ranked.first?.text
                    ).map { EmojiSkinToneApplicator.withPreferredSkinTone($0, tone: preferredEmojiSkinTone) }
                } else {
                    emojiHits = []
                }
                guard !token.isCancelled else { return }
                let weights = stillInflating
                    ? provider.nextKeyWeights(
                        latinBuffer: latinBuffer,
                        mode: currentMode,
                        shifted: isShifted,
                        from: ranked,
                        precedingWords: request.precedingWords
                    )
                    : [:]
                DispatchQueue.main.async { [weak self] in
                    guard !token.isCancelled else { return }
                    self?.applyPredictions(
                        displayRanked.prefix(3).map(\.text),
                        emoji: emojiHits,
                        weights: weights,
                        for: prefix,
                        generation: generation
                    )
                }
            }
        }
        pendingPredictionUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyPredictions(
        _ ranked: [String],
        emoji: [String] = [],
        weights: [String: Double] = [:],
        for prefix: String,
        generation: Int
    ) {
        guard generation == predictionGeneration, showsCandidateBar else { return }
        pendingPredictionUpdate = nil
        predictionPrefix = prefix
        let previousCandidates = candidates
        let previousEmoji = emojiCandidates
        var ranked = ranked
        if AksharaEasterEgg.isCompleteTrueName(rendered: prefix, phoneticSource: activePhoneticSource) {
            ranked.removeAll { $0 == AksharaEasterEgg.trueNameDisplay }
            ranked.insert(AksharaEasterEgg.trueNameDisplay, at: 0)
            if ranked.count > 3 { ranked = Array(ranked.prefix(3)) }
        }
        // iOS gives the centre slot the strongest visual weight. Preserve the
        // dictionary ranking while presenting its best match in that slot.
        switch ranked.count {
        case 3: candidates = [ranked[1], ranked[0], ranked[2]]
        case 2: candidates = [ranked[1], ranked[0], nil]
        case 1: candidates = [nil, ranked[0], nil]
        default: candidates = [nil, nil, nil]
        }

        let showEmoji = !emoji.isEmpty
        if showEmoji {
            // Emoji replace the whole right column — never mix with the 3rd word.
            candidates[2] = nil
            emojiCandidates = [
                emoji.first,
                emoji.count > 1 ? emoji[1] : nil
            ]
        } else {
            emojiCandidates = [nil, nil]
        }

        let animated = CACurrentMediaTime() - lastInputTimestamp > 0.12
        for (index, button) in candidateButtons.enumerated() {
            // The third word button is only visible when emoji are off.
            if index == 2 {
                button.isHidden = showEmoji
                if showEmoji {
                    if previousCandidates[2] != nil {
                        button.setCandidate(nil, animated: false)
                    }
                    continue
                }
            }
            guard previousCandidates[index] != candidates[index] else { continue }
            button.setCandidate(candidates[index], animated: animated)
        }

        emojiCandidateStack?.isHidden = !showEmoji
        for (index, button) in emojiCandidateButtons.enumerated() {
            let value = index < emojiCandidates.count ? emojiCandidates[index] : nil
            button.isHidden = value == nil
            let previous = index < previousEmoji.count ? previousEmoji[index] : nil
            guard previous != value else { continue }
            button.setCandidate(value, animated: animated)
        }
        applyKeyTouchWeights(weights)
        if Self.layoutTraceEnabled {
            Self.layoutLogger.debug(
                "predictions updated count=\(ranked.count, privacy: .public) emoji=\(emoji.count, privacy: .public) railHidden=\(self.candidateBar.isHidden, privacy: .public) railHeight=\(Int(self.candidateBar.bounds.height), privacy: .public)"
            )
        }
    }

    private func clearCandidateRailDisplay() {
        candidates = [nil, nil, nil]
        emojiCandidates = [nil, nil]
        candidateButtons.forEach {
            $0.isHidden = false
            $0.setCandidate(nil, animated: false)
        }
        emojiCandidateButtons.forEach {
            $0.isHidden = true
            $0.setCandidate(nil, animated: false)
        }
        emojiCandidateStack?.isHidden = true
    }

    private func applyKeyTouchWeights(_ weights: [String: Double]) {
        let mapped: [String: CGFloat]
        if KeyboardPreferences.hotPath.predictiveTouchAreas {
            mapped = Dictionary(uniqueKeysWithValues: weights.map { ($0.key, CGFloat($0.value)) })
        } else {
            mapped = [:]
        }
        guard keyboardStack.keyTouchWeights != mapped else { return }
        keyboardStack.keyTouchWeights = mapped
        if KeyboardPreferences.hotPath.showTouchAreas {
            keyboardStack.setNeedsLayout()
        }
    }

    /// Personal-model writes can arrive while the bundled corpus is still
    /// loading. Keep that lock and UserDefaults serialization off the input
    /// thread so choosing a suggestion never delays the next key-down.
    private func recordPredictionSelection(_ word: String, after precedingWord: String?) {
        let provider = activePredictionProvider
        predictionQueue.async {
            provider.recordSelection(word, after: precedingWord)
        }
    }

    private func recordCommittedPredictionWord(_ word: String, after precedingWord: String?) {
        let provider = activePredictionProvider
        predictionQueue.async {
            provider.recordCommittedWord(word, after: precedingWord)
        }
    }

    @objc private func selectPrediction(_ sender: UIButton) {
        guard !isSpaceTrackpadActive, !numberDragActive else { return }
        guard let candidate = displayedCandidate(on: sender), !candidate.isEmpty else { return }
        let now = CACurrentMediaTime()
        if candidate == lastInsertedPrediction, now - lastPredictionInsertAt < 0.35 {
            return
        }
        lastInsertedPrediction = candidate
        lastPredictionInsertAt = now

        // A delayed ranking pass must not disable this chip or rewrite the
        // prefix after the user has already chosen a word.
        pendingPredictionUpdate?.cancel()
        pendingPredictionUpdate = nil
        pendingPredictionToken?.cancel()
        predictionGeneration += 1

        let isTrueName = candidate == AksharaEasterEgg.trueNameDisplay
        let isEmojiSuggestion = emojiCandidateButtons.contains(where: { $0 === sender })
            || (candidate.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji }
                && !candidate.unicodeScalars.contains { (0x0D80...0x0DFF).contains($0.value) }
                && candidate != AksharaEasterEgg.trueNameDisplay)
        if language == .english {
            selectEnglishCandidate(candidate, isEmoji: isEmojiSuggestion, sourceView: sender)
            return
        }
        let precedingWord = predictionContext(for: predictionPrefix).last
        let replacingPhonetic = !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty
        let wordToReplace = activePredictionWord()
        let wholeWordContext = cursorWordContext().flatMap { context -> EnglishWordContext? in
            guard !context.suffix.isEmpty, context.canReplaceWholeWord,
                  context.prefix == wordToReplace else { return nil }
            return context
        }

        if wholeWordContext == nil, replacingPhonetic {
            clearPhoneticComposition(refreshingPredictions: false)
            // Some hosts leave the unmarked preview in place after the
            // anchor-based delete. Only try again when we can still see it.
            if let before = textDocumentProxy.documentContextBeforeInput,
               NativeBackspace.endsWith(before, suffix: wordToReplace) {
                deleteDocumentText(wordToReplace)
            } else if !inheritedPredictionPrefix.isEmpty {
                // The local phonetic preview was appended to text that was
                // already in the editor. It has just been removed above, so
                // replace the inherited prefix as well instead of inserting a
                // duplicate candidate after it.
                deleteComposingWordIfPresent(inheritedPredictionPrefix)
            }
        } else if wholeWordContext == nil {
            abandonPendingComposition(removingFromDocument: false)
            deleteComposingWordIfPresent(wordToReplace)
        }
        // Selecting a prediction completes a word. Match the system keyboard
        // by committing its separator as part of the selection, so the next
        // keystroke begins the following word rather than appending to it.
        let inserted = isTrueName ? AksharaEasterEgg.trueNameInsert : candidate
        // Capture the chip before a middle-of-word replacement clears and
        // repopulates the candidate rail.
        animateSuggestionAcceptance(from: sender)
        if let wholeWordContext {
            // The local buffers describe the prefix that was edited, while
            // the document context also knows the untouched suffix. Drop the
            // buffers without deleting their host text, then replace both.
            cancelLocalCompositionWithoutCommit(refreshingPredictions: false)
            replaceWordAroundCaret(wholeWordContext, with: inserted + " ")
        } else {
            insertIntoDocument(inserted + " ", applyingSmartSpacing: true)
        }
        // Learn only a deliberate dictionary selection. True-name and emoji
        // chips must not enter the personal Sinhala model.
        if isTrueName {
            keyFeedback?.signatureWink()
        } else if isEmojiSuggestion {
            EmojiCatalog.record(candidate)
        } else {
            recordPredictionSelection(candidate, after: precedingWord)
        }
        resetSpaceSignatureTaps()
        // A selected candidate replaces the entire active word. Keeping the
        // old per-key deletion history would make the next Backspace delete a
        // prefix of the chosen word instead of one document character.
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        predictionPrefix = ""
        inheritedPredictionPrefix = ""
        if isTrueName || isEmojiSuggestion {
            invalidatePrecedingWordsCache()
        } else {
            // The host proxy often lags one insert behind, so next-word
            // ranking cannot wait for `documentContextBeforeInput`.
            seedPrecedingWordsAfterCommit(candidate, previous: precedingWord)
        }
        // Keep offering the following word, the same way Space does after a
        // commit. Clearing the rail here made suggestion chains die after
        // a single tap.
        updatePredictions(for: "")
    }

    private func displayedCandidate(on sender: UIButton) -> String? {
        if let button = sender as? CandidateButton, let text = button.displayedText, !text.isEmpty {
            return text
        }
        if sender.tag < candidates.count, let text = candidates[sender.tag], !text.isEmpty {
            return text
        }
        return nil
    }

    private func cursorWordContext() -> EnglishWordContext? {
        let proxy = textDocumentProxy
        guard let before = proxy.documentContextBeforeInput else { return nil }
        return EnglishWordContext(before: before, after: proxy.documentContextAfterInput ?? "",
                                  hasSelection: !(proxy.selectedText?.isEmpty ?? true))
    }

    /// `UITextDocumentProxy` gives a bounded pre-cursor window. Use it only to
    /// rank the current suggestion in memory; the provider never persists it.
    /// Ordinary letter keys reuse a cached preceding-word list so ranking does
    /// not pay for a proxy context read on every keystroke.
    private func predictionContext(for composingText: String) -> [String] {
        if language == .english { return englishContext()?.preceding ?? [] }
        if !precedingWordsCacheValid {
            refreshPrecedingWordsCache(composingText: composingText)
        }
        return cachedPrecedingWords
    }

    private func refreshPrecedingWordsCache(composingText: String) {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words = (textDocumentProxy.documentContextBeforeInput ?? "")
            .components(separatedBy: separators)
            .filter { word in
                !word.isEmpty && word.unicodeScalars.contains { (0x0D80...0x0DFF).contains($0.value) }
            }
        // With direct Wijesekara input the current partial word is already in
        // the host document. It is not prior-word context for its own ranking.
        // Use scalar matching: `String.hasSuffix` fails for Sinhala conjuncts.
        if !composingText.isEmpty, let last = words.last, NativeBackspace.endsWith(last, suffix: composingText) {
            words.removeLast()
        }
        cachedPrecedingWords = Array(words.suffix(2))
        precedingWordsCacheValid = true
    }

    private func invalidatePrecedingWordsCache() {
        precedingWordsCacheValid = false
    }

    private func seedPrecedingWordsAfterCommit(_ word: String, previous: String?) {
        var words: [String] = []
        if let previous, !previous.isEmpty { words.append(previous) }
        if !word.isEmpty { words.append(word) }
        cachedPrecedingWords = Array(words.suffix(2))
        precedingWordsCacheValid = true
    }

    private enum DeleteUnit {
        case character
        case word
    }

    /// System Delete: a tap removes one grapheme (or one phonetic source
    /// letter while transliterating). A sustained hold later removes words.
    private func deleteOnce(unit: DeleteUnit = .character) {
        if !isDeleteRepeatActive {
            reconcileCompositionStateWithDocument()
        }
        lastSpaceTimestamp = nil
        resetSpaceSignatureTaps()
        collapseSpaceAfterOpeningPunctuation = false
        noteInput()
        if unit == .character, undoPendingAutocorrectionIfPossible() {
            return
        }
        if language == .english {
            englishOwnedWord = ""
            englishCanLearnWord = false
            englishCorrection = nil
            if unit == .word, textDocumentProxy.selectedText?.isEmpty ?? true,
               let before = textDocumentProxy.documentContextBeforeInput {
                let segment = NativeBackspace.lastWordSegment(in: before)
                if segment.isEmpty { deleteBackwardFromDocument(times: 1) }
                else { deleteDocumentText(segment) }
            } else { deleteBackwardFromDocument(times: 1) }
            updatePredictionsAfterDelete(for: "")
            return
        }
        if let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            clearLocalCompositionKeepingDocument()
            deleteBackwardFromDocument(times: 1)
            updatePredictionsAfterDelete(for: "")
            return
        }
        if unit == .word {
            deleteWord()
            return
        }
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
        if pendingSource != nil {
            deletePendingCompositionOnce()
            return
        }
        guard !visibleEntries.isEmpty else {
            rawBuffer = ""
            // The next typed glyph starts a fresh local session. Re-read the
            // host prefix then: Delete may have changed the word immediately
            // before the caret.
            inheritedPredictionPrefix = ""
            deleteBackwardFromDocument(times: 1)
            updatePredictionsAfterDelete(for: "")
            return
        }
        deleteLastOwnedGrapheme()
    }

    private func deleteWord() {
        if !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty {
            clearPhoneticComposition()
            invalidatePrecedingWordsCache()
            return
        }
        if pendingSource != nil {
            discardPendingFromDocument()
        }
        if !visibleEntries.isEmpty {
            let word = visibleEntries.joined()
            deleteDocumentText(word)
            rawBuffer = ""
            visibleEntries.removeAll()
            visibleSources.removeAll()
            updatePredictionsAfterDelete(for: "")
            invalidatePrecedingWordsCache()
            return
        }
        guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            rawBuffer = ""
            deleteBackwardFromDocument(times: 1)
            return
        }
        let segment = NativeBackspace.lastWordSegment(in: before)
        if segment.isEmpty {
            deleteBackwardFromDocument(times: 1)
        } else {
            deleteDocumentText(segment)
        }
        rawBuffer = ""
        invalidatePrecedingWordsCache()
        updatePredictionsAfterDelete(for: "")
    }

    private func deleteLastOwnedGrapheme() {
        let rendered = visibleEntries.joined()
        guard let split = NativeBackspace.lastGrapheme(in: rendered) else {
            rawBuffer = ""
            deleteBackwardFromDocument(times: 1)
            return
        }
        trimOwnedEntries(to: split.remaining)
        deleteDocumentText(split.cluster)
        updatePredictionsAfterDelete(for: split.remaining)
    }

    /// Drops trailing Wijesekara history so it matches `remainingRendered`.
    /// One grapheme can span several keys (`ක` + `ා` → `කා`).
    private func trimOwnedEntries(to remainingRendered: String) {
        while visibleEntries.joined() != remainingRendered {
            guard !visibleEntries.isEmpty else { return }
            let prefix = visibleEntries.dropLast().joined()
            let lastVisible = visibleEntries.removeLast()
            let lastSource = visibleSources.isEmpty ? lastVisible : visibleSources.removeLast()
            if rawBuffer.hasSuffix(lastSource) {
                rawBuffer.removeLast(lastSource.count)
            } else {
                for _ in lastSource where !rawBuffer.isEmpty { rawBuffer.removeLast() }
            }
            if remainingRendered.hasPrefix(prefix), prefix != remainingRendered {
                let kept = String(remainingRendered.dropFirst(prefix.count))
                if !kept.isEmpty {
                    visibleEntries.append(kept)
                    visibleSources.append(kept)
                    rawBuffer += kept
                }
                return
            }
        }
        while visibleSources.count > visibleEntries.count {
            visibleSources.removeLast()
        }
    }

    private func clearLocalCompositionKeepingDocument() {
        cancelLocalCompositionWithoutCommit()
    }

    /// Drop every in-keyboard buffer without inserting it. Host text already
    /// written for this composition stays where it is; a new field must not
    /// receive the previous word.
    private func cancelLocalCompositionWithoutCommit(refreshingPredictions: Bool = false) {
        englishOwnedWord = ""
        englishCanLearnWord = false
        englishCorrection = nil
        englishDisplayedContext = nil
        pendingPredictionUpdate?.cancel()
        pendingPredictionUpdate = nil
        pendingPredictionToken?.cancel()
        predictionGeneration += 1
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        phoneticBuffer = ""
        lastPhoneticRendered = ""
        phoneticCompositionAnchor = nil
        committedPhoneticSegments.removeAll()
        abandonPendingComposition(removingFromDocument: false)
        predictionPrefix = ""
        inheritedPredictionPrefix = ""
        lastSpaceTimestamp = nil
        collapseSpaceAfterOpeningPunctuation = false
        invalidatePrecedingWordsCache()
        clearCandidateRailDisplay()
        applyKeyTouchWeights([:])
        endTemporaryLatinWordMode()
        if refreshingPredictions {
            updatePredictions(for: "")
        }
    }

    @discardableResult
    private func noteDocumentIdentifierChange() -> Bool {
        if let current = documentIdentifierIfAvailable() {
            let changed = CompositionHygiene.documentIdentifierChanged(
                previous: lastDocumentIdentifier,
                current: current
            )
            lastDocumentIdentifier = current
            if changed {
                hasEnteredTextThisAppearance = false
            }
            return changed
        }
        // Classic UIKit hosts on iOS 26 often omit `documentIdentifier`.
        // Losing a previous id is still a field switch; staying nil is not.
        guard lastDocumentIdentifier != nil else { return false }
        lastDocumentIdentifier = nil
        hasEnteredTextThisAppearance = false
        return true
    }

    /// Swift overlays `documentIdentifier` as a non-optional `UUID`. UIKit
    /// returns nil before the input session is attached, and on some iOS 26
    /// hosts while `_controllerState` is unset. Bridging that nil traps with
    /// `EXC_BREAKPOINT`. KVC keeps the nil so we can skip until the proxy is live.
    private func documentIdentifierIfAvailable() -> UUID? {
        (textDocumentProxy as AnyObject).value(forKey: "documentIdentifier") as? UUID
    }

    /// Delete `word` only when it is still immediately before the caret.
    /// Missing proxy context is treated as "still ours": many hosts omit
    /// `documentContextBeforeInput` unless Full Access is on.
    private func deleteComposingWordIfPresent(_ word: String) {
        guard !word.isEmpty else { return }
        if let before = textDocumentProxy.documentContextBeforeInput,
           !NativeBackspace.endsWith(before, suffix: word) {
            return
        }
        deleteDocumentText(word)
    }

    /// Keeps the extension-owned composition history in sync with the host
    /// editor without reading or retaining its text. `UITextDocumentProxy`
    /// can change independently when the host sends a message, clears a
    /// draft, applies an edit, or the user selects text. A new
    /// `documentIdentifier` always cancels leftover Smart Phonetic state,
    /// including when context is nil (common without Full Access).
    private func reconcileCompositionStateWithDocument() {
        if noteDocumentIdentifierChange() {
            documentStateMayHaveChanged = false
            cancelLocalCompositionWithoutCommit(refreshingPredictions: true)
            return
        }
        let renderedWord = activeRenderedWord()
        // Do not let `isApplyingOwnEdit` hide a host's immediate send/reset.
        // WhatsApp-like editors can clear and reuse the same text input during
        // the async callback window.  When a local preview exists, checking
        // its suffix before accepting the next key is the only reliable
        // boundary; an ordinary idle keystroke still avoids the proxy read.
        let mustValidateActiveComposition = !renderedWord.isEmpty
        guard documentStateMayHaveChanged || mustValidateActiveComposition else { return }
        documentStateMayHaveChanged = false
        guard CompositionHygiene.documentContextInvalidatedComposition(
            renderedWord: renderedWord,
            documentContextBeforeInput: textDocumentProxy.documentContextBeforeInput,
            contextIsExpected: hasFullAccess
        ) else { return }
        cancelLocalCompositionWithoutCommit(refreshingPredictions: true)
    }

    @objc private func handleDeleteLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            deleteRepeatAnchor = recognizer.view
            deleteRepeatRecognizer = recognizer
            beginDeleteRepeat()
        case .ended:
            stopDeleteRepeat()
        case .cancelled, .failed:
            // On device, a competing keyboard-window gesture or a host
            // round-trip stall often cancels the recognizer while the finger
            // is still on Delete. Keep repeating until a real lift arrives.
            handleDeleteTouchCancellation()
        default:
            break
        }
    }

    /// Host `deleteBackward` often cancels the original touch. Once repeat
    /// has started, treat that as a tracking glitch rather than a lift.
    private func handleDeleteTouchCancellation() {
        guard isDeleteRepeatActive else { return }
        deleteRepeatLostTouchAt = deleteRepeatLostTouchAt ?? CACurrentMediaTime()
    }

    private func startDeleteHoldCountdown() {
        deleteHoldWork?.cancel()
        deleteRepeatLostTouchAt = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deleteHoldWork = nil
            guard self.deleteRepeatTouchStillHeld else { return }
            self.beginDeleteRepeat()
        }
        deleteHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
    }

    /// The system keyboard keeps deleting characters, then switches to words
    /// after a sustained hold. Touch-down already removed the first unit.
    private func beginDeleteRepeat() {
        deleteHoldWork?.cancel()
        deleteHoldWork = nil
        deleteRepeatLostTouchAt = nil
        guard !isDeleteRepeatActive else { return }
        isDeleteRepeatActive = true
        pendingPredictionUpdate?.cancel()
        pendingPredictionUpdate = nil
        pendingPredictionToken?.cancel()
        predictionGeneration += 1
        if deleteRepeatBeganAt == 0 {
            deleteRepeatBeganAt = CACurrentMediaTime()
        }
        deleteOnce()
        startDeleteRepeatTimer()
    }

    private func startDeleteRepeatTimer() {
        deleteRepeater?.invalidate()
        let interval = deleteRepeatUsesWords
            ? max(0.15, KeyboardPreferences.hotPath.deleteRepeatInterval * 2.2)
            : KeyboardPreferences.hotPath.deleteRepeatInterval
        let repeater = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleDeleteRepeatTick()
        }
        repeater.tolerance = interval * 0.2
        deleteRepeater = repeater
        RunLoop.main.add(repeater, forMode: .common)
    }

    private func handleDeleteRepeatTick() {
        if deleteRepeatTouchStillHeld {
            deleteRepeatLostTouchAt = nil
        } else {
            let lostAt = deleteRepeatLostTouchAt ?? CACurrentMediaTime()
            deleteRepeatLostTouchAt = lostAt
            if CACurrentMediaTime() - lostAt < 0.18 {
                return
            }
            stopDeleteRepeat()
            return
        }
        let elapsed = CACurrentMediaTime() - deleteRepeatBeganAt
        if !deleteRepeatUsesWords, elapsed >= 1.0 {
            deleteRepeatUsesWords = true
            deleteOnce(unit: .word)
            startDeleteRepeatTimer()
            return
        }
        deleteOnce(unit: deleteRepeatUsesWords ? .word : .character)
    }

    private var deleteRepeatTouchStillHeld: Bool {
        if let recognizer = deleteRepeatRecognizer {
            switch recognizer.state {
            case .began, .changed:
                return true
            default:
                break
            }
        }
        guard let anchor = deleteRepeatAnchor else { return true }
        if let button = anchor as? UIControl {
            return button.isTracking || button.isHighlighted
        }
        return true
    }

    @objc private func stopDeleteRepeat() {
        deleteHoldWork?.cancel()
        deleteHoldWork = nil
        deleteRepeatLostTouchAt = nil
        let wasRepeating = isDeleteRepeatActive
        deleteRepeater?.invalidate()
        deleteRepeater = nil
        isDeleteRepeatActive = false
        deleteRepeatUsesWords = false
        deleteRepeatBeganAt = 0
        deleteRepeatAnchor = nil
        deleteRepeatRecognizer = nil
        if wasRepeating {
            updatePredictions(for: activeRenderedWord())
            if needsKeyRebuildWhenGeometryIsStable {
                rebuildKeys()
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === numberDragRecognizer else { return true }
        guard layer == .letters, !isKeyboardOverlayPresented, !isSpaceTrackpadActive else { return false }
        return (touch.view as? NativeKeyButton)?.keyName == "123"
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer !== numberDragRecognizer && otherGestureRecognizer !== numberDragRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === numberDragRecognizer {
            return layer == .letters && !isDeleteRepeatActive
                && !isKeyboardOverlayPresented && !isSpaceTrackpadActive
        }
        guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer,
              let button = swipe.view as? NativeKeyButton,
              button.keyName == "space" else { return true }
        // Enter is swipe-up only; exit also accepts swipe-down.
        if swipe.direction == .down {
            return temporaryLatinWordActive
        }
        return swipe.direction == .up
    }

    /// Direct Wijesekara alternates that do not fit on a phone's primary
    /// layer. `input` may be a composition token while `display` remains the
    /// finished Sinhala form that users expect in the picker.
    private func wijesekaraAlternates(for key: String) -> [(display: String, input: String)]? {
        switch key {
        case ".": return [("ඟ", "ඟ")]
        case "c": return [("ඦ", "ඦ")]
        case "v": return [("ඬ", "ඬ")]
        case "o": return [("ඳ", "ඳ")]
        case "r": return [("ර්‍", "\u{E002}")]
        case "x": return [("ඃ", "ඃ")]
        case ",": return [("ඏ", "ඏ")]
        default: return nil
        }
    }

    private func punctuationAlternates(for key: String) -> [String]? {
        switch contextualCharacter(for: key) ?? key {
        case ".": return [".", "…", "!", "?", "෴"]
        case ",": return [",", ";", ":", "؟"]
        case "'": return ["'", "‘", "’", "\""]
        case "\"": return ["\"", "“", "”", "'"]
        case "?": return ["?", "!", "…"]
        default: return nil
        }
    }

    @objc private func handleSanyakayaLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? NativeKeyButton,
              let key = button.accessibilityIdentifier,
              let alternates = wijesekaraAlternates(for: key) else { return }
        switch recognizer.state {
        case .began:
            // Suppress the key's normal touch-up action once the alternate
            // picker is open. A quick tap never reaches this state.
            button.markLongPressHandled()
            button.suppressesCharacterPreview = true
            hideKeyPreview()
            let baseCharacter = SinhalaEngine.slsCharacter(for: key, shifted: shift)
            let choices = [(display: baseCharacter, input: baseCharacter)] + alternates
            presentedAlternateChoices = orderedAlternateChoices(choices, for: button)
            showAlternatePicker(
                for: button,
                choices: presentedAlternateChoices.map(\.display),
                selectedIndex: presentedAlternateChoices.firstIndex(where: { $0.input == baseCharacter }) ?? 0
            )
            keyFeedback?.selectionChanged()
        case .changed:
            guard let picker = alternatePicker else { return }
            _ = picker.select(at: recognizer.location(in: picker))
        case .ended:
            let selected = alternatePicker?.selectedIndex ?? 0
            let choice = presentedAlternateChoices.indices.contains(selected)
                ? presentedAlternateChoices[selected].input
                : alternates[0].input
            hideAlternatePicker()
            button.suppressesCharacterPreview = false
            lastLetterKey = key
            insertLive(choice)
        case .cancelled, .failed:
            hideAlternatePicker()
            button.suppressesCharacterPreview = false
        default:
            break
        }
    }

    @objc private func handlePunctuationLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let button = recognizer.view as? NativeKeyButton,
              let key = button.accessibilityIdentifier,
              let choices = punctuationAlternates(for: key) else { return }
        switch recognizer.state {
        case .began:
            button.markLongPressHandled()
            button.suppressesCharacterPreview = true
            hideKeyPreview()
            presentedAlternateChoices = orderedAlternateChoices(
                choices.map { (display: $0, input: $0) },
                for: button
            )
            showAlternatePicker(
                for: button,
                choices: presentedAlternateChoices.map(\.display),
                selectedIndex: presentedAlternateChoices.firstIndex(where: { $0.input == choices[0] }) ?? 0
            )
            keyFeedback?.selectionChanged()
        case .changed:
            guard let picker = alternatePicker else { return }
            _ = picker.select(at: recognizer.location(in: picker))
        case .ended:
            let selected = alternatePicker?.selectedIndex ?? 0
            let choice = presentedAlternateChoices.indices.contains(selected)
                ? presentedAlternateChoices[selected].input
                : choices[0]
            hideAlternatePicker()
            button.suppressesCharacterPreview = false
            commit(suffix: choice)
        case .cancelled, .failed:
            hideAlternatePicker()
            button.suppressesCharacterPreview = false
        default:
            break
        }
    }

    private func orderedAlternateChoices(
        _ choices: [(display: String, input: String)],
        for button: NativeKeyButton
    ) -> [(display: String, input: String)] {
        guard choices.count > 1 else { return choices }
        let keyFrame = button.convert(button.bounds, to: view)
        let itemWidth = max(keyFrame.width, usesPadLayout ? 58 : 44)
        let requiredWidth = itemWidth * CGFloat(choices.count) + 8
        let expandsRight = keyFrame.minX - 4 + requiredWidth <= view.bounds.maxX - 2
        guard !expandsRight else { return choices }
        // The base character remains under the held finger, with alternates
        // fanning toward the available space on the left.
        return Array(choices.dropFirst().reversed()) + [choices[0]]
    }

    private func showAlternatePicker(
        for button: NativeKeyButton,
        choices: [String],
        selectedIndex: Int
    ) {
        let picker = AlternateCharacterPickerView(choices: choices)
        let keyFrame = button.convert(button.bounds, to: view)
        // Keep the choices clear of the held character, so the user can still
        // use that key as a spatial anchor while sliding to an alternate.
        let itemWidth = max(keyFrame.width, usesPadLayout ? 58 : 44)
        let height = keyFrame.height + 8
        let size = CGSize(width: itemWidth * CGFloat(choices.count) + 8, height: height)
        let selectedIndex = min(max(selectedIndex, 0), choices.count - 1)
        let selectedX = keyFrame.minX - 4 - CGFloat(selectedIndex) * itemWidth
        let x = min(max(selectedX, view.bounds.minX + 2), view.bounds.maxX - size.width - 2)
        picker.frame = CGRect(
            x: x,
            y: max(0, keyFrame.minY - size.height - 7),
            width: size.width,
            height: size.height
        )
        picker.select(index: selectedIndex)
        view.addSubview(picker)
        view.bringSubviewToFront(picker)
        alternatePicker = picker
    }

    private func hideAlternatePicker() {
        alternatePicker?.removeFromSuperview()
        alternatePicker = nil
        presentedAlternateChoices.removeAll()
    }

    private func commit(suffix: String) {
        if language == .english { commitEnglish(suffix: suffix); return }
        flushPendingComposition()
        let formattedSuffix = smartTypography(for: suffix)
        let committedWord = activeRenderedWord()
        pendingAutocorrection = nil
        if isAutocorrectionBoundary(formattedSuffix),
           KeyboardPreferences.hotPath.autocorrectEnabled,
           let replacement = SinhalaAutocorrectionService.shared.correction(for: committedWord) {
            applyAutocorrection(from: committedWord, to: replacement, suffix: formattedSuffix)
            return
        }
        learnActiveWord()
        if !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty {
            commitPhoneticComposition(suffix: formattedSuffix)
            updatePredictions(for: "")
            return
        }
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        inheritedPredictionPrefix = ""
        updatePredictions(for: "")
        insertIntoDocument(formattedSuffix, applyingSmartSpacing: true)
    }

    private func isAutocorrectionBoundary(_ suffix: String) -> Bool {
        suffix == " " || suffix == "\n" || suffix == "." || suffix == "?" || suffix == "!" || suffix == "။"
    }

    /// The active rendering is already written to the document for every
    /// layout. Replace that exact suffix before committing its delimiter.
    private func applyAutocorrection(from original: String, to replacement: String, suffix: String) {
        guard !original.isEmpty, original != replacement else { return }
        let preceding = predictionContext(for: original).last
        deleteDocumentText(original)
        insertIntoDocument(replacement + suffix, applyingSmartSpacing: true)
        pendingAutocorrection = .init(original: original, replacement: replacement, suffix: suffix)
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        phoneticBuffer = ""
        lastPhoneticRendered = ""
        phoneticCompositionAnchor = nil
        committedPhoneticSegments.removeAll()
        inheritedPredictionPrefix = ""
        predictionPrefix = ""
        seedPrecedingWordsAfterCommit(replacement, previous: preceding)
        updatePredictions(for: "")
    }

    private func undoPendingAutocorrectionIfPossible() -> Bool {
        guard let pending = pendingAutocorrection,
              textDocumentProxy.selectedText?.isEmpty ?? true,
              let before = textDocumentProxy.documentContextBeforeInput,
              NativeBackspace.endsWith(before, suffix: pending.replacement + pending.suffix) else {
            pendingAutocorrection = nil
            return false
        }
        deleteDocumentText(pending.replacement + pending.suffix)
        insertIntoDocument(pending.original)
        if language == .english { englishOwnedWord = pending.original; englishCanLearnWord = true }
        KeyboardPreferences.recordAutocorrectionReversal(for: pending.original)
        pendingAutocorrection = nil
        invalidatePrecedingWordsCache()
        updatePredictions(for: pending.original)
        return true
    }

    /// Direct Wijesekara insert. Kombuwa and independent vowels are written
    /// immediately, then rewritten in place if a following key completes the
    /// syllable (`ෙ` + `ක` → `කෙ`, `අ` + `ා` → `ආ`).
    private func insertLive(_ source: String) {
        if language == .english { insertEnglish(source); return }
        noteInput()
        pendingAutocorrection = nil
        captureInheritedPredictionPrefixIfNeeded()
        if temporaryLatinWordActive {
            insertIntoDocument(source, applyingSmartSpacing: true)
            return
        }
        if mode != .sls {
            phoneticBuffer += source
            updatePhoneticComposition()
            return
        }
        if source == "\u{E002}" {
            insertRepaya()
            return
        }
        if let pendingSource, let pendingKind {
            switch pendingKind {
            case .prebase where SinhalaEngine.canExtendPrebase(pendingSource, with: source):
                updatePendingComposition(pendingSource + source, kind: .prebase)
                return
            case .independentVowel where SinhalaEngine.combinesWithIndependentVowel(pendingSource, suffix: source):
                updatePendingComposition(pendingSource + source, kind: .independentVowel)
                return
            default:
                flushPendingComposition()
                insertLive(source)
                return
            }
        }
        if source == "ෙ" {
            beginPendingComposition(source, kind: .prebase)
            return
        }
        if SinhalaEngine.isIndependentVowel(source) {
            beginPendingComposition(source, kind: .independentVowel)
            return
        }
        insertRendered(source)
    }

    /// On the compact keyboard Repaya is selected after its base consonant.
    /// Reorder that pair into the logical SLS sequence so it renders as one
    /// joined cluster (`ර්‍ක`), instead of appending a visible standalone
    /// `ර්‍` after the consonant.
    private func insertRepaya() {
        flushPendingComposition()
        guard let previousSource = visibleSources.last,
              let previousRendered = visibleEntries.last,
              SinhalaEngine.isSinhalaConsonant(previousRendered) else {
            insertRendered("\u{E002}")
            return
        }

        deleteDocumentText(previousRendered)
        visibleEntries.removeLast()
        visibleSources.removeLast()
        if rawBuffer.hasSuffix(previousSource) {
            rawBuffer.removeLast(previousSource.count)
        }
        insertRendered("\u{E002}" + previousSource)
    }

    private func updatePhoneticComposition() {
        let rendered = SinhalaEngine.transliterate(phoneticBuffer, mode: mode)

        // Keep the preview unmarked (no underline). Growing renderings only
        // insert a delta. Rewrites delete until the remaining live glyphs are
        // a prefix of the new text, then insert the rest — so a later vowel
        // does not erase the whole word back to `phoneticCompositionAnchor`.
        if lastPhoneticRendered.isEmpty {
            let spacing = smartSpacingAdjustment(for: rendered)
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            phoneticCompositionAnchor = spacing.deletePrecedingCount > 0
                ? String(before.dropLast(spacing.deletePrecedingCount))
                : before
            insertIntoDocument(spacing)
        } else {
            applyUnmarkedCompositionChange(from: lastPhoneticRendered, to: rendered)
        }

        lastPhoneticRendered = rendered
        commitStablePhoneticPrefixIfNeeded()
        schedulePredictions(for: activeRenderedWord())
    }

    private func commitPhoneticComposition(suffix: String = "") {
        guard !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty else { return }
        insertIntoDocument(suffix, applyingSmartSpacing: !suffix.isEmpty)
        phoneticBuffer = ""
        lastPhoneticRendered = ""
        phoneticCompositionAnchor = nil
        committedPhoneticSegments.removeAll()
        inheritedPredictionPrefix = ""
        updatePredictions(for: "")
    }

    private func clearPhoneticComposition(refreshingPredictions: Bool = true) {
        let rendered = committedPhoneticSegments.map(\.rendered).joined() + lastPhoneticRendered
        let anchor = committedPhoneticSegments.isEmpty ? phoneticCompositionAnchor : nil
        deleteDocumentText(rendered, stoppingAt: anchor)
        phoneticBuffer = ""
        lastPhoneticRendered = ""
        phoneticCompositionAnchor = nil
        committedPhoneticSegments.removeAll()
        if refreshingPredictions {
            updatePredictions(for: "")
        }
    }

    /// Leave already-written glyphs in the host and keep only a short live
    /// Latin window. Splitting is skipped when prefix and suffix would not
    /// independently transliterate to the same visible text.
    private func commitStablePhoneticPrefixIfNeeded() {
        guard let split = PhoneticLiveWindow.prefixCommitIfNeeded(
            source: phoneticBuffer,
            anchor: phoneticCompositionAnchor,
            mode: mode,
            maximumLiveSourceLength: maximumLivePhoneticSourceLength
        ) else { return }

        committedPhoneticSegments.append((source: split.committedSource, rendered: split.committedRendered))
        phoneticBuffer = split.liveSource
        lastPhoneticRendered = split.liveRendered
        phoneticCompositionAnchor = split.liveAnchor
    }

    /// A backspace can cross a committed phonetic chunk. Re-open just that
    /// final chunk so the deletion retains the same transliteration behavior
    /// as it had while that chunk was the live unmarked window.
    private func restorePreviousPhoneticSegmentAfterDelete() {
        removeActivePhoneticRendering()
        lastPhoneticRendered = ""
        phoneticCompositionAnchor = nil
        
        guard var segment = committedPhoneticSegments.popLast() else {
            updatePredictions(for: "")
            return
        }
        deleteDocumentText(segment.rendered)
        segment.source.removeLast()
        phoneticBuffer = segment.source
        if phoneticBuffer.isEmpty {
            updatePredictions(for: committedPhoneticSegments.map(\.rendered).joined())
        } else {
            updatePhoneticComposition()
        }
    }

    private func removeActivePhoneticRendering() {
        guard !lastPhoneticRendered.isEmpty else { return }
        deleteDocumentText(lastPhoneticRendered, stoppingAt: phoneticCompositionAnchor)
    }

    private func commitActiveComposition() {
        if !phoneticBuffer.isEmpty || !committedPhoneticSegments.isEmpty {
            commitPhoneticComposition()
        }
        flushPendingComposition()
    }

    private func activeRenderedWord() -> String {
        if language == .english { return englishOwnedWord }
        if mode != .sls {
            return committedPhoneticSegments.map(\.rendered).joined() + lastPhoneticRendered
        }
        return visibleEntries.joined()
    }

    /// The word used for completion and replacement. `activeRenderedWord()`
    /// remains local-only because transliteration rewrite and Backspace must
    /// never delete text that the extension did not create.
    private func activePredictionWord() -> String {
        inheritedPredictionPrefix + activeRenderedWord()
    }

    /// Capture only at the start of a local composing session. Reading the
    /// proxy on every letter is expensive, and after the first local insertion
    /// it would include the text we have already tracked.
    private func captureInheritedPredictionPrefixIfNeeded() {
        guard inheritedPredictionPrefix.isEmpty, isIdleComposition else { return }
        inheritedPredictionPrefix = NativeBackspace.wordPrefixBeforeCaret(
            in: textDocumentProxy.documentContextBeforeInput ?? ""
        )
    }

    private func learnActiveWord() {
        if language == .english { return }
        let word = activeRenderedWord()
        guard !word.isEmpty else { return }
        let preceding = predictionContext(for: word).last
        recordCommittedPredictionWord(word, after: preceding)
    }

    private func smartTypography(for suffix: String) -> String {
        guard KeyboardPreferences.hotPath.smartQuotesEnabled, (suffix == "'" || suffix == "\"") else { return suffix }
        let previous = textDocumentProxy.documentContextBeforeInput?.last
        let opensQuote = previous == nil || previous?.isWhitespace == true || previous?.isPunctuation == true
        switch suffix {
        case "'": return opensQuote ? "‘" : "’"
        case "\"": return opensQuote ? "“" : "”"
        default: return suffix
        }
    }

    private func beginPendingComposition(_ source: String, kind: PendingCompositionKind) {
        pendingSource = source
        pendingKind = kind
        pendingHostRendered = nil
        pendingHostAnchor = nil
        pendingAnchorKey = lastLetterKey
        writePendingClusterToDocument(SinhalaEngine.transliterate(source, mode: mode), source: source)
        refreshPendingCompositionChrome()
        schedulePredictions(for: visibleEntries.joined())
    }

    private func updatePendingComposition(_ source: String, kind: PendingCompositionKind) {
        let rendered = SinhalaEngine.transliterate(source, mode: mode)
        let previousSource = pendingSource
        pendingSource = source
        pendingKind = kind
        if pendingHostRendered == nil {
            writePendingClusterToDocument(rendered, source: source)
        } else if pendingHostRendered != rendered {
            rewritePendingCluster(to: rendered, source: source, previousSource: previousSource)
        }
        refreshPendingCompositionChrome()
        schedulePredictions(for: visibleEntries.joined())
    }

    private func writePendingClusterToDocument(_ rendered: String, source: String) {
        let spacing = smartSpacingAdjustment(for: rendered)
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        pendingHostAnchor = spacing.deletePrecedingCount > 0
            ? String(before.dropLast(spacing.deletePrecedingCount))
            : before
        insertIntoDocument(spacing)
        pendingHostRendered = rendered
        rawBuffer += source
        visibleEntries.append(rendered)
        visibleSources.append(source)
    }

    private func rewritePendingCluster(to rendered: String, source: String, previousSource: String?) {
        applyUnmarkedCompositionChange(from: pendingHostRendered ?? "", to: rendered)
        pendingHostRendered = rendered
        if let previousSource, rawBuffer.hasSuffix(previousSource) {
            rawBuffer.removeLast(previousSource.count)
        }
        rawBuffer += source
        if !visibleEntries.isEmpty {
            visibleEntries[visibleEntries.count - 1] = rendered
            visibleSources[visibleSources.count - 1] = source
        } else {
            visibleEntries.append(rendered)
            visibleSources.append(source)
        }
    }

    /// Ends local composition state. A lone kombuwa is already visible in
    /// the host, so this does not wait for a consonant.
    private func flushPendingComposition() {
        guard let source = pendingSource else { return }
        if pendingHostRendered == nil {
            insertRendered(source)
        }
        abandonPendingComposition(removingFromDocument: false)
    }

    private func discardPendingFromDocument() {
        if pendingHostRendered != nil {
            popPendingVisibleEntry()
            removePendingHostRendering()
        }
        abandonPendingComposition(removingFromDocument: false)
    }

    private func deletePendingCompositionOnce() {
        guard var source = pendingSource, let kind = pendingKind else { return }
        source.removeLast()
        if source.isEmpty {
            discardPendingFromDocument()
            updatePredictions(for: visibleEntries.joined())
            return
        }
        updatePendingComposition(source, kind: kind)
    }

    private func popPendingVisibleEntry() {
        guard let source = pendingSource else { return }
        if visibleSources.last == source {
            visibleEntries.removeLast()
            visibleSources.removeLast()
        }
        if rawBuffer.hasSuffix(source) {
            rawBuffer.removeLast(source.count)
        }
    }

    private func removePendingHostRendering() {
        guard let rendered = pendingHostRendered, !rendered.isEmpty else { return }
        deleteDocumentText(rendered, stoppingAt: pendingHostAnchor)
        pendingHostRendered = nil
    }

    private func abandonPendingComposition(removingFromDocument: Bool) {
        if removingFromDocument {
            discardPendingFromDocument()
            return
        }
        pendingSource = nil
        pendingKind = nil
        pendingHostRendered = nil
        pendingHostAnchor = nil
        pendingAnchorKey = nil
        hidePendingCompositionChrome()
    }

    private func insertRendered(_ source: String) {
        let rendered = SinhalaEngine.transliterate(source, mode: mode)
        rawBuffer += source
        visibleEntries.append(rendered)
        visibleSources.append(source)
        insertIntoDocument(rendered, applyingSmartSpacing: true)
        schedulePredictions(for: visibleEntries.joined())
    }

    private func noteInput() {
        lastInputTimestamp = CACurrentMediaTime()
        hasEnteredTextThisAppearance = true
    }

    /// Own proxy mutations notify `textDidChange` in some hosts. Suppress
    /// reconcile until the current run-loop turn (and a brief follow-up)
    /// has passed, so typing does not pay for `documentContextBeforeInput`.
    private func performDocumentEdit(_ body: () -> Void) {
        ownEditDepth += 1
        isApplyingOwnEdit = true
        ownEditGeneration += 1
        let generation = ownEditGeneration
        ownEditClearWork?.cancel()
        body()
        ownEditDepth -= 1
        guard ownEditDepth == 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ownEditGeneration == generation, self.ownEditDepth == 0 else { return }
            self.isApplyingOwnEdit = false
            self.ownEditClearWork = nil
        }
        ownEditClearWork = work
        DispatchQueue.main.async(execute: work)
    }

    private var smartPunctuationFieldKind: SmartPunctuationSpacing.FieldKind {
        switch textDocumentProxy.keyboardType {
        case .URL, .emailAddress, .webSearch, .decimalPad, .numberPad, .phonePad, .asciiCapableNumberPad:
            return .suppressesSentenceSpacing
        default:
            return .standard
        }
    }

    private func smartSpacingAdjustment(for text: String) -> SmartPunctuationSpacing.Adjustment {
        guard KeyboardPreferences.hotPath.smartPunctuationSpacingEnabled,
              !text.isEmpty, text != " ", !text.hasPrefix("\n") else {
            return .unchanged(text)
        }
        if collapseSpaceAfterOpeningPunctuation,
           SmartPunctuationSpacing.shouldCollapseSpaceAfterOpening(inserting: text) {
            collapseSpaceAfterOpeningPunctuation = false
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            if SmartPunctuationSpacing.canCollapseOpeningSpace(before: before) {
                return SmartPunctuationSpacing.Adjustment(deletePrecedingCount: 1, text: text)
            }
            return .unchanged(text)
        }
        guard SmartPunctuationSpacing.needsContextRead(inserting: text) else {
            return .unchanged(text)
        }
        return SmartPunctuationSpacing.adjustment(
            inserting: text,
            before: textDocumentProxy.documentContextBeforeInput ?? "",
            field: smartPunctuationFieldKind
        )
    }

    private func insertIntoDocument(_ text: String, applyingSmartSpacing: Bool = false) {
        insertIntoDocument(applyingSmartSpacing ? smartSpacingAdjustment(for: text) : .unchanged(text))
    }

    private func insertIntoDocument(_ change: SmartPunctuationSpacing.Adjustment) {
        guard change.deletePrecedingCount > 0 || !change.text.isEmpty else { return }
        performDocumentEdit {
            for _ in 0..<change.deletePrecedingCount {
                self.textDocumentProxy.deleteBackward()
            }
            if !change.text.isEmpty {
                self.textDocumentProxy.insertText(change.text)
            }
        }
    }

    private func deleteBackwardFromDocument(times: Int) {
        guard times > 0 else { return }
        performDocumentEdit {
            for _ in 0..<times { self.textDocumentProxy.deleteBackward() }
        }
    }

    /// Unmarked phonetic / pending-cluster rewrite. Growing text is insert-only
    /// so typing does not poll the host. Rewrites stay in one edit window.
    private func applyUnmarkedCompositionChange(from old: String, to new: String) {
        switch UnmarkedCompositionRewrite.plan(from: old, to: new) {
        case .none:
            return
        case .insertOnly(let text):
            guard !text.isEmpty else { return }
            insertIntoDocument(text)
        case .reconcile(let old, let new, let maximumDeletes):
            performDocumentEdit {
                UnmarkedCompositionRewrite.reconcile(
                    old: old,
                    new: new,
                    maximumDeletes: maximumDeletes,
                    context: { self.textDocumentProxy.documentContextBeforeInput },
                    deleteBackward: { self.textDocumentProxy.deleteBackward() },
                    insert: { text in
                        if !text.isEmpty {
                            self.textDocumentProxy.insertText(text)
                        }
                    }
                )
            }
        }
    }

    /// Remove `text` immediately before the caret. Hosts disagree on whether
    /// Sinhala clusters are one `deleteBackward()` or many, so stop as soon
    /// as the expected prefix is restored (or the suffix is already gone).
    private func deleteDocumentText(_ text: String, stoppingAt expected: String? = nil) {
        guard !text.isEmpty else { return }
        performDocumentEdit {
            self.deleteDocumentTextWhileEditing(text, stoppingAt: expected)
        }
    }

    private func deleteDocumentTextWhileEditing(_ text: String, stoppingAt expected: String? = nil) {
        // Repeat must not poll `documentContextBeforeInput` on every
        // scalar. Each read is a host round-trip, and a burst of them
        // stalls `UIKeyboardTaskQueue` on device — after which
        // `deleteBackward` is ignored until the next press.
        if isDeleteRepeatActive, expected == nil {
            let count = min(max(text.count, 1), 24)
            for _ in 0..<count {
                textDocumentProxy.deleteBackward()
            }
            return
        }
        let expected = expected
            ?? textDocumentProxy.documentContextBeforeInput.flatMap {
                NativeBackspace.removingSuffix($0, suffix: text)
            }
        let maximumDeletes = text.unicodeScalars.count
        var current = textDocumentProxy.documentContextBeforeInput
        for _ in 0..<maximumDeletes {
            if let expected, current == expected { return }
            textDocumentProxy.deleteBackward()
            let after = textDocumentProxy.documentContextBeforeInput
            if let expected, after == expected { return }
            if expected == nil, let after, !NativeBackspace.endsWith(after, suffix: text) {
                return
            }
            current = after
        }
    }

    private func keyButton(named name: String) -> NativeKeyButton? {
        for case let row as UIStackView in keyboardStack.arrangedSubviews {
            for case let button as NativeKeyButton in row.arrangedSubviews where button.keyName == name {
                return button
            }
        }
        return nil
    }

    private func refreshPendingCompositionChrome() {
        keyboardStack.arrangedSubviews.forEach { row in
            row.subviews.compactMap { $0 as? NativeKeyButton }.forEach {
                $0.setCompositionPending($0.keyName == pendingAnchorKey && pendingHostRendered == nil)
            }
        }
        guard let source = pendingSource, pendingHostRendered == nil else {
            hidePendingCompositionChip()
            return
        }
        let rendered = SinhalaEngine.transliterate(source, mode: mode)
        guard let key = pendingAnchorKey, let button = keyButton(named: key), !button.isHighlighted else {
            hidePendingCompositionChip()
            return
        }
        showPendingCompositionChip(rendered, over: button)
    }

    private func hidePendingCompositionChrome() {
        keyboardStack.arrangedSubviews.forEach { row in
            row.subviews.compactMap { $0 as? NativeKeyButton }.forEach {
                $0.setCompositionPending(false)
            }
        }
        hidePendingCompositionChip()
    }

    private func showPendingCompositionChip(_ text: String, over button: NativeKeyButton) {
        let chip = pendingCompositionChip ?? PendingCompositionChip()
        if chip.superview == nil {
            view.addSubview(chip)
            pendingCompositionChip = chip
        }
        chip.display(text)
        let keyFrame = button.convert(button.bounds, to: view)
        let size = CGSize(width: max(36, keyFrame.width + 8), height: 34)
        chip.frame = CGRect(
            x: min(max(keyFrame.midX - size.width / 2, view.bounds.minX + 2), view.bounds.maxX - size.width - 2),
            y: max(0, keyFrame.minY - size.height - 4),
            width: size.width,
            height: size.height
        )
        view.bringSubviewToFront(chip)
    }

    private func hidePendingCompositionChip() {
        pendingCompositionChip?.removeFromSuperview()
        pendingCompositionChip = nil
    }

    /// Matches the standard iOS double-space shortcut: the second tap turns
    /// the prior space into a period followed by one ready for the next word.
    private func insertSpace() {
        if temporaryLatinWordActive {
            endTemporaryLatinWordMode()
        }
        let now = CACurrentMediaTime()
        let wasIdle = isIdleComposition
        // The second tap follows the first committed space. Only replace that
        // space when it follows a word; never manufacture punctuation at the
        // start of a field or after an existing sentence terminator.
        let beforeInput = textDocumentProxy.documentContextBeforeInput ?? ""
        let characterBeforeSpace = beforeInput.dropLast().last
        let followsWord = characterBeforeSpace.map { $0.isLetter || $0.isNumber } ?? false
        let isDoubleSpace = KeyboardPreferences.hotPath.doubleSpacePeriodEnabled
            && rawBuffer.isEmpty && followsWord
            && (lastSpaceTimestamp.map { now - $0 < 0.45 } ?? false)
        if isDoubleSpace {
            performDocumentEdit {
                self.textDocumentProxy.deleteBackward()
                self.textDocumentProxy.insertText(". ")
            }
            lastSpaceTimestamp = nil
            collapseSpaceAfterOpeningPunctuation = false
            invalidatePrecedingWordsCache()
            noteIdleSpaceSignatureTap(wasIdle: wasIdle, at: now)
            return
        }

        let followsOpening = beforeInput.last.map(SmartPunctuationSpacing.isOpening) ?? false
        commit(suffix: " ")
        collapseSpaceAfterOpeningPunctuation =
            KeyboardPreferences.hotPath.smartPunctuationSpacingEnabled && followsOpening
        noteIdleSpaceSignatureTap(wasIdle: wasIdle, at: now)
        lastSpaceTimestamp = now
        invalidatePrecedingWordsCache()
    }

    private var isIdleComposition: Bool {
        if language == .english { return englishOwnedWord.isEmpty }
        return phoneticBuffer.isEmpty && committedPhoneticSegments.isEmpty && pendingSource == nil && visibleEntries.isEmpty
    }

    private var activePhoneticSource: String {
        committedPhoneticSegments.map(\.source).joined() + phoneticBuffer
    }

    /// Seven idle Space taps, no slower than a second apart, wink the caption.
    /// Each tap still inserts normally, so a run of spaces is never eaten.
    private func noteIdleSpaceSignatureTap(wasIdle: Bool, at now: TimeInterval) {
        guard !temporaryLatinWordActive else {
            resetSpaceSignatureTaps()
            return
        }
        guard wasIdle else {
            resetSpaceSignatureTaps()
            return
        }
        if now - spaceSignatureTapTimestamp > 1.05 {
            spaceSignatureTapCount = 0
        }
        spaceSignatureTapTimestamp = now
        spaceSignatureTapCount += 1
        guard spaceSignatureTapCount >= 7 else { return }
        revealSpacebarSignature()
        resetSpaceSignatureTaps()
    }

    private func resetSpaceSignatureTaps() {
        spaceSignatureTapCount = 0
        spaceSignatureTapTimestamp = 0
    }

    private func spaceKeyButton() -> NativeKeyButton? {
        keyButton(named: "space")
    }

    private func revealSpacebarSignature() {
        guard let button = spaceKeyButton(), !isSpaceTrackpadActive else { return }
        spaceSignatureRestoreWork?.cancel()
        button.presentSpaceSignature(AksharaEasterEgg.spacebarPhrase)
        keyFeedback?.signatureWink()
        let work = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button else { return }
            button.restoreCollapsedSpaceTitle(self.title(for: "space") ?? "අක්ෂර")
            self.spaceSignatureRestoreWork = nil
        }
        spaceSignatureRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: work)
    }

    private func beginTemporaryLatinWordMode() {
        commitActiveComposition()
        temporaryLatinWordActive = true
        // Clear any leftover Space suppress flag from the enter swipe.
        _ = spaceKeyButton()?.consumeLongPressHandled()
        updatePredictions(for: "")
        refreshLetterHints(animated: true)
        guard let button = spaceKeyButton() else { return }
        spaceSignatureRestoreWork?.cancel()
        button.presentSpaceSignature(Self.oneWordEnglishSpaceTitle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak button] in
            guard let self, let button, self.temporaryLatinWordActive else { return }
            button.restoreCollapsedSpaceTitle(Self.oneWordEnglishSpaceTitle)
        }
    }

    private func endTemporaryLatinWordMode() {
        guard temporaryLatinWordActive else { return }
        temporaryLatinWordActive = false
        _ = spaceKeyButton()?.consumeLongPressHandled()
        refreshLetterHints(animated: true)
        spaceKeyButton()?.restoreCollapsedSpaceTitle(title(for: "space") ?? "අක්ෂර")
    }

    private func refreshLetterHints(animated: Bool) {
        guard layer == .letters else { return }
        for case let row as UIStackView in keyboardStack.arrangedSubviews {
            for case let button as NativeKeyButton in row.arrangedSubviews {
                let key = button.keyName
                guard key.count == 1 || key == "rakaranshaya" || key == "yansaya" || key == "kundaliya" else {
                    continue
                }
                button.setHint(hint(for: key), animated: animated)
            }
        }
    }

}
