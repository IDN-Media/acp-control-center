import Foundation

/// Resolves Kiro CLI from a bounded candidate list. It never recursively
/// scans the filesystem and accepts injected candidates for isolated tests.
struct KiroCLIResolver: Sendable {
    /// Default local path: `~/.local/bin/kiro-cli`, typically a symlink into
    /// `/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli`.
    static func defaultExecutableURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".local")
            .appendingPathComponent("bin")
            .appendingPathComponent("kiro-cli")
    }

    static func defaultCandidateURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [URL] {
        var urls = [
            defaultExecutableURL(homeDirectory: homeDirectory),
            URL(fileURLWithPath: "/opt/homebrew/bin/kiro-cli"),
            URL(fileURLWithPath: "/usr/local/bin/kiro-cli")
        ]

        if let pathEnvironment {
            urls.append(contentsOf: pathEnvironment
                .split(separator: ":")
                .prefix(50)
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent("kiro-cli") })
        }

        urls.append(URL(fileURLWithPath: "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"))
        urls.append(
            homeDirectory
                .appendingPathComponent("Applications/Kiro CLI.app/Contents/MacOS/kiro-cli")
        )

        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private let candidateURLs: [URL]
    private let processRunner: ProcessRunner
    let acceptsPersistedSelection: Bool

    init(
        executableURL: URL? = nil,
        candidateURLs: [URL]? = nil,
        processRunner: ProcessRunner = ProcessRunner()
    ) {
        self.acceptsPersistedSelection = executableURL == nil && candidateURLs == nil
        if let executableURL {
            self.candidateURLs = [executableURL]
        } else {
            self.candidateURLs = candidateURLs ?? Self.defaultCandidateURLs()
        }
        self.processRunner = processRunner
    }

    /// Resolves the installation. Never throws: a missing/non-executable CLI
    /// is a valid, displayable state rather than an error.
    func resolve(preferredExecutableURL: URL? = nil) -> KiroCLIInstallation {
        var candidates: [(url: URL, source: KiroCLIDiscoverySource)] = []
        if let preferredExecutableURL {
            candidates.append((preferredExecutableURL, .selected))
        }
        candidates.append(contentsOf: candidateURLs.map { ($0, .knownLocation) })

        var seen = Set<String>()
        var firstUnavailable: KiroCLIInstallation?
        for candidate in candidates where seen.insert(candidate.url.standardizedFileURL.path).inserted {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }

            guard FileManager.default.isExecutableFile(atPath: candidate.url.path) else {
                firstUnavailable = firstUnavailable ?? KiroCLIInstallation(
                    executableURL: candidate.url,
                    resolvedExecutableURL: resolveSymlink(candidate.url),
                    version: nil,
                    discoverySource: candidate.source,
                    availability: .notExecutable,
                    isExecutable: false
                )
                continue
            }

            let output = processRunner.run(executableURL: candidate.url, arguments: ["--version"])
            guard output.exitCode == 0 else {
                firstUnavailable = firstUnavailable ?? KiroCLIInstallation(
                    executableURL: candidate.url,
                    resolvedExecutableURL: resolveSymlink(candidate.url),
                    version: nil,
                    discoverySource: candidate.source,
                    availability: .launchFailed(reason: "Unable to run kiro-cli --version"),
                    isExecutable: true
                )
                continue
            }

            return KiroCLIInstallation(
                executableURL: candidate.url,
                resolvedExecutableURL: resolveSymlink(candidate.url),
                version: parseVersion(from: output.standardOutput + "\n" + output.standardError),
                discoverySource: candidate.source,
                availability: .ready,
                isExecutable: true
            )
        }

        if let firstUnavailable {
            return firstUnavailable
        }

        return KiroCLIInstallation(
            executableURL: preferredExecutableURL,
            resolvedExecutableURL: nil,
            version: nil,
            discoverySource: preferredExecutableURL == nil ? nil : .selected,
            availability: .notFound,
            isExecutable: false
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

/// Persists only a user-selected executable path. It never stores credentials
/// or copies the executable itself.
/// Intentionally non-Sendable because Foundation's UserDefaults is not
/// Sendable. DashboardViewModel owns and accesses this store on MainActor.
struct KiroCLISelectionStore {
    private static let key = "selectedKiroCLIExecutablePath"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> URL? {
        guard let path = userDefaults.string(forKey: Self.key), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    func save(_ url: URL?) {
        if let url {
            userDefaults.set(url.standardizedFileURL.path, forKey: Self.key)
        } else {
            userDefaults.removeObject(forKey: Self.key)
        }
    }
}
