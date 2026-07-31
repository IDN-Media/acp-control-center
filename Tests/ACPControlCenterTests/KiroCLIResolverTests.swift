import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `KiroCLIResolver`.
struct KiroCLIResolverTests {
    private func makeExecutable(at url: URL, version: String = "9.9.9") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\necho \"kiro-cli \(version)\"\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    @Test
    func nonexistentExecutableReportsNotExecutable() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        let resolver = KiroCLIResolver(executableURL: url)
        let installation = resolver.resolve()

        #expect(installation.isExecutable == false)
        #expect(installation.version == nil)
    }

    @Test
    func executableScriptReportsVersionFromOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCLI = root.appendingPathComponent("fake-kiro-cli")
        let script = "#!/bin/sh\necho \"kiro-cli 9.9.9\"\n"
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let resolver = KiroCLIResolver(executableURL: fakeCLI)
        let installation = resolver.resolve()

        #expect(installation.isExecutable == true)
        #expect(installation.version == "9.9.9")
    }

    @Test
    func defaultExecutableURLUsesLocalBinPath() {
        let home = URL(fileURLWithPath: "/Users/exampleuser")
        let url = KiroCLIResolver.defaultExecutableURL(homeDirectory: home)
        #expect(url.path == "/Users/exampleuser/.local/bin/kiro-cli")
    }

    @Test
    func preferredExecutableWinsOverKnownCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferred = root.appendingPathComponent("custom/kiro-cli")
        let known = root.appendingPathComponent("known/kiro-cli")
        try makeExecutable(at: preferred, version: "1.0.0")
        try makeExecutable(at: known, version: "2.0.0")

        let installation = KiroCLIResolver(candidateURLs: [known])
            .resolve(preferredExecutableURL: preferred)

        #expect(installation.executableURL == preferred)
        #expect(installation.discoverySource == .selected)
        #expect(installation.availability == .ready)
        #expect(installation.version == "1.0.0")
    }

    @Test
    func movedPreferredPathFallsBackToKnownCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = root.appendingPathComponent("moved/kiro-cli")
        let known = root.appendingPathComponent("known/kiro-cli")
        try makeExecutable(at: known)

        let installation = KiroCLIResolver(candidateURLs: [known])
            .resolve(preferredExecutableURL: moved)

        #expect(installation.executableURL == known)
        #expect(installation.discoverySource == .knownLocation)
        #expect(installation.availability == .ready)
    }

    @Test
    func brokenCandidateFallsBackToNextWorkingCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("broken/kiro-cli")
        let working = root.appendingPathComponent("working/kiro-cli")
        try FileManager.default.createDirectory(
            at: broken.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        try makeExecutable(at: working, version: "4.0.0")

        let installation = KiroCLIResolver(candidateURLs: [broken, working]).resolve()

        #expect(installation.executableURL == working)
        #expect(installation.availability == .ready)
        #expect(installation.version == "4.0.0")
    }

    @Test
    func nonExecutablePreferredPathIsActionableWhenNoFallbackExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferred = root.appendingPathComponent("custom/kiro-cli")
        try FileManager.default.createDirectory(
            at: preferred.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not executable".write(to: preferred, atomically: true, encoding: .utf8)

        let installation = KiroCLIResolver(candidateURLs: [])
            .resolve(preferredExecutableURL: preferred)

        #expect(installation.executableURL == preferred)
        #expect(installation.discoverySource == .selected)
        #expect(installation.availability == .notExecutable)
        #expect(installation.isExecutable == false)
    }

    @Test
    func pathEnvironmentCandidatesAreBoundedAndDeduplicated() {
        let home = URL(fileURLWithPath: "/Users/exampleuser")
        let urls = KiroCLIResolver.defaultCandidateURLs(
            homeDirectory: home,
            pathEnvironment: "/custom/bin:/opt/homebrew/bin:/custom/bin"
        )

        #expect(urls.first?.path == "/Users/exampleuser/.local/bin/kiro-cli")
        #expect(urls.contains(URL(fileURLWithPath: "/opt/homebrew/bin/kiro-cli")))
        #expect(urls.contains(URL(fileURLWithPath: "/usr/local/bin/kiro-cli")))
        #expect(urls.contains(URL(fileURLWithPath: "/custom/bin/kiro-cli")))
        #expect(Set(urls.map(\.standardizedFileURL.path)).count == urls.count)
    }

    @Test
    func pathEnvironmentCandidateCountIsCapped() {
        let pathEnvironment = (0..<60)
            .map { "/custom/path\($0)" }
            .joined(separator: ":")
        let urls = KiroCLIResolver.defaultCandidateURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/exampleuser"),
            pathEnvironment: pathEnvironment
        )

        #expect(urls.contains(URL(fileURLWithPath: "/custom/path49/kiro-cli")))
        #expect(!urls.contains(URL(fileURLWithPath: "/custom/path50/kiro-cli")))
    }

    @Test
    func selectedPathStoreRoundTripsAndClears() {
        let suiteName = "KiroCLIResolverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = KiroCLISelectionStore(userDefaults: defaults)
        let selected = URL(fileURLWithPath: "/custom/kiro-cli")

        store.save(selected)
        #expect(store.load() == selected)

        store.save(nil)
        #expect(store.load() == nil)
    }
}
