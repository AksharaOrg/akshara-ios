import Foundation
import MetricKit
import OSLog

/// Collects Apple's privacy-preserving production diagnostics locally. The
/// payloads contain stacks and device/app metadata, never keyboard input.
final class CrashReportManager: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReportManager()

    private let queue = DispatchQueue(label: "lk.org.akshara.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "lk.org.akshara.keyboard", category: "Diagnostics")
    private var started = false
    private let maximumStoredReports = 24

    private override init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, kind: "diagnostic")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, kind: "metric")
    }

    var storedReportCount: Int {
        queue.sync { reportURLs().count }
    }

    /// Produces one JSON file that can be attached to an issue or email.
    /// Invalid/partial files are skipped instead of making all reports
    /// impossible to export.
    func makeExportFile() -> URL? {
        queue.sync {
            let reports = reportURLs().compactMap { url -> Any? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            }
            guard !reports.isEmpty else { return nil }
            let appInfo = Bundle.main.infoDictionary
            let envelope: [String: Any] = [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "appVersion": appInfo?["CFBundleShortVersionString"] as? String ?? "unknown",
                "appBuild": appInfo?["CFBundleVersion"] as? String ?? "unknown",
                "reports": reports
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]) else {
                return nil
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Akshara-Diagnostics.json")
            do {
                try data.write(to: destination, options: .atomic)
                return destination
            } catch {
                logger.error("Unable to export diagnostics: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    func deleteStoredReports() {
        queue.sync {
            reportURLs().forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func persist(_ payloads: [Data], kind: String) {
        guard !payloads.isEmpty else { return }
        queue.async { [self] in
            guard let directory = diagnosticsDirectory(create: true) else { return }
            let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
            for (index, payload) in payloads.enumerated() {
                let name = "\(timestamp)-\(kind)-\(index)-\(UUID().uuidString).json"
                do {
                    try payload.write(to: directory.appendingPathComponent(name), options: .atomic)
                } catch {
                    logger.error("Unable to store diagnostics: \(error.localizedDescription, privacy: .public)")
                }
            }
            trimStoredReports()
        }
    }

    private func diagnosticsDirectory(create: Bool) -> URL? {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let directory = base?.appendingPathComponent("Diagnostics", isDirectory: true) else { return nil }
        if create {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func reportURLs() -> [URL] {
        guard let directory = diagnosticsDirectory(create: false),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }

    private func trimStoredReports() {
        let stale = reportURLs().dropFirst(maximumStoredReports)
        stale.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
