import Foundation

/// Host and input-session events that must drop local IME state.
///
/// Smart Phonetic keeps an unmarked preview plus a Latin buffer. If that
/// buffer outlives the field it was typed in, the next keystroke rewrites
/// the previous word into the new editor. These events cancel locally and
/// never insert the leftover rendering.
enum CompositionHygieneEvent: String, CaseIterable, Equatable {
    case documentIdentifierChanged
    case returnOrSend
    case keyboardWillDisappear
    case inputModeChanged
    case documentContextChangedUnexpectedly
}

enum CompositionHygiene {
    /// Leftover composition is never written into a different field or a
    /// freshly submitted message. The glyphs already in the old editor stay.
    static func shouldCommitLeftoverBuffer(for event: CompositionHygieneEvent) -> Bool {
        false
    }

    static func shouldCancelWithoutCommit(for event: CompositionHygieneEvent) -> Bool {
        true
    }

    /// First observation only records identity. A later UUID change is a new
    /// document even when `documentContextBeforeInput` is nil.
    static func documentIdentifierChanged(previous: UUID?, current: UUID) -> Bool {
        guard let previous else { return false }
        return previous != current
    }

    /// Nil context is inconclusive in restricted keyboards. With Full Access,
    /// it is a real boundary: the host should provide context for a normal
    /// message field, so a missing window means the draft was sent or the
    /// editor changed.
    static func documentContextInvalidatedComposition(
        renderedWord: String,
        documentContextBeforeInput: String?,
        contextIsExpected: Bool = false
    ) -> Bool {
        guard !renderedWord.isEmpty else { return false }
        guard let before = documentContextBeforeInput else { return contextIsExpected }
        return !NativeBackspace.endsWith(before, suffix: renderedWord)
    }
}

/// Local composition buffers owned by the keyboard extension. Host text is
/// not stored here; cancelling must not produce a document insert.
struct KeyboardCompositionSession {
    enum PendingKind: Equatable {
        case prebase
        case independentVowel
    }

    struct PhoneticSegment: Equatable {
        var source: String
        var rendered: String
    }

    var rawBuffer = ""
    var phoneticBuffer = ""
    var lastPhoneticRendered = ""
    var phoneticCompositionAnchor: String?
    var committedPhoneticSegments: [PhoneticSegment] = []
    var visibleEntries: [String] = []
    var visibleSources: [String] = []
    var pendingSource: String?
    var pendingKind: PendingKind?
    var pendingHostRendered: String?
    var pendingHostAnchor: String?
    var pendingAnchorKey: String?
    var predictionPrefix = ""
    private(set) var predictionGeneration = 0
    private(set) var droppedPredictionDebounceCount = 0

    var hasLocalComposition: Bool {
        !phoneticBuffer.isEmpty
            || !committedPhoneticSegments.isEmpty
            || pendingSource != nil
            || !visibleEntries.isEmpty
            || !rawBuffer.isEmpty
            || !lastPhoneticRendered.isEmpty
            || phoneticCompositionAnchor != nil
            || !predictionPrefix.isEmpty
    }

    /// Drop every local buffer. Callers must not insert `lastPhoneticRendered`
    /// or `phoneticBuffer` as a result of this reset.
    mutating func cancelWithoutCommit() {
        rawBuffer = ""
        visibleEntries.removeAll()
        visibleSources.removeAll()
        phoneticBuffer = ""
        lastPhoneticRendered = ""
        phoneticCompositionAnchor = nil
        committedPhoneticSegments.removeAll()
        pendingSource = nil
        pendingKind = nil
        pendingHostRendered = nil
        pendingHostAnchor = nil
        pendingAnchorKey = nil
        predictionPrefix = ""
        predictionGeneration += 1
        droppedPredictionDebounceCount += 1
    }

    mutating func apply(_ event: CompositionHygieneEvent) {
        if CompositionHygiene.shouldCancelWithoutCommit(for: event) {
            cancelWithoutCommit()
        }
    }

    /// Preview that would be written if `source` were typed in this session.
    func phoneticPreviewIfTyping(_ source: String, mode: SinhalaEngine.Mode) -> String {
        SinhalaEngine.transliterate(phoneticBuffer + source, mode: mode)
    }

    /// Leave already-written glyphs in the host and keep only a short live
    /// Latin window. The document is unchanged; the next rewrite only touches
    /// `lastPhoneticRendered`.
    @discardableResult
    mutating func commitStablePhoneticPrefixIfNeeded(
        mode: SinhalaEngine.Mode,
        maximumLiveSourceLength: Int = PhoneticLiveWindow.defaultMaximumSourceLength
    ) -> Bool {
        guard let split = PhoneticLiveWindow.prefixCommitIfNeeded(
            source: phoneticBuffer,
            anchor: phoneticCompositionAnchor,
            mode: mode,
            maximumLiveSourceLength: maximumLiveSourceLength
        ) else { return false }
        committedPhoneticSegments.append(
            .init(source: split.committedSource, rendered: split.committedRendered)
        )
        phoneticBuffer = split.liveSource
        lastPhoneticRendered = split.liveRendered
        phoneticCompositionAnchor = split.liveAnchor
        return true
    }
}

/// Caps the unmarked phonetic rewrite window without using marked text.
enum PhoneticLiveWindow {
    static let defaultMaximumSourceLength = 8

