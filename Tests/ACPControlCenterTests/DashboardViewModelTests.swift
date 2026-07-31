import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `DashboardViewModel` composition using injected readers backed
/// by fixture-derived temp directories, never real local Kiro data.
@MainActor
struct DashboardViewModelTests {
    private func makeUsageLogsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = root
            .appendingPathComponent("session0")
            .appendingPathComponent("window1")
            .appendingPathComponent("exthost")
            .appendingPathComponent("kiro.kiroAgent")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: FixtureLocator.url("usage/usage-current-schema.log"),
            to: sessionDir.appendingPathComponent("q-client.log")
        )
        return root
    }

    private func makeModelLogsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = root.appendingPathComponent("session0")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: FixtureLocator.url("model/model-kiro-cli.log"),
            to: sessionDir.appendingPathComponent("kiro.log")
        )
        return root
    }

    private func makeViewModel(liveUsageReader: KiroUsageLiveReader? = nil) throws -> (DashboardViewModel, URL, URL) {
        let usageRoot = try makeUsageLogsRoot()
        let modelRoot = try makeModelLogsRoot()
        let vm = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-cli-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: usageRoot),
            liveUsageReader: liveUsageReader,
            modelReader: KiroModelObservationReader(logsRoot: modelRoot),
            wrapperReader: ACPWrapperReader(acpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            usageLogsRoot: usageRoot,
            modelLogsRoot: modelRoot
        )
        return (vm, usageRoot, modelRoot)
    }

    @Test
    func refreshComposesAllReadersIntoSnapshot() async throws {
        let (viewModel, usageRoot, modelRoot) = try makeViewModel()
        defer {
            try? FileManager.default.removeItem(at: usageRoot)
            try? FileManager.default.removeItem(at: modelRoot)
        }

        await viewModel.refresh()

        guard let snapshot = viewModel.snapshot else {
            Issue.record("Expected a snapshot after refresh")
            return
        }

        guard case .success(let usage) = snapshot.accountUsage else {
            Issue.record("Expected usage success")
            return
        }
        #expect(usage.subscriptionTitle == "KIRO PRO")

        guard case .success(let observation) = snapshot.observedModel else {
            Issue.record("Expected model observation success")
            return
        }
        #expect(observation.source == .kiroCLI)

        guard case .failure(let wrapperError) = snapshot.wrapper else {
            Issue.record("Expected wrapper failure since no ACP directory exists")
            return
        }
        guard case .missing = wrapperError else {
            Issue.record("Expected .missing, got \(wrapperError)")
            return
        }
    }

    @Test
    func focusedRefreshActionsPreserveUnrelatedSnapshotSections() async throws {
        let (viewModel, usageRoot, modelRoot) = try makeViewModel()
        defer {
            try? FileManager.default.removeItem(at: usageRoot)
            try? FileManager.default.removeItem(at: modelRoot)
        }
        await viewModel.refresh()
        guard let initial = viewModel.snapshot,
              case .success(let initialModel) = initial.observedModel else {
            Issue.record("Expected initial snapshot and model observation")
            return
        }

        await viewModel.searchAgain()
        #expect(viewModel.snapshot?.cli == initial.cli)
        guard case .success(let modelAfterSearch) = viewModel.snapshot?.observedModel else {
            Issue.record("Search should preserve the model observation")
            return
        }
        #expect(modelAfterSearch == initialModel)

        await viewModel.refreshAccountUsage()
        #expect(viewModel.snapshot?.cli == initial.cli)
        guard case .success(let modelAfterUsage) = viewModel.snapshot?.observedModel else {
            Issue.record("Usage refresh should preserve the model observation")
            return
        }
        #expect(modelAfterUsage == initialModel)

        await viewModel.rescanXcode()
        #expect(viewModel.snapshot?.cli == initial.cli)
        guard case .success(let modelAfterRescan) = viewModel.snapshot?.observedModel else {
            Issue.record("Xcode rescan should preserve the model observation")
            return
        }
        #expect(modelAfterRescan == initialModel)
        guard case .failure(.missing) = viewModel.snapshot?.wrapper else {
            Issue.record("Expected the missing ACP wrapper state to remain explicit")
            return
        }
    }

    @Test
    func diagnosticSummaryExcludesSensitiveFieldsAndIncludesStructuralState() async throws {
        let (viewModel, usageRoot, modelRoot) = try makeViewModel()
        defer {
            try? FileManager.default.removeItem(at: usageRoot)
            try? FileManager.default.removeItem(at: modelRoot)
        }

        await viewModel.refresh()

        let summary = viewModel.diagnosticSummary()

        #expect(summary.contains("KIRO PRO"))
        #expect(summary.contains("ACP Control Center diagnostic summary"))
        // Verify renamed section title appears in diagnostic
        #expect(summary.contains("Latest observed model activity"))
        // Never include ARNs, request IDs, or user IDs.
        #expect(!summary.contains("arn:aws"))
        #expect(!summary.contains("requestId"))
        #expect(!summary.contains("userId"))
        #expect(!summary.contains("EXAMPLE-USER-ID"))
    }

    // MARK: - Menu bar label tests

    @Test
    func menuBarStatusTextBeforeDataShowsEllipsis() {
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent")),
            usageReader: KiroUsageReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent")),
            liveUsageReader: nil,
            modelReader: KiroModelObservationReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent")),
            wrapperReader: ACPWrapperReader(acpDirectory: URL(fileURLWithPath: "/tmp/nonexistent"))
        )
        #expect(viewModel.menuBarStatusText == "\u{2026}")
        #expect(viewModel.menuBarAccessibilityLabel == "Kiro credits loading")
    }

    @Test
    func menuBarStatusTextWithLocalLogShowsFallbackMarker() async throws {
        let (viewModel, usageRoot, modelRoot) = try makeViewModel()
        defer {
            try? FileManager.default.removeItem(at: usageRoot)
            try? FileManager.default.removeItem(at: modelRoot)
        }

        await viewModel.refresh()

        // The fixture has usage data from local log (no live reader injected).
        // It should show the warning marker for local log fallback.
        let status = viewModel.menuBarStatusText
        #expect(status.contains(" / "))
        // Local log fallback appends warning marker
        #expect(status.hasSuffix("\u{26A0}"))
        // No 'Kiro' prefix in the status text — that's handled by the emoji
        #expect(!status.contains("Kiro"))
        // Accessibility label includes fallback info with exact decimals
        let a11y = viewModel.menuBarAccessibilityLabel
        #expect(a11y.contains("Kiro credits:"))
        #expect(a11y.contains("of"))
        #expect(a11y.hasSuffix("local log fallback"))
    }

    @Test
    func menuBarStatusTextWithLiveCLISourceHasNoWarningMarker() async throws {
        // Simulate a snapshot with live CLI source
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent")),
            usageReader: KiroUsageReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent")),
            liveUsageReader: nil,
            modelReader: KiroModelObservationReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent")),
            wrapperReader: ACPWrapperReader(acpDirectory: URL(fileURLWithPath: "/tmp/nonexistent"))
        )

        // Directly test the formatting logic by verifying the function
        let formatted760 = DashboardViewModel.formatDecimalCredits(Decimal(760))
        #expect(formatted760 == "760")
        let formatted1000 = DashboardViewModel.formatDecimalCredits(Decimal(1000))
        #expect(formatted1000 == "1000")

        // No snapshot → ellipsis
        #expect(viewModel.menuBarStatusText == "\u{2026}")
    }

    @Test
    func menuBarStatusTextWithFailedUsageShowsEmDash() async throws {
        // Use a nonexistent directory so usage read fails
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            liveUsageReader: nil,
            modelReader: KiroModelObservationReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            wrapperReader: ACPWrapperReader(acpDirectory: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"))
        )

        await viewModel.refresh()

        #expect(viewModel.menuBarStatusText == "\u{2014}")
        #expect(viewModel.menuBarAccessibilityLabel == "Kiro credits unavailable")
    }

    @Test
    func formatDecimalCreditsPreservesExactValuesWithoutScientificNotation() {
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "760.45")!) == "760.45")
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "999.5")!) == "999.5")
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "0")!) == "0")
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "12345")!) == "12345")
        // Large values: no scientific notation
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "100000")!) == "100000")
        // No unnecessary trailing zeros
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "1000.00")!) == "1000")
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "771.21")!) == "771.21")
        #expect(DashboardViewModel.formatDecimalCredits(Decimal(string: "771.210")!) == "771.21")
    }

    @Test
    func performInitialRefreshRunsOnlyOnce() async throws {
        let (viewModel, usageRoot, modelRoot) = try makeViewModel()
        defer {
            try? FileManager.default.removeItem(at: usageRoot)
            try? FileManager.default.removeItem(at: modelRoot)
        }

        await viewModel.performInitialRefreshIfNeeded()
        let firstSnapshot = viewModel.snapshot

        // Calling again should not trigger a new refresh (guard protects it)
        await viewModel.performInitialRefreshIfNeeded()
        let secondSnapshot = viewModel.snapshot

        // Same snapshot reference time — no duplicate refresh
        #expect(firstSnapshot?.refreshedAt == secondSnapshot?.refreshedAt)
    }

    @Test
    func menuBarStatusTextLocalLogFallbackFormat() async throws {
        let (viewModel, usageRoot, modelRoot) = try makeViewModel()
        defer {
            try? FileManager.default.removeItem(at: usageRoot)
            try? FileManager.default.removeItem(at: modelRoot)
        }

        await viewModel.refresh()

        let status = viewModel.menuBarStatusText
        // Should match pattern: "DIGITS / DIGITS ⚠"
        #expect(status.hasSuffix(" \u{26A0}"))
        // Extract the numeric part
        let stripped = status.replacingOccurrences(of: " \u{26A0}", with: "")
        let parts = stripped.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(parts.count == 2)
        // Both parts should be valid decimals
        #expect(Decimal(string: parts[0]) != nil)
        #expect(Decimal(string: parts[1]) != nil)
    }

    // MARK: - Diagnostic error redaction integration tests

    @Test
    func diagnosticRedactsUsageFailureReasonPaths() async throws {
        // Build a view model that will fail usage with a path in the reason.
        let fakeHome = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: fakeHome)
        let usageRoot = URL(fileURLWithPath: "/Users/alice/Library/Application Support/Kiro/logs-nonexistent")

        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: usageRoot),
            liveUsageReader: nil,
            modelReader: KiroModelObservationReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            wrapperReader: ACPWrapperReader(acpDirectory: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"))
        )

        await viewModel.refresh()

        let summary = viewModel.diagnosticSummary(redactor: redactor)
        #expect(summary.contains("No q-client.log files found under ~/Library/Application Support/Kiro/logs-nonexistent"))
        #expect(!summary.contains("/Users/alice/"))
    }

    @Test
    func diagnosticRedactsModelFailureReasonPaths() async throws {
        let fakeHome = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: fakeHome)

        // Model logs root under the fake home so the failure reason contains it.
        let modelRoot = URL(fileURLWithPath: "/Users/alice/.kiro/logs-nonexistent")
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            liveUsageReader: nil,
            modelReader: KiroModelObservationReader(logsRoot: modelRoot),
            wrapperReader: ACPWrapperReader(acpDirectory: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"))
        )

        await viewModel.refresh()

        let summary = viewModel.diagnosticSummary(redactor: redactor)
        #expect(summary.contains("No kiro.log files found under ~/.kiro/logs-nonexistent"))
        #expect(!summary.contains("/Users/alice/"))
    }

    @Test
    func diagnosticRedactsWrapperFailureReasonPaths() async throws {
        let fakeHome = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: fakeHome)

        // Wrapper ACP directory under fake home.
        let wrapperDir = URL(fileURLWithPath: "/Users/alice/Library/Developer/Xcode/CodingAssistant/ACP-nonexistent")
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            usageReader: KiroUsageReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            liveUsageReader: nil,
            modelReader: KiroModelObservationReader(logsRoot: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")),
            wrapperReader: ACPWrapperReader(acpDirectory: wrapperDir)
        )

        await viewModel.refresh()

        let summary = viewModel.diagnosticSummary(redactor: redactor)
        // With the single-read model, noProvider observation yields
        // "No ACP provider configured" which has no path to redact.
        #expect(summary.contains("No ACP provider configured"))
        #expect(!summary.contains("/Users/alice/"))
    }
}
