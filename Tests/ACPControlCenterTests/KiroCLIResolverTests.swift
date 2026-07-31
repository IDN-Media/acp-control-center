import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `KiroCLIResolver`.
struct KiroCLIResolverTests {
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
}
