import Foundation
import Testing
@testable import ACPControlCenter

struct KiroCLIDiscoveryIntegrationTests {
    @Test @MainActor
    func choosingExecutablePersistsPathAndDrivesLiveUsage() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptURL = tmpDir.appendingPathComponent("custom-kiro-cli")
        let scriptContent = """
        #!/bin/bash
        if [ "$1" = "--version" ]; then
          echo "kiro-cli 3.2.1"
          exit 0
        fi
        echo "Estimated Usage | resets on 2026-08-01 | KIRO PRO"
        echo "Credits (321.5 of 1000 covered in plan)"
        """
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let suiteName = "KiroCLIDiscoveryIntegrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selectionStore = KiroCLISelectionStore(userDefaults: defaults)
        let emptyRoot = tmpDir.appendingPathComponent("empty")
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(candidateURLs: []),
            usageReader: KiroUsageReader(logsRoot: emptyRoot),
            modelReader: KiroModelObservationReader(logsRoot: emptyRoot),
            wrapperReader: ACPWrapperReader(acpDirectory: emptyRoot),
            cliSelectionStore: selectionStore,
            usageLogsRoot: emptyRoot,
            modelLogsRoot: emptyRoot
        )

        await viewModel.chooseExecutable(scriptURL)

        #expect(selectionStore.load() == scriptURL)
        #expect(viewModel.snapshot?.cli.executableURL == scriptURL)
        #expect(viewModel.snapshot?.cli.discoverySource == .selected)
        #expect(viewModel.snapshot?.cli.version == "3.2.1")
        #expect(viewModel.liveUsageStatus == .ready)
        guard case .success(let usage) = viewModel.snapshot?.accountUsage else {
            Issue.record("Expected live usage after choosing the executable")
            return
        }
        #expect(usage.used == Decimal(string: "321.5"))
        #expect(usage.source == .liveCLI)
    }
}
