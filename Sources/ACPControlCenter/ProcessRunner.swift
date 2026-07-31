import Foundation
import Darwin

/// A narrow process runner for short, bounded read-only invocations such as
/// `kiro-cli --version` and `/bin/zsh -n <wrapper>`.
///
/// Output is redirected to temporary files instead of pipes. That prevents a
/// child with verbose output from filling a pipe buffer while this runner is
/// waiting for termination.
///
/// The runner creates a unique directory under the system temporary directory
/// with POSIX 0700 permissions and individual files with 0600 permissions.
/// Captured output is bounded to `maxCapturedOutputBytes` (default 1 MiB);
/// if output exceeds this cap, the returned string contains the prefix plus
/// a truncation marker, while the process continues draining to the file
/// until it exits naturally.
struct ProcessRunner: Sendable {
    struct Output: Sendable {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Default maximum bytes to read from each output file.
    static let defaultMaxCapturedOutputBytes: Int = 1_048_576
    static let maximumMaxCapturedOutputBytes: Int = 16_777_216

    /// Maximum bytes to capture from stdout/stderr each. Values are clamped
    /// to 1...16 MiB, which also keeps the `cap + 1` read overflow-safe.
    let maxCapturedOutputBytes: Int

    init(maxCapturedOutputBytes: Int = ProcessRunner.defaultMaxCapturedOutputBytes) {
        self.maxCapturedOutputBytes = min(
            max(1, maxCapturedOutputBytes),
            ProcessRunner.maximumMaxCapturedOutputBytes
        )
    }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval = 5.0) -> Output {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ACPControlCenter-\(UUID().uuidString)")

        // Create directory with restricted permissions (0700).
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return Output(exitCode: -1, standardOutput: "", standardError: "Could not create temporary output directory: \(error)")
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")

        // Create files with restricted permissions (0600).
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fileManager.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return Output(exitCode: -1, standardOutput: "", standardError: "Could not prepare temporary output files")
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            return Output(exitCode: -1, standardOutput: "", standardError: "\(error)")
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdoutStr = readBounded(url: stdoutURL)
        let stderrStr = readBounded(url: stderrURL)

        return Output(
            exitCode: process.terminationStatus,
            standardOutput: stdoutStr,
            standardError: stderrStr
        )
    }

    /// Reads up to `maxCapturedOutputBytes` from `url`. If the file is larger,
    /// returns the prefix decoded as UTF-8 with a truncation marker appended.
    private func readBounded(url: URL) -> String {
        guard let readHandle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? readHandle.close() }

        let cap = maxCapturedOutputBytes
        guard let data = try? readHandle.read(upToCount: cap + 1) else {
            return ""
        }

        if data.count > cap {
            // File exceeds cap — return the prefix with truncation marker.
            let prefix = data.prefix(cap)
            let text = String(data: prefix, encoding: .utf8)
                ?? String(decoding: prefix, as: UTF8.self)
            return text + "\n[output truncated]"
        } else {
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
