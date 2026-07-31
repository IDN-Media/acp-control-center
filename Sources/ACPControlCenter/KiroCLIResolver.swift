import Foundation

/// Resolves the Kiro CLI installation used for ACP. Defaults to the real
/// local path documented in the grooming plan, but accepts an injected path
/// so tests never touch the real filesystem.
struct KiroCLIResolver: Sendable {
    /// Default local path: `~/.local/bin/kiro-cli`, typically a symlink into
    /// `/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli`.
    static func defaultExecutableURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".local")
            .appendingPathComponent("bin")
            .appendingPathComponent("kiro-cli")
    }

    private let executableURL: URL
    private let processRunner: ProcessRunner

    init(
        executableURL: URL? = nil,
        processRunner: ProcessRunner = ProcessRunner()
    ) {
        self.executableURL = executableURL ?? Self.defaultExecutableURL()
        self.processRunner = processRunner
    }

    /// Resolves the installation. Never throws: a missing/non-executable CLI
    /// is a valid, displayable state rather than an error.
    func resolve() -> KiroCLIInstallation {
        let resolvedURL = resolveSymlink(executableURL)
        let isExecutable = FileManager.default.isExecutableFile(atPath: executableURL.path)

        var version: String?
        if isExecutable {
            let output = processRunner.run(executableURL: executableURL, arguments: ["--version"])
            if output.exitCode == 0 {
                version = parseVersion(from: output.standardOutput)
            }
        }

        return KiroCLIInstallation(
            executableURL: executableURL,
            resolvedExecutableURL: resolvedURL,
            version: version,
            isExecutable: isExecutable
        )
    }

    private func resolveSymlink(_ url: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
    }

    /// Parses output like `kiro-cli 2.15.2` into `2.15.2`.
    private func parseVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: " ", maxSplits: 1)
        if components.count == 2 {
            return String(components[1])
        }
        return trimmed
    }
}