    struct PrefixCommit: Equatable {
        var liveSource: String
        var liveRendered: String
        var liveAnchor: String?
        var committedSource: String
        var committedRendered: String
    }

    /// Split only when prefix and suffix transliterate independently to the
    /// same glyphs as the full buffer, so a later vowel cannot rewrite a
    /// committed chunk.
    static func prefixCommitIfNeeded(
        source: String,
        anchor: String?,
        mode: SinhalaEngine.Mode,
        maximumLiveSourceLength: Int = defaultMaximumSourceLength
    ) -> PrefixCommit? {
        let sourceLength = source.count
        guard sourceLength > maximumLiveSourceLength else { return nil }
        let fullRendered = SinhalaEngine.transliterate(source, mode: mode)
        let latestPrefixLength = sourceLength - maximumLiveSourceLength
        for prefixLength in stride(from: latestPrefixLength, through: 1, by: -1) {
            let split = source.index(source.startIndex, offsetBy: prefixLength)
            let prefix = String(source[..<split])
            let suffix = String(source[split...])
            let renderedPrefix = SinhalaEngine.transliterate(prefix, mode: mode)
            let renderedSuffix = SinhalaEngine.transliterate(suffix, mode: mode)
            guard renderedPrefix + renderedSuffix == fullRendered else { continue }
            let liveAnchor = anchor.map { $0 + renderedPrefix }
            return PrefixCommit(
                liveSource: suffix,
                liveRendered: renderedSuffix,
                liveAnchor: liveAnchor,
                committedSource: prefix,
                committedRendered: renderedPrefix
            )
        }
        return nil
    }
}

/// Unmarked IME rewrite: insert a delta when the rendering only grows, otherwise
/// delete until the remaining live glyphs are a prefix of the new rendering.
enum UnmarkedCompositionRewrite {
    enum Plan: Equatable {
        case none
        /// `insertText` only. No `deleteBackward` and no proxy reads.
        case insertOnly(String)
        /// Delete at most `maximumDeletes` times, observing the host after each
        /// call because Sinhala clusters may be one grapheme or many scalars.
        case reconcile(old: String, new: String, maximumDeletes: Int)
    }

    enum Step: Equatable {
        case done
        case delete
        case insert(String)
    }

    static func plan(from old: String, to new: String) -> Plan {
        if old == new { return .none }
        if old.isEmpty { return .insertOnly(new) }
        if SinhalaEngine.hasUnicodeScalarPrefix(new, old) {
            return .insertOnly(unicodeScalarSuffix(new, afterPrefix: old))
        }
        return .reconcile(old: old, new: new, maximumDeletes: max(old.unicodeScalars.count, 1))
    }

    /// Decide the next host mutation from the current pre-caret text.
    /// `old` is the live unmarked rendering, not the whole committed word.
    static func nextStep(currentBeforeInput: String?, old: String, new: String) -> Step {
        guard let current = currentBeforeInput else { return .delete }
        let remaining = longestScalarPrefix(of: old, thatIsSuffixOf: current)
        if remaining == old {
            if SinhalaEngine.hasUnicodeScalarPrefix(new, old) {
                let delta = unicodeScalarSuffix(new, afterPrefix: old)
                return delta.isEmpty ? .done : .insert(delta)
            }
            return old == new ? .done : .delete
        }
        if SinhalaEngine.hasUnicodeScalarPrefix(new, remaining) {
            let delta = unicodeScalarSuffix(new, afterPrefix: remaining)
            return delta.isEmpty ? .done : .insert(delta)
        }
        return .delete
    }

    static func reconcile(
        old: String,
        new: String,
        maximumDeletes: Int,
        context: () -> String?,
        deleteBackward: () -> Void,
        insert: (String) -> Void
    ) {
        func apply(_ step: Step) -> Bool {
            switch step {
            case .done:
                return true
            case .insert(let text):
                if !text.isEmpty { insert(text) }
                return true
            case .delete:
                return false
            }
        }

        for _ in 0..<maximumDeletes {
            if apply(nextStep(currentBeforeInput: context(), old: old, new: new)) {
                return
            }
            deleteBackward()
        }
        if apply(nextStep(currentBeforeInput: context(), old: old, new: new)) {
            return
        }
        if !new.isEmpty { insert(new) }
    }

    static func unicodeScalarSuffix(_ text: String, afterPrefix prefix: String) -> String {
        var iterator = text.unicodeScalars.makeIterator()
        for scalar in prefix.unicodeScalars {
            guard iterator.next() == scalar else { return text }
        }
        var remainder = String.UnicodeScalarView()
        while let scalar = iterator.next() {
            remainder.append(scalar)
        }
        return String(remainder)
    }

    static func longestScalarPrefix(of pattern: String, thatIsSuffixOf text: String) -> String {
        let patternScalars = Array(pattern.unicodeScalars)
        let textScalars = Array(text.unicodeScalars)
        var length = min(patternScalars.count, textScalars.count)
        while length > 0 {
            if textScalars.suffix(length).elementsEqual(patternScalars.prefix(length)) {
                return String(String.UnicodeScalarView(patternScalars.prefix(length)))
            }
            length -= 1
        }
        return ""
    }
}
