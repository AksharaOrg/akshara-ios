import Foundation
import CoreGraphics
import CryptoKit
#if os(iOS)
import os
#endif

/// Measurements are opt-in and contain no text, words, or touch coordinates.
enum KeyboardPerformance {
    static let enabled = ProcessInfo.processInfo.environment["AKSHARA_PERF_TRACE"] == "1"
#if os(iOS)
    private static let signposter = OSSignposter(subsystem: "lk.org.akshara.keyboard", category: "Performance")
    struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
    }
    static func begin(_ name: StaticString, mode: Int = -1, generation: Int = 0, count: Int = 0) -> Interval? {
        guard enabled else { return nil }
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID(), "mode=\(mode, privacy: .public) generation=\(generation, privacy: .public) count=\(count, privacy: .public)"))
    }
    static func end(_ interval: Interval?) {
        guard let interval else { return }
        signposter.endInterval(interval.name, interval.state)
    }
#else
    struct Interval {}
    static func begin(_ name: StaticString, mode: Int = -1, generation: Int = 0, count: Int = 0) -> Interval? { nil }
    static func end(_ interval: Interval?) {}
#endif
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try body()
    }
}

/// One active job and one replaceable pending job. No queue grows with typing.
final class LatestRequestWorker {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var pending: (job: () -> Void, wait: KeyboardPerformance.Interval?)?
    private var running = false

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func submit(generation: Int = 0, _ job: @escaping () -> Void) {
        let interval = KeyboardPerformance.begin("WorkerQueueDelay", generation: generation, count: 1)
        lock.lock()
        let replaced = pending
        pending = (job, interval)
        let start = !running
        running = true
        lock.unlock()
        KeyboardPerformance.end(replaced?.wait)
        if start { queue.async { self.drain() } }
    }

    func cancelPending() {
        lock.lock(); let removed = pending; pending = nil; lock.unlock()
        KeyboardPerformance.end(removed?.wait)
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            KeyboardPerformance.end(job.wait)
            job.job()
        }
    }
}

/// Never survives an input operation. A loaded nil is cached like other values.
/// All mutations and host callbacks must invalidate before another read.
final class DocumentContextSnapshot {
    private let readBefore: () -> String?
    private let readAfter: () -> String?
    private let readSelection: () -> String?
    private var beforeValue: String??
    private var afterValue: String??
    private var selectionValue: String??
    private(set) var generation = 0

    init(before: @escaping () -> String?, after: @escaping () -> String?, selection: @escaping () -> String?) {
        readBefore = before; readAfter = after; readSelection = selection
    }

    var before: String? {
        if let value = beforeValue { return value }
        let value = readBefore(); beforeValue = .some(value); return value
    }
    var after: String? {
        if let value = afterValue { return value }
        let value = readAfter(); afterValue = .some(value); return value
    }
    var selection: String? {
        if let value = selectionValue { return value }
        let value = readSelection(); selectionValue = .some(value); return value
    }
    func invalidate() {
        beforeValue = nil; afterValue = nil; selectionValue = nil
        generation += 1
    }
}

/// A shared callout belongs to the most recently displayed press. An older
/// key's lift or cancellation must not dismiss the newer key's feedback.
struct KeyboardPressOwner {
    private var owner: ObjectIdentifier?

    mutating func claim(_ identifier: ObjectIdentifier) { owner = identifier }
    mutating func release(_ identifier: ObjectIdentifier) -> Bool {
        guard owner == identifier else { return false }
        owner = nil
        return true
    }
    mutating func reset() { owner = nil }
}

/// Main-thread state for an action deferred until UIKit finishes touch-down.
/// Drain before accepting newer input; invalidate on host/layout changes.
/// An obsolete closure cannot consume a newer pending action.
struct DeferredKeyboardAction<Context: Equatable> {
    private var nextToken: UInt64 = 0
    private var pending: (token: UInt64, context: Context)?
    var hasPending: Bool { pending != nil }
    func contains(token: UInt64?) -> Bool {
        guard let pending else { return false }
        return token == nil || pending.token == token
    }

    mutating func enqueue(context: Context) -> UInt64 {
        nextToken &+= 1
        pending = (nextToken, context)
        return nextToken
    }
    mutating func take(token: UInt64? = nil, context: Context) -> Bool {
        guard let action = pending, token == nil || token == action.token else { return false }
        pending = nil
        return action.context == context
    }
    mutating func cancel() { pending = nil }
}

/// Selection stays stable near a slot boundary, and leaving the popup/key
/// corridor cancels rather than clamping a distant finger to an end choice.
struct AlternatePickerSelection {
    let count: Int
    private let anchorIndex: Int
    private var lastIndex: Int
    private(set) var selectedIndex: Int?

    init(count: Int, selectedIndex: Int = 0) {
        self.count = max(0, count)
        lastIndex = min(max(0, selectedIndex), max(0, count - 1))
        anchorIndex = lastIndex
        self.selectedIndex = count > 0 ? lastIndex : nil
    }

