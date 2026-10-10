import Foundation
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
    static func begin(_ name: StaticString) -> Interval? {
        guard enabled else { return nil }
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }
    static func end(_ interval: Interval?) {
        guard let interval else { return }
        signposter.endInterval(interval.name, interval.state)
    }
#else
    struct Interval {}
    static func begin(_ name: StaticString) -> Interval? { nil }
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
    private var pending: (() -> Void)?
    private var running = false

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func submit(_ job: @escaping () -> Void) {
        lock.lock()
        pending = job
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func cancelPending() {
        lock.lock(); pending = nil; lock.unlock()
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
            job()
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

/// Hash-paired sidecar reader. Truncated, stale, and unsupported files fall back
/// to rebuilding from the source. Integer reads are alignment independent.
struct PredictionIndexReader {
    private let data: Data
    private(set) var offset: Int

    init?(url: URL?, magic: String, source: Data) {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let header = Array(magic.utf8)
        guard data.count >= header.count + 32,
              data.prefix(header.count).elementsEqual(header),
              data[header.count..<(header.count + 32)].elementsEqual(SHA256.hash(data: source)) else { return nil }
        self.data = data; offset = header.count + 32
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
