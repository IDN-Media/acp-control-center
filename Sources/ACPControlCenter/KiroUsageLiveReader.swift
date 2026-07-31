import Foundation

/// Fetches live Kiro account credit usage by invoking
/// `kiro-cli chat --no-interactive '/usage'`.
///
/// This reader:
/// - Never reads token files or calls private APIs.
/// - Uses `ProcessRunner` with a bounded timeout (~20 s).
/// - Strips ANSI escape sequences and control characters from output.
/// - Parses the text-format response for used/limit credits, reset date,
///   and plan name.
/// - Never exposes raw CLI output in user-facing errors.
///
/// Authentication is handled internally by `kiro-cli`; the user must be
/// logged in for a successful response.
struct KiroUsageLiveReader: Sendable {

    // MARK: - Result type

    /// The parsed live usage result. `sourceLabel` always identifies this as
    /// a live CLI response so the UI can distinguish it from a local-log
    /// fallback.
    struct LiveUsageResult: Equatable, Sendable {
        let used: Decimal
        let limit: Decimal
        let resetDate: Date?
        let planName: String?
        let observedAt: Date
        /// Always `"live Kiro CLI"` to distinguish from local-log reader.
        let sourceLabel: String = "live Kiro CLI"
    }

    enum LiveReaderError: Error, Equatable, Sendable {
        case cliNotExecutable
        case notLoggedIn
        case timeout
        case commandFailed(reason: String)
        case parseFailed(reason: String)
    }

    // MARK: - Configuration

    private let cliExecutableURL: URL
    private let processRunner: ProcessRunner
    private let timeout: TimeInterval

    init(
        cliExecutableURL: URL? = nil,
        processRunner: ProcessRunner = ProcessRunner(),
        timeout: TimeInterval = 20.0
    ) {
        self.cliExecutableURL = cliExecutableURL
            ?? KiroCLIResolver.defaultExecutableURL()
        self.processRunner = processRunner
        self.timeout = timeout
    }

    // MARK: - Public API

    /// Invokes `kiro-cli chat --no-interactive '/usage'` and parses the
    /// text response.
    func fetchLiveUsage() -> Result<LiveUsageResult, LiveReaderError> {
        guard FileManager.default.isExecutableFile(atPath: cliExecutableURL.path) else {
            return .failure(.cliNotExecutable)
        }

        let output = processRunner.run(
            executableURL: cliExecutableURL,
            arguments: ["chat", "--no-interactive", "/usage"],
            timeout: timeout
        )

        let completionTime = Date()

        // Timeout detection: ProcessRunner terminates the process and
        // returns exitCode != 0 when the deadline is reached. We detect
        // the specific termination signals.
        if output.exitCode == -1 || output.exitCode == 15 /* SIGTERM */ || output.exitCode == 9 /* SIGKILL */ {
            // Check if stderr suggests the process was terminated
            if output.standardOutput.isEmpty && output.standardError.isEmpty {
                return .failure(.timeout)
            }
        }

        if output.exitCode != 0 {
            let combined = Self.stripANSI(output.standardOutput + output.standardError)
            if combined.localizedCaseInsensitiveContains("not logged in")
                || combined.localizedCaseInsensitiveContains("login")
                || combined.localizedCaseInsensitiveContains("authenticate")
                || combined.localizedCaseInsensitiveContains("credentials") {
                return .failure(.notLoggedIn)
            }
            // Never expose raw output — use a generic reason.
            return .failure(.commandFailed(reason: "kiro-cli exited with code \(output.exitCode)"))
        }

        // Parse combined stdout+stderr because terminal-style CLI output may
        // use either stream. Raw output is never surfaced in errors.
        let cleaned = Self.stripANSI(output.standardOutput + output.standardError)
        return parse(cleaned, observedAt: completionTime)
    }

    // MARK: - ANSI stripping

    /// Removes ANSI escape sequences (CSI, OSC) and ASCII control characters
    /// (except newline/tab) from CLI output.
    static func stripANSI(_ input: String) -> String {
        // CSI sequences: ESC [ ... (ending with a letter)
        // OSC sequences: ESC ] ... (ending with BEL or ST)
        // Single ESC sequences: ESC followed by one char
        var result = ""
        result.reserveCapacity(input.count)

        var iterator = input.makeIterator()
        while let char = iterator.next() {
            if char == "\u{1B}" {
                // Start of escape sequence
                guard let next = iterator.next() else { break }
                if next == "[" {
                    // CSI: consume until a letter (0x40-0x7E)
                    while let c = iterator.next() {
                        if c.asciiValue.map({ $0 >= 0x40 && $0 <= 0x7E }) == true {
                            break
                        }
                    }
                } else if next == "]" {
                    // OSC: consume until BEL (\u{07}) or ST (ESC \)
                    while let c = iterator.next() {
                        if c == "\u{07}" { break }
                        if c == "\u{1B}" {
                            let _ = iterator.next() // consume the backslash
                            break
                        }
                    }
                }
                // else: single-char escape, already consumed
            } else if char.asciiValue.map({ $0 < 0x20 && $0 != 0x0A && $0 != 0x09 && $0 != 0x0D }) == true {
                // Strip other control chars (keep \n, \t, \r)
                continue
            } else {
                result.append(char)
            }
        }
        return result
    }