    mutating func update(at point: CGPoint, bounds: CGRect, anchor: CGRect) {
        guard count > 0, bounds.width > 8, bounds.height > 0 else {
            selectedIndex = nil
            return
        }
        let width = (bounds.width - 8) / CGFloat(count)
        // Wide accent menus must be clamped to the screen, so their base
        // slot may no longer line up with the held key. A stationary hold
        // still means the base letter; selecting an accent requires movement.
        if anchor.contains(point), !bounds.contains(point) {
            lastIndex = anchorIndex
            selectedIndex = anchorIndex
            return
        }
        let tolerance = min(18, max(12, width * 0.3))
        guard bounds.union(anchor).insetBy(dx: -tolerance, dy: -tolerance).contains(point) else {
            selectedIndex = nil
            return
        }
        let hysteresis = min(8, width * 0.15)
        let left = 4 + CGFloat(lastIndex) * width
        if selectedIndex != nil, point.x >= left - hysteresis, point.x <= left + width + hysteresis {
            return
        }
        lastIndex = min(max(Int(floor((point.x - 4) / width)), 0), count - 1)
        selectedIndex = lastIndex
    }
}

/// Hash-paired sidecar reader. Truncated, stale, and unsupported files fall back
/// to rebuilding from the source. Integer reads are alignment independent.
struct PredictionIndexReader {
    private let data: Data
    private(set) var offset: Int

    init?(url: URL?, magic: String, source: Data) {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let header = Array(magic.utf8)
        guard data.count >= header.count + 64,
              data.prefix(header.count).elementsEqual(header),
              data[header.count..<(header.count + 32)].elementsEqual(SHA256.hash(data: source)),
              data[(header.count + 32)..<(header.count + 64)].elementsEqual(SHA256.hash(data: data.suffix(from: header.count + 64))) else { return nil }
        self.data = data; offset = header.count + 64
    }

    var isAtEnd: Bool { offset == data.count }
    mutating func uint32() -> Int? {
        guard offset <= data.count - 4 else { return nil }
        defer { offset += 4 }
        return (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) }
    }
    mutating func string() -> String? {
        guard let count = uint32(), count <= data.count - offset else { return nil }
        defer { offset += count }
        return String(data: data[offset..<(offset + count)], encoding: .utf8)
    }
}

/// Immutable search data can be prepared and queried entirely off the UI thread.
struct EmojiKeywordSearchIndex {
    private let entries: [(emoji: String, terms: Set<String>)]
    private let locale: Locale

    init(index: [String: [String]], locale: Locale = .current) {
        self.locale = locale
        entries = index.map { emoji, terms in
            (emoji, Set(terms.flatMap { Self.tokens($0, locale: locale) }))
        }
    }
    private static func tokens(_ query: String, locale: Locale) -> [String] {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .lowercased(with: locale)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    func search(_ query: String, cancellation: PredictionCancellationToken? = nil) -> [String] {
        let interval = KeyboardPerformance.begin("EmojiSearch")
        defer { KeyboardPerformance.end(interval) }
        let tokens = Self.tokens(query, locale: locale)
        guard !tokens.isEmpty else { return ["😐", "😀", "😃", "😁", "😄", "😆", "🥹", "😅"] }
        var matches: [(String, Int)] = []
        for (offset, entry) in entries.enumerated() {
            if offset & 63 == 0, cancellation?.isCancelled == true { return [] }
            guard tokens.allSatisfy({ token in entry.terms.contains {
                $0.hasPrefix(token) || ($0.count >= 3 && token.hasPrefix($0))
            } }) else { continue }
            let score = tokens.reduce(0) { $0 + (entry.terms.contains($1) ? 2 : 1) }
            matches.append((entry.emoji, score))
        }
        guard cancellation?.isCancelled != true else { return [] }
        var seen = Set<String>(), result: [String] = []
        for (emoji, _) in matches.sorted(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }) {
            if seen.insert(EmojiSkinToneApplicator.skinToneFreeKey(for: emoji)).inserted { result.append(emoji) }
            if result.count == 40 { break }
        }
        return result
    }
}

/// A result is usable only in the exact composing session that requested it.
struct SinhalaCorrectionIdentity: Equatable {
    let document: UUID
    let generation: Int
    let word: String
    let mode: SinhalaEngine.Mode
    let language: KeyboardLanguage
    let protectionRevision: Int
}
struct ReadySinhalaCorrection {
    let identity: SinhalaCorrectionIdentity
    let result: SinhalaAutocorrectionService.CorrectionEvaluation
    func replacement(for current: SinhalaCorrectionIdentity) -> String? {
        identity == current ? result.replacement : nil
    }
}

struct PhoneticChoiceIdentity: Equatable {
    let document: UUID
    let generation: Int
    let source: String
    let word: String
    let configuration: SmartPhoneticConfiguration
    let protectionRevision: Int
}
