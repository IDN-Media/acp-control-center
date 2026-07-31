import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `KiroUsageLiveReader` covering ANSI stripping, text output
/// parsing, error handling, and DashboardViewModel integration (preference
/// for live data with local-log fallback).
///
/// All fixtures use sanitized placeholder data — no real emails, account
/// IDs, ARNs, paths, or credentials.
struct KiroUsageLiveReaderTests {

    // MARK: - ANSI stripping

    @Test
    func stripANSIRemovesCSISequences() {
        let input = "\u{1B}[1m\u{1B}[32mEstimated Usage\u{1B}[0m | resets on 2026-08-01 | KIRO PRO"
        let result = KiroUsageLiveReader.stripANSI(input)
        #expect(result == "Estimated Usage | resets on 2026-08-01 | KIRO PRO")
    }

    @Test
    func stripANSIRemovesOSCSequences() {
        let input = "\u{1B}]0;kiro-cli\u{07}Credits (739.91 of 1000 covered in plan)"
        let result = KiroUsageLiveReader.stripANSI(input)
        #expect(result == "Credits (739.91 of 1000 covered in plan)")
    }

    @Test
    func stripANSIRemovesControlCharacters() {
        let input = "Credits\u{01}\u{02}\u{03} (500 of 1000 covered in plan)"
        let result = KiroUsageLiveReader.stripANSI(input)
        #expect(result == "Credits (500 of 1000 covered in plan)")
    }

    @Test
    func stripANSIPreservesNewlinesAndTabs() {
        let input = "Line1\nLine2\tTabbed"
        let result = KiroUsageLiveReader.stripANSI(input)
        #expect(result == "Line1\nLine2\tTabbed")
    }

    @Test
    func stripANSIHandlesEmptyString() {
        #expect(KiroUsageLiveReader.stripANSI("") == "")
    }

    @Test
    func stripANSIHandlesMultipleNestedSequences() {
        let input = "\u{1B}[38;2;255;128;0m\u{1B}[1mBold Orange Text\u{1B}[0m\u{1B}[39m"
        let result = KiroUsageLiveReader.stripANSI(input)
        #expect(result == "Bold Orange Text")
    }

    // MARK: - Successful parsing