    // MARK: - Parsing

    /// Parses the cleaned text output from `/usage`. Expected shape:
    /// ```
    /// Estimated Usage | resets on 2026-08-01 | KIRO PRO
    /// Credits (739.91 of 1000 covered in plan)
    /// ████████████████░░░░░░░░ 74%
    /// ```
    func parse(_ text: String, observedAt: Date) -> Result<LiveUsageResult, LiveReaderError> {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return .failure(.parseFailed(reason: "Empty output from kiro-cli"))
        }

        // Parse header line: "Estimated Usage | resets on YYYY-MM-DD | PLAN"
        var resetDate: Date?
        var planName: String?

        for line in lines {
            if let headerMatch = Self.parseHeaderLine(line) {
                resetDate = headerMatch.resetDate
                planName = headerMatch.planName
                break
            }
        }

        // Parse credits line: "Credits (739.91 of 1000 covered in plan)"
        // or variations like "Credits (739.91 of 1,000 covered in plan)"
        var used: Decimal?
        var limit: Decimal?

        for line in lines {
            if let creditsMatch = Self.parseCreditsLine(line) {
                used = creditsMatch.used
                limit = creditsMatch.limit
                break
            }
        }

        guard let parsedUsed = used, let parsedLimit = limit else {
            return .failure(.parseFailed(reason: "Could not parse credit values"))
        }

