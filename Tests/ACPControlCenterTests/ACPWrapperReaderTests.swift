import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `ACPWrapperReader` covering wrapper parsing with and without
/// `--model`/`--effort` flags, and an invalid (unparsable/malformed) wrapper.
struct ACPWrapperReaderTests {
    @Test
    func wrapperWithoutFlagsReportsUnspecifiedModelAndEffort() throws {
        let wrapperURL = FixtureLocator.url("wrapper/wrapper-no-flags.sh")
        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: wrapperURL)

        guard case .success(let config) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(config.cliExecutableURL?.path == "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli")
        #expect(config.modelID == nil)
        #expect(config.effort == nil)
        #expect(config.syntaxIsValid == true)
    }

    @Test
    func wrapperWithFlagsParsesModelAndEffort() throws {
        let wrapperURL = FixtureLocator.url("wrapper/wrapper-with-flags.sh")
        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: wrapperURL)

        guard case .success(let config) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(config.cliExecutableURL?.path == "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli")
        #expect(config.modelID == "claude-opus-4.6")
        #expect(config.effort == "high")
        #expect(config.syntaxIsValid == true)
    }

    @Test
    func malformedWrapperFailsSyntaxCheck() throws {
        let wrapperURL = FixtureLocator.url("wrapper/wrapper-malformed.sh")
        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: wrapperURL)

        guard case .success(let config) = result else {
            Issue.record("Expected success (executable extraction still works), got \(result)")
            return
        }
        // Executable extraction can still succeed even though the script has
        // a syntax error elsewhere; syntax validation must catch it.
        #expect(config.syntaxIsValid == false)
    }

    @Test
    func nonexistentWrapperReturnsMissing() {
        let wrapperURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).sh")
        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: wrapperURL)

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .missing = error else {
            Issue.record("Expected .missing, got \(error)")
            return
        }
    }

    @Test
    func wrapperTextWithoutAcpInvocationIsInvalid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperURL = root.appendingPathComponent("no-acp.sh")
        try "#!/bin/zsh\necho hello\n".write(to: wrapperURL, atomically: true, encoding: .utf8)

        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: wrapperURL)

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .invalid = error else {
            Issue.record("Expected .invalid, got \(error)")
            return
        }
    }

    @Test
    func plistResolutionFindsWrapperPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperURL = FixtureLocator.url("wrapper/wrapper-no-flags.sh")

        let plistURL = root.appendingPathComponent("TEST-ACP.plist")
        let plistDict: [String: Any] = [
            "agent": wrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let reader = ACPWrapperReader(acpDirectory: root)
        let result = reader.readWrapperConfiguration()

        guard case .success(let config) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(config.wrapperURL == wrapperURL)
    }

    @Test
    func missingACPDirectoryReturnsMissing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ACPWrapperReader(acpDirectory: root)
        let result = reader.readWrapperConfiguration()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .missing = error else {
            Issue.record("Expected .missing, got \(error)")
            return
        }
    }

    @Test
    func parserIgnoresCommentsAndKeepsFlagsOnSelectedInvocation() {
        let contents = """
        # exec "/old/kiro-cli" acp --model old-model
        exec "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli" acp --model=claude-sonnet-5 --effort high
        echo --model unrelated-model
        """

        #expect(ACPWrapperReader.extractExecutable(fromWrapperContents: contents)?.path == "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli")
        #expect(ACPWrapperReader.extractFlagValue(named: "--model", fromWrapperContents: contents) == "claude-sonnet-5")
        #expect(ACPWrapperReader.extractFlagValue(named: "--effort", fromWrapperContents: contents) == "high")
    }

    @Test
    func dynamicExecutableIsRejectedInsteadOfGuessed() {
        let contents = """
        CLI="/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"
        exec "$CLI" acp --model "$MODEL"
        """

        #expect(ACPWrapperReader.extractExecutable(fromWrapperContents: contents) == nil)
        #expect(ACPWrapperReader.extractFlagValue(named: "--model", fromWrapperContents: contents) == nil)
    }
}
