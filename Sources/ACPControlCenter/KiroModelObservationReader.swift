import Foundation

/// Reads observed model/agent-mode/origin information from structured Kiro
/// agent logs at `~/.kiro/logs/*/kiro.log`.
///
/// Each line is a standalone JSON object:
/// ```
/// {"timestamp":"2026-07-20T07:50:20.531Z","level":"info","message":"[q-developer-converse] Sending GenerateAssistantResponse modelId=claude-opus-4.6 agentMode=vibe origin=AI_EDITOR ..."}
/// ```
///
/// Attribution is derived from the directory's `Stored clientInfo.name`
/// line, per spec. `origin=AI_EDITOR` is surfaced as `.aiEditor`, never
/// claimed to be Xcode ACP specifically, matching the plan's caution about
/// insufficient evidence.
struct KiroModelObservationReader: Sendable {
    /// Default logs root: `~/.kiro/logs`.
    static func defaultLogsRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".kiro")
            .appendingPathComponent("logs")
    }

    private let logsRoot: URL

    init(logsRoot: URL? = nil) {
        self.logsRoot = logsRoot ?? Self.defaultLogsRoot()
    }

    /// Locates every `<logsRoot>/*/kiro.log` file (one directory level deep).
    func discoverLogFiles() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.appendingPathComponent("kiro.log") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Returns the newest valid model observation across all discovered
    /// directories, selected by the JSON `timestamp` field.
    func readLatestObservation() -> Result<ModelObservation, ReaderError> {
        let files = discoverLogFiles()
        guard !files.isEmpty else {
            return .failure(.missing(reason: "No kiro.log files found under \(logsRoot.path)"))
        }

        var newest: ModelObservation?
        var sawAnyCandidateLine = false
        var sawAnyDecodeSuccess = false
        var sawReadableFile = false

        for file in files {
            var currentClientName: String?
            do {
                try UTF8LineScanner.scan(file) { line in
                    sawReadableFile = true

                    if let record = try? JSONDecoder().decode(RawLogLine.self, from: Data(line.utf8)),
                       let message = record.message,
                       let range = message.range(of: "Stored clientInfo.name:") {
                        currentClientName = message[range.upperBound...]
                            .trimmingCharacters(in: .whitespaces)
                        return
                    }

                    guard line.contains("Sending GenerateAssistantResponse") else { return }
                    sawAnyCandidateLine = true
                    guard let observation = parseObservationLine(
                        line,
                        clientName: currentClientName,
                        sourceURL: file
                    ) else { return }
                    sawAnyDecodeSuccess = true
                    if newest == nil || observation.observedAt > newest!.observedAt {
                        newest = observation
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
            return .failure(.invalid(reason: "Found GenerateAssistantResponse records but all failed to decode"))
        }
        if !sawReadableFile {
            return .failure(.ioFailure(reason: "kiro.log files were found but none could be read"))
        }
        return .failure(.missing(reason: "No GenerateAssistantResponse records found"))
    }

    // MARK: - Line parsing

    private func parseObservationLine(_ line: String, clientName: String?, sourceURL: URL) -> ModelObservation? {
        guard let record = try? JSONDecoder().decode(RawLogLine.self, from: Data(line.utf8)) else {
            return nil
        }
        guard let message = record.message else { return nil }
        guard let timestampString = record.timestamp, let observedAt = Self.parseISO8601(timestampString) else {
            return nil
        }
        guard let modelID = Self.extractValue(for: "modelId", from: message) else { return nil }

        let agentMode = Self.extractValue(for: "agentMode", from: message)
        let origin = Self.extractValue(for: "origin", from: message)
        let source = Self.classifySource(clientName: clientName, origin: origin)

        return ModelObservation(
            modelID: modelID,
            agentMode: agentMode,
            origin: origin,
            clientName: clientName,
            observedAt: observedAt,
            source: source,
            sourceURL: sourceURL
        )
    }

    /// Maps `clientName == kiro-cli` to `.kiroCLI`, `origin == AI_EDITOR` to
    /// `.aiEditor` (never Xcode ACP specifically), and everything else to
    /// `.unknown`, per spec steps 6-9.
    static func classifySource(clientName: String?, origin: String?) -> ModelSource {
        if clientName == "kiro-cli" {
            return .kiroCLI
        }
        if origin == "AI_EDITOR" {
            return .aiEditor
        }
        return .unknown
    }

    /// Extracts `key=value` tokens from a space-delimited message fragment,
    /// stopping at the next whitespace.
    static func extractValue(for key: String, from message: String) -> String? {
        let marker = "\(key)="
        guard let markerRange = message.range(of: marker) else { return nil }
        let remainder = message[markerRange.upperBound...]
        let value = remainder.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
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

/// Tolerant decode target for a single structured log line.
private struct RawLogLine: Decodable {
    let timestamp: String?
    let level: String?
    let message: String?
}