        return .success(LiveUsageResult(
            used: parsedUsed,
            limit: parsedLimit,
            resetDate: resetDate,
            planName: planName,
            observedAt: observedAt
        ))
    }

    // MARK: - Line parsers

    private struct HeaderMatch {
        let resetDate: Date?
        let planName: String?
    }

    /// Matches "Estimated Usage | resets on 2026-08-01 | KIRO PRO"
    private static func parseHeaderLine(_ line: String) -> HeaderMatch? {
        // Must contain pipe-delimited segments with "resets on" or "Usage"
        let segments = line.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard segments.count >= 2 else { return nil }
        guard segments[0].localizedCaseInsensitiveContains("usage") else { return nil }

        var resetDate: Date?
        var planName: String?

        for segment in segments.dropFirst() {
            let lower = segment.lowercased()
            if lower.contains("resets on") || lower.contains("reset") {
                // Extract date: look for YYYY-MM-DD pattern
                resetDate = extractDate(from: segment)
            } else if !segment.isEmpty {
                planName = segment
            }
        }

        return HeaderMatch(resetDate: resetDate, planName: planName)
    }

    private struct CreditsMatch {
        let used: Decimal
        let limit: Decimal
    }

    /// Matches "Credits (739.91 of 1000 covered in plan)" or similar.
    private static func parseCreditsLine(_ line: String) -> CreditsMatch? {
        let lower = line.lowercased()
        guard lower.contains("credit") else { return nil }

        // Look for pattern: (NUMBER of NUMBER ...)
        // Also handle lines like "Credits: 739.91 / 1000" as fallback
        if let parenMatch = parseParenthesizedCredits(line) {
            return parenMatch
        }
        if let slashMatch = parseSlashCredits(line) {
            return slashMatch
        }
        return nil
    }

    /// Parses "(739.91 of 1000 ...)" or "(739.91 of 1,000 ...)"
    private static func parseParenthesizedCredits(_ line: String) -> CreditsMatch? {
        // Find content within parentheses
        guard let openParen = line.firstIndex(of: "("),
              let closeParen = line.lastIndex(of: ")"),
              openParen < closeParen else {
            // Try without parens — "Credits 739.91 of 1000 covered in plan"
            return parseOfPattern(in: line)
        }
        let content = String(line[line.index(after: openParen)..<closeParen])
        return parseOfPattern(in: content)
    }

    /// Parses "739.91 of 1000" or "739.91 of 1,000" from a string.
    private static func parseOfPattern(in text: String) -> CreditsMatch? {
        // Split on " of " (case-insensitive)
        let parts = text.components(separatedBy: " of ")
        guard parts.count >= 2 else { return nil }

        // First part: the used value (last number token before "of")
        guard let usedValue = parseDecimalFromEnd(of: parts[0]) else { return nil }

        // Second part: the limit value (first number token after "of")
        guard let limitValue = parseDecimalFromStart(of: parts[1]) else { return nil }

        return CreditsMatch(used: usedValue, limit: limitValue)
    }

    /// Parses "739.91 / 1000" from a line.
    private static func parseSlashCredits(_ line: String) -> CreditsMatch? {
        let parts = line.components(separatedBy: "/")
        guard parts.count >= 2 else { return nil }

        guard let usedValue = parseDecimalFromEnd(of: parts[0]) else { return nil }
        guard let limitValue = parseDecimalFromStart(of: parts[1]) else { return nil }

        return CreditsMatch(used: usedValue, limit: limitValue)
    }

    // MARK: - Number parsing

    /// Extracts the last decimal number from a string segment.
    /// Handles formats like "739.91", "1,000", "1,000.50", "739,91" (comma
    /// as decimal separator when no dot is present).
    private static func parseDecimalFromEnd(of text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Walk backwards to find the last contiguous numeric token
        // (digits, dots, commas).
        let numericSet = CharacterSet(charactersIn: "0123456789.,")
        var endIdx = trimmed.endIndex
        // Skip trailing non-numeric chars
        while endIdx > trimmed.startIndex {
            let prevIdx = trimmed.index(before: endIdx)
            if trimmed[prevIdx].unicodeScalars.allSatisfy({ numericSet.contains($0) }) {
                break
            }
            endIdx = prevIdx
        }
        guard endIdx > trimmed.startIndex else { return nil }

        var startIdx = endIdx
        // Walk backwards through numeric chars
        while startIdx > trimmed.startIndex {
            let prevIdx = trimmed.index(before: startIdx)
            if trimmed[prevIdx].unicodeScalars.allSatisfy({ numericSet.contains($0) }) {
                startIdx = prevIdx
            } else {
                break
            }
        }

        guard startIdx < endIdx else { return nil }
        let token = String(trimmed[startIdx..<endIdx])
        return parseNumericToken(token)
    }

    /// Extracts the first decimal number from a string segment.
    private static func parseDecimalFromStart(of text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let numericSet = CharacterSet(charactersIn: "0123456789.,")
        var startIdx: String.Index?
        var endIdx: String.Index?

        for idx in trimmed.indices {
            if trimmed[idx].unicodeScalars.allSatisfy({ numericSet.contains($0) }) {
                if startIdx == nil { startIdx = idx }
                endIdx = trimmed.index(after: idx)
            } else if startIdx != nil {
                break
            }
        }

        guard let s = startIdx, let e = endIdx else { return nil }
        let token = String(trimmed[s..<e])
        return parseNumericToken(token)
    }

    /// Parses a numeric token that may use dot or comma as decimal/grouping
    /// separators. Heuristic:
    /// - If it has both dots and commas, the last one is decimal separator.
    /// - "1,000.50" → 1000.50  (comma = grouping, dot = decimal)
    /// - "1.000,50" → 1000.50  (dot = grouping, comma = decimal)
    /// - "739.91"   → 739.91   (dot = decimal)
    /// - "739,91"   → 739.91   (comma = decimal, only if 2 decimal digits)
    /// - "1,000"    → 1000     (comma = grouping, exactly 3 digits after)
    private static func parseNumericToken(_ token: String) -> Decimal? {
        guard !token.isEmpty else { return nil }

        let hasDot = token.contains(".")
        let hasComma = token.contains(",")

        if hasDot && hasComma {
            // Both present: last separator is the decimal mark
            guard let lastDot = token.lastIndex(of: "."),
                  let lastComma = token.lastIndex(of: ",") else { return nil }
            if lastDot > lastComma {
                // Format: 1,000.50
                let normalized = token.replacingOccurrences(of: ",", with: "")
                return Decimal(string: normalized, locale: Locale(identifier: "en_US"))
            } else {
                // Format: 1.000,50
                let normalized = token
                    .replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
                return Decimal(string: normalized, locale: Locale(identifier: "en_US"))
            }
        } else if hasDot {
            // Dot only: treat as decimal separator
            return Decimal(string: token, locale: Locale(identifier: "en_US"))
        } else if hasComma {
            // Comma only: heuristic
            guard let lastComma = token.lastIndex(of: ",") else { return nil }
            let afterComma = String(token[token.index(after: lastComma)...])
            if afterComma.count == 3 && afterComma.allSatisfy(\.isWholeNumber) {
                // Likely a thousands separator: "1,000" → 1000
                let normalized = token.replacingOccurrences(of: ",", with: "")
                return Decimal(string: normalized, locale: Locale(identifier: "en_US"))
            } else {
                // Likely decimal separator: "739,91" → 739.91
                let normalized = token.replacingOccurrences(of: ",", with: ".")
                return Decimal(string: normalized, locale: Locale(identifier: "en_US"))
            }
        } else {
            // Pure digits
            return Decimal(string: token, locale: Locale(identifier: "en_US"))
        }
    }

    // MARK: - Date parsing

    /// Extracts a date in YYYY-MM-DD format from a string.
    private static func extractDate(from text: String) -> Date? {
        // Look for YYYY-MM-DD pattern
        let pattern = #"(\d{4}-\d{2}-\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let dateString = String(text[range])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.date(from: dateString)
    }
}
