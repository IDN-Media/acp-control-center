import Foundation

/// Bounded-memory UTF-8 line scanning for potentially large log files.
///
/// The scanner retains at most one partial line plus the current chunk. Callers
/// decide which lines to decode and do not need to load an entire log into
/// memory.
///
/// Lines exceeding `maxLineBytes` (default 1 MiB) are skipped entirely rather
/// than emitted truncated. This ensures bounded memory usage regardless of
/// input content.
enum UTF8LineScanner {
    /// Default maximum line size: 1 MiB.
    static let defaultMaxLineBytes: Int = 1_048_576

    /// Scans `url` line-by-line, invoking `body` for each complete line that
    /// fits within `maxLineBytes`.
    ///
    /// - Parameters:
    ///   - url: File to scan.
    ///   - chunkSize: Read chunk size in bytes. Must be positive.
    ///   - maxLineBytes: Maximum allowed line length in bytes. Lines exceeding
    ///     this are skipped entirely (not truncated). Must be positive.
    ///   - body: Closure invoked with each valid, non-empty line.
    /// - Throws: If the file cannot be opened or read.
    static func scan(
        _ url: URL,
        chunkSize: Int = 64 * 1024,
        maxLineBytes: Int = defaultMaxLineBytes,
        _ body: (String) -> Void
    ) throws {
        precondition(chunkSize > 0, "chunkSize must be positive")
        precondition(maxLineBytes > 0, "maxLineBytes must be positive")

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        // Tracks whether the current accumulating line has exceeded the limit.
        // When true, bytes are discarded until the next newline.
        var oversized = false

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                if oversized {
                    // This newline terminates the oversized line. Discard it
                    // and reset tracking.
                    oversized = false
                } else if lineData.count > maxLineBytes {
                    // The complete line exceeds the cap — skip it.
                    // (no-op: just don't emit)
                } else if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    body(line)
                }
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
            }

            // If the buffer (which is a partial line without a newline yet)
            // exceeds maxLineBytes, mark it as oversized and discard
            // accumulated bytes to bound memory.
            if !oversized && buffer.count > maxLineBytes {
                oversized = true
                buffer.removeAll(keepingCapacity: true)
            } else if oversized {
                // Continue discarding bytes for the oversized line.
                buffer.removeAll(keepingCapacity: true)
            }
        }

        // Handle final content without a trailing newline.
        if !oversized && !buffer.isEmpty {
            if buffer.count <= maxLineBytes,
               let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                body(line)
            }
        }
        // If oversized, the final partial line is skipped entirely.
    }
}
