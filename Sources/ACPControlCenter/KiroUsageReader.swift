import Foundation

/// Reads Kiro account usage/credit information from `q-client.log` files.
///
/// Log line shape (real-world verified):
/// ```
/// 2026-07-26 04:39:12.731 [info] {"clientName":"CodeWhispererRuntimeClient","commandName":"GetUsageLimitsCommand",...}
/// ```
///
/// The reader streams files in bounded chunks and decodes only lines that
/// look relevant. File work runs away from MainActor so scanning historical
/// logs does not freeze the menu UI.
struct KiroUsageReader: Sendable {
    /// Default logs root: `~/Library/Application Support/Kiro/logs`.
    static func defaultLogsRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Kiro")
            .appendingPathComponent("logs")
    }

    private let logsRoot: URL

    init(logsRoot: URL? = nil) {
        self.logsRoot = logsRoot ?? Self.defaultLogsRoot()
    }

    /// Locates every `q-client.log` file anywhere under the logs root.
    func discoverLogFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: logsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var matches: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "q-client.log" else { continue }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            matches.append((fileURL, modified))
        }
        // Newest candidate files first. Selection still compares record
        // timestamps across every file, so file mtime is never treated as
        // the source of truth.
        return matches.sorted { $0.modified > $1.modified }.map(\.url)
    }

    /// Returns the newest valid usage observation across all discovered log
    /// files, selected by parsed record timestamp (not filename or mtime).
    func readLatestUsage() -> Result<KiroAccountUsage, ReaderError> {
        let files = discoverLogFiles()
        guard !files.isEmpty else {
            return .failure(.missing(reason: "No q-client.log files found under \(logsRoot.path)"))
        }

        var newest: KiroAccountUsage?
        var sawAnyCandidateLine = false
        var sawAnyDecodeSuccess = false
        var sawReadableFile = false

        for file in files {
            do {
                try UTF8LineScanner.scan(file) { line in
                    sawReadableFile = true
                    guard line.contains("GetUsageLimitsCommand") else { return }
                    sawAnyCandidateLine = true
                    guard let usage = parseUsageLine(line, sourceURL: file) else { return }
                    sawAnyDecodeSuccess = true
                    if newest == nil || usage.observedAt > newest!.observedAt {
                        newest = usage
                    }
                }
            } catch {
                continue
            }
        }

        if let newest {
            return .success(newest)
        }
        if sawAnyCandidateLine && !sawAnyDecodeSuccess {
            return .failure(.invalid(reason: "Found GetUsageLimitsCommand records but all failed to decode or lacked a CREDIT resource"))
        }
        if !sawReadableFile {
            return .failure(.ioFailure(reason: "q-client.log files were found but none could be read"))
        }
        return .failure(.missing(reason: "No GetUsageLimitsCommand records found"))
    }

    // MARK: - Line parsing

    /// Splits the log-prefix (timestamp + level) from the trailing JSON
    /// payload, decodes it, and maps it to `KiroAccountUsage`. Returns `nil`
    /// on any decode failure so the caller can fall back to older lines.
    private func parseUsageLine(_ line: String, sourceURL: URL) -> KiroAccountUsage? {
        guard let jsonStartIndex = line.firstIndex(of: "{") else { return nil }
        let jsonSubstring = line[jsonStartIndex...]
        guard let jsonData = String(jsonSubstring).data(using: .utf8) else { return nil }

        guard let record = try? JSONDecoder().decode(UsageLogRecord.self, from: jsonData) else {
            return nil
        }
        guard record.commandName == "GetUsageLimitsCommand" else { return nil }
        guard let output = record.output else { return nil }
        guard let creditItem = output.usageBreakdownList?.first(where: { $0.resourceType == "CREDIT" }) else {
            return nil
        }

        guard let used = creditItem.currentUsageWithPrecision ?? creditItem.currentUsage else {
            return nil
        }
        guard let limit = creditItem.usageLimitWithPrecision ?? creditItem.usageLimit else {
            return nil
        }
        let overages = creditItem.currentOveragesWithPrecision ?? creditItem.currentOverages

        guard let observedAt = Self.parseLogPrefixTimestamp(from: line) else { return nil }

        let resetDate = output.nextDateReset.flatMap(Self.parseISO8601)
            ?? creditItem.nextDateReset.flatMap(Self.parseISO8601)

        return KiroAccountUsage(
            used: used,
            limit: limit,
            currentOverages: overages,
            resetDate: resetDate,
            subscriptionTitle: output.subscriptionInfo?.subscriptionTitle,
            overageStatus: output.overageConfiguration?.overageStatus,
            observedAt: observedAt,
            sourceURL: sourceURL
        )
    }

    /// Parses a prefix like `2026-07-26 04:39:12.731 [info] ` into a `Date`.
    static func parseLogPrefixTimestamp(from line: String) -> Date? {
        guard let jsonStart = line.firstIndex(of: "{") else { return nil }
        let prefix = line[line.startIndex..<jsonStart].trimmingCharacters(in: .whitespaces)
        // Expect "yyyy-MM-dd HH:mm:ss.SSS [level]"
        guard let bracketIndex = prefix.firstIndex(of: "[") else { return nil }
        let timestampPart = prefix[prefix.startIndex..<bracketIndex].trimmingCharacters(in: .whitespaces)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: timestampPart)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Decoding DTOs

/// Tolerant decode target for the current usage log schema. All fields are
/// optional so that partial/older/newer schema variants degrade gracefully
/// instead of throwing.
private struct UsageLogRecord: Decodable {
    let commandName: String?
    let output: UsageOutput?
}

private struct UsageOutput: Decodable {
    let nextDateReset: String?
    let usageBreakdownList: [UsageBreakdownItem]?
    let subscriptionInfo: SubscriptionInfo?
    let overageConfiguration: OverageConfiguration?
}

private struct UsageBreakdownItem: Decodable {
    let resourceType: String?
    let currentUsage: Decimal?
    let currentUsageWithPrecision: Decimal?
    let currentOverages: Decimal?
    let currentOveragesWithPrecision: Decimal?
    let usageLimit: Decimal?
    let usageLimitWithPrecision: Decimal?
    let nextDateReset: String?
}

private struct SubscriptionInfo: Decodable {
    let subscriptionTitle: String?
}

private struct OverageConfiguration: Decodable {
    let overageStatus: String?
}
