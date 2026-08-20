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
}