    @Test
    func parseStandardOutput() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let text = """
        Estimated Usage | resets on 2026-08-01 | KIRO PRO
        Credits (739.91 of 1000 covered in plan)
        ████████████████░░░░░░░░ 74%
        """
        let now = Date()
        let result = reader.parse(text, observedAt: now)

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "739.91"))
        #expect(usage.limit == Decimal(1000))
        #expect(usage.planName == "KIRO PRO")
        #expect(usage.resetDate != nil)
        #expect(usage.observedAt == now)
        #expect(usage.sourceLabel == "live Kiro CLI")
    }

    @Test
    func parseOutputWithCommaThousandsSeparator() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let text = """
        Estimated Usage | resets on 2026-08-01 | KIRO ENTERPRISE
        Credits (2,500.75 of 10,000 covered in plan)
        ████░░░░░░░░░░░░░░░░░░░░ 25%
        """
        let result = reader.parse(text, observedAt: Date())

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "2500.75"))
        #expect(usage.limit == Decimal(10000))
        #expect(usage.planName == "KIRO ENTERPRISE")
    }

    @Test
    func parseOutputWithCommaDecimalSeparator() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let text = """
        Estimated Usage | resets on 2026-08-01 | KIRO PRO
        Credits (739,91 of 1000 covered in plan)
        """
        let result = reader.parse(text, observedAt: Date())

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "739.91"))
        #expect(usage.limit == Decimal(1000))
    }

    @Test
    func parseOutputWithoutResetDate() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let text = """
        Estimated Usage | KIRO PRO
        Credits (500 of 1000 covered in plan)
        """
        let result = reader.parse(text, observedAt: Date())

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(500))
        #expect(usage.limit == Decimal(1000))
        #expect(usage.resetDate == nil)
        #expect(usage.planName == "KIRO PRO")
    }

    @Test
    func parseOutputWithANSIEscapes() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let rawText = "\u{1B}[1mEstimated Usage\u{1B}[0m | resets on 2026-08-01 | "
            + "\u{1B}[32mKIRO PRO\u{1B}[0m\n"
            + "\u{1B}[36mCredits\u{1B}[0m (739.91 of 1000 covered in plan)\n"
        let cleaned = KiroUsageLiveReader.stripANSI(rawText)
        let result = reader.parse(cleaned, observedAt: Date())

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "739.91"))
        #expect(usage.limit == Decimal(1000))
        #expect(usage.planName == "KIRO PRO")
    }

    // MARK: - Malformed output

    @Test
    func parseEmptyOutputFails() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let result = reader.parse("", observedAt: Date())

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        #expect(error == .parseFailed(reason: "Empty output from kiro-cli"))
    }

    @Test
    func parseOutputWithNoCreditLineFails() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let text = """
        Estimated Usage | resets on 2026-08-01 | KIRO PRO
        No usage data available.
        """
        let result = reader.parse(text, observedAt: Date())

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .parseFailed = error else {
            Issue.record("Expected .parseFailed, got \(error)")
            return
        }
    }

    @Test
    func parseGarbageOutputFails() {
        let reader = KiroUsageLiveReader(
            cliExecutableURL: URL(fileURLWithPath: "/tmp/fake-cli")
        )
        let text = "Some random output that has nothing useful"
        let result = reader.parse(text, observedAt: Date())

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .parseFailed = error else {
            Issue.record("Expected .parseFailed, got \(error)")
            return
        }
    }

    // MARK: - CLI failure scenarios

    @Test
    func nonExecutableCLIReturnsError() {
        let nonExistentPath = URL(fileURLWithPath: "/tmp/nonexistent-kiro-cli-\(UUID().uuidString)")
        let reader = KiroUsageLiveReader(cliExecutableURL: nonExistentPath)
        let result = reader.fetchLiveUsage()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        #expect(error == .cliNotExecutable)
    }

    @Test
    func notLoggedInDetection() {
        // This test verifies the detection logic using a mock script that
        // outputs an authentication error message. We create a temporary
        // script that simulates the not-logged-in scenario.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("fake-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        echo "Error: You are not logged in. Please run 'kiro-cli login' first." >&2
        exit 1
        """
        try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let reader = KiroUsageLiveReader(cliExecutableURL: scriptURL)
        let result = reader.fetchLiveUsage()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        #expect(error == .notLoggedIn)
    }

    @Test
    func nonZeroExitWithoutLoginMessageReturnsCommandFailed() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("fake-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        echo "Internal error occurred" >&2
        exit 42
        """
        try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let reader = KiroUsageLiveReader(cliExecutableURL: scriptURL)
        let result = reader.fetchLiveUsage()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .commandFailed(let reason) = error else {
            Issue.record("Expected .commandFailed, got \(error)")
            return
        }
        // Verify that raw output is NOT in the reason
        #expect(!reason.contains("Internal error"))
        #expect(reason.contains("42"))
    }

    @Test
    func successfulCLIWithValidOutput() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("fake-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        echo "Estimated Usage | resets on 2026-08-01 | KIRO PRO"
        echo "Credits (850.25 of 1000 covered in plan)"
        echo "████████████████████░░░░ 85%"
        """
        try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let reader = KiroUsageLiveReader(cliExecutableURL: scriptURL)
        let result = reader.fetchLiveUsage()

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "850.25"))
        #expect(usage.limit == Decimal(1000))
        #expect(usage.planName == "KIRO PRO")
        #expect(usage.sourceLabel == "live Kiro CLI")
    }

    @Test
    func successfulCLIWithDataOnStderr() {
        // Some CLI tools write informational output to stderr even on
        // success (e.g. progress indicators). The reader should parse
        // combined stdout+stderr.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("fake-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        echo "Estimated Usage | resets on 2026-08-01 | KIRO PRO" >&2
        echo "Credits (420.00 of 1000 covered in plan)" >&2
        echo "████████░░░░░░░░░░░░░░░░ 42%" >&2
        """
        try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let reader = KiroUsageLiveReader(cliExecutableURL: scriptURL)
        let result = reader.fetchLiveUsage()

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "420.00"))
        #expect(usage.limit == Decimal(1000))
        #expect(usage.planName == "KIRO PRO")
    }

    // MARK: - DashboardViewModel integration

    @Test @MainActor
    func viewModelPrefersLiveUsageOverLocalLog() async throws {
        // Set up a local log root with valid data
        let usageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = usageRoot
            .appendingPathComponent("session0")
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("kiro.kiroAgent")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: FixtureLocator.url("usage/usage-current-schema.log"),
            to: sessionDir.appendingPathComponent("q-client.log")
        )
        defer { try? FileManager.default.removeItem(at: usageRoot) }

        // Set up a fake CLI that returns live usage
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("fake-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        echo "Estimated Usage | resets on 2026-08-15 | KIRO PRO"
        echo "Credits (900.50 of 1000 covered in plan)"
        echo "████████████████████████ 90%"
        """
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: usageRoot),
            liveUsageReader: KiroUsageLiveReader(cliExecutableURL: scriptURL),
            modelReader: KiroModelObservationReader(logsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            wrapperReader: ACPWrapperReader(acpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            usageLogsRoot: usageRoot,
            modelLogsRoot: FileManager.default.temporaryDirectory
        )

        await viewModel.refresh()

        guard let snapshot = viewModel.snapshot else {
            Issue.record("Expected a snapshot after refresh")
            return
        }
        guard case .success(let usage) = snapshot.accountUsage else {
            Issue.record("Expected usage success")
            return
        }
        // Should use live data, not local log (which has 637.63)
        #expect(usage.used == Decimal(string: "900.50"))
        #expect(usage.source == .liveCLI)
        // Live CLI has no backing file — sourceURL must be nil, never /dev/null
        #expect(usage.sourceURL == nil)
    }

    @Test @MainActor
    func viewModelFallsBackToLocalLogWhenLiveFails() async throws {
        // Set up a local log root with valid data
        let usageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = usageRoot
            .appendingPathComponent("session0")
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("kiro.kiroAgent")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: FixtureLocator.url("usage/usage-current-schema.log"),
            to: sessionDir.appendingPathComponent("q-client.log")
        )
        defer { try? FileManager.default.removeItem(at: usageRoot) }

        // Set up a fake CLI that fails (not logged in)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("fake-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        echo "Error: not logged in" >&2
        exit 1
        """
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: usageRoot),
            liveUsageReader: KiroUsageLiveReader(cliExecutableURL: scriptURL),
            modelReader: KiroModelObservationReader(logsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            wrapperReader: ACPWrapperReader(acpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            usageLogsRoot: usageRoot,
            modelLogsRoot: FileManager.default.temporaryDirectory
        )

        await viewModel.refresh()

        guard let snapshot = viewModel.snapshot else {
            Issue.record("Expected a snapshot after refresh")
            return
        }
        guard case .success(let usage) = snapshot.accountUsage else {
            Issue.record("Expected usage success (from local fallback)")
            return
        }
        // Should fall back to local log data (637.63)
        #expect(usage.used == Decimal(string: "637.63"))
        #expect(usage.source == .localLog)
        // Local log fallback has an actual source file URL
        #expect(usage.sourceURL != nil)
    }

    @Test @MainActor
    func viewModelFallsBackWhenCLINotExecutable() async throws {
        // Set up a local log root with valid data
        let usageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = usageRoot
            .appendingPathComponent("session0")
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("kiro.kiroAgent")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: FixtureLocator.url("usage/usage-current-schema.log"),
            to: sessionDir.appendingPathComponent("q-client.log")
        )
        defer { try? FileManager.default.removeItem(at: usageRoot) }

        // Live reader points to non-existent CLI
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: usageRoot),
            liveUsageReader: KiroUsageLiveReader(cliExecutableURL: URL(fileURLWithPath: "/tmp/nonexistent-cli-\(UUID().uuidString)")),
            modelReader: KiroModelObservationReader(logsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            wrapperReader: ACPWrapperReader(acpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            usageLogsRoot: usageRoot,
            modelLogsRoot: FileManager.default.temporaryDirectory
        )

        await viewModel.refresh()

        guard let snapshot = viewModel.snapshot else {
            Issue.record("Expected a snapshot after refresh")
            return
        }
        guard case .success(let usage) = snapshot.accountUsage else {
            Issue.record("Expected usage success (from local fallback)")
            return
        }
        #expect(usage.source == .localLog)
    }

    @Test @MainActor
    func viewModelWithNilLiveReaderUsesLocalLogDirectly() async throws {
        // Set up a local log root with valid data
        let usageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = usageRoot
            .appendingPathComponent("session0")
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("kiro.kiroAgent")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: FixtureLocator.url("usage/usage-current-schema.log"),
            to: sessionDir.appendingPathComponent("q-client.log")
        )
        defer { try? FileManager.default.removeItem(at: usageRoot) }

        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: usageRoot),
            liveUsageReader: nil,
            modelReader: KiroModelObservationReader(logsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            wrapperReader: ACPWrapperReader(acpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            usageLogsRoot: usageRoot,
            modelLogsRoot: FileManager.default.temporaryDirectory
        )

        await viewModel.refresh()

        guard let snapshot = viewModel.snapshot else {
            Issue.record("Expected a snapshot after refresh")
            return
        }
        guard case .success(let usage) = snapshot.accountUsage else {
            Issue.record("Expected usage success")
            return
        }
        #expect(usage.source == .localLog)
    }

    @Test @MainActor
    func diagnosticSummaryClearlyIdentifiesLiveSource() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("fake-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        echo "Estimated Usage | resets on 2026-08-01 | KIRO PRO"
        echo "Credits (100 of 1000 covered in plan)"
        """
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            liveUsageReader: KiroUsageLiveReader(cliExecutableURL: scriptURL),
            modelReader: KiroModelObservationReader(logsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            wrapperReader: ACPWrapperReader(acpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            usageLogsRoot: FileManager.default.temporaryDirectory,
            modelLogsRoot: FileManager.default.temporaryDirectory
        )

        await viewModel.refresh()

        let summary = viewModel.diagnosticSummary()
        #expect(summary.contains("live Kiro CLI"))
        #expect(!summary.contains("local log"))
        // Must never present /dev/null as a source path
        #expect(!summary.contains("/dev/null"))
    }

    @Test @MainActor
    func diagnosticSummaryClearlyIdentifiesLocalLogFallback() async throws {
        let usageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = usageRoot
            .appendingPathComponent("session0")
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("kiro.kiroAgent")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: FixtureLocator.url("usage/usage-current-schema.log"),
            to: sessionDir.appendingPathComponent("q-client.log")
        )
        defer { try? FileManager.default.removeItem(at: usageRoot) }

        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: usageRoot),
            liveUsageReader: KiroUsageLiveReader(cliExecutableURL: URL(fileURLWithPath: "/tmp/nonexistent-cli-\(UUID().uuidString)")),
            modelReader: KiroModelObservationReader(logsRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            wrapperReader: ACPWrapperReader(acpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            usageLogsRoot: usageRoot,
            modelLogsRoot: FileManager.default.temporaryDirectory
        )

        await viewModel.refresh()

        let summary = viewModel.diagnosticSummary()
        #expect(summary.contains("local log (fallback)"))
        #expect(!summary.contains("live Kiro CLI"))
    }
}
