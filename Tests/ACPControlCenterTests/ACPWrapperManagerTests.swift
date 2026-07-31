import Foundation
import Testing
@testable import ACPControlCenter

struct ACPWrapperManagerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPWrapperManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRequest(
        modelID: String? = "claude-opus-4.6",
        effort: ACPWrapperEffort? = .high
    ) -> ACPWrapperRequest {
        ACPWrapperRequest(
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: modelID,
            effort: effort
        )
    }

    @Test
    func previewRendersStructuredWrapperWithoutWriting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)

        let preview = try manager.preview(makeRequest())

        #expect(!FileManager.default.fileExists(atPath: preview.wrapperURL.path))
        #expect(preview.renderedContent.contains("#!/bin/zsh"))
        #expect(preview.renderedContent.contains("export HOME='/Users/"))
        #expect(preview.renderedContent.contains(
            "exec '/bin/echo' acp --model 'claude-opus-4.6' --effort 'high'"
        ))
        #expect(preview.existingContent == nil)
    }

    @Test
    func invalidModelIDIsRejectedBeforePreview() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)

        #expect(throws: ACPWrapperManagerError.invalidModelID) {
            try manager.preview(makeRequest(modelID: "model\nexec bad"))
        }
    }

    @Test
    func unavailableCLIExecutableIsRejectedBeforePreview() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let request = ACPWrapperRequest(
            cliExecutableURL: root.appendingPathComponent("missing-kiro-cli"),
            modelID: nil,
            effort: nil
        )

        #expect(throws: ACPWrapperManagerError.invalidExecutablePath) {
            try manager.preview(request)
        }
    }

    @Test
    func installCreatesPrivateExecutableWrapperThatReaderCanParse() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let preview = try manager.preview(makeRequest())

        let result = try manager.install(preview)

        #expect(result.wrapperURL == preview.wrapperURL)
        #expect(result.backupURL == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: result.wrapperURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let parsed = ACPWrapperReader().readWrapperConfiguration(atWrapperURL: result.wrapperURL)
        guard case .success(let configuration) = parsed else {
            Issue.record("Expected installed wrapper to be readable")
            return
        }
        #expect(configuration.modelID == "claude-opus-4.6")
        #expect(configuration.effort == "high")
        #expect(configuration.syntaxIsValid)
    }

    @Test
    func replacingWrapperCreatesBackupAndRollbackRestoresIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(
            managedRoot: root,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let first = try manager.install(manager.preview(makeRequest(modelID: "model-one", effort: .low)))
        let originalContent = try String(contentsOf: first.wrapperURL, encoding: .utf8)

        let second = try manager.install(manager.preview(makeRequest(modelID: "model-two", effort: .max)))
        let backupURL = try #require(second.backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        #expect((backupAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try String(contentsOf: second.wrapperURL, encoding: .utf8) != originalContent)

        try manager.rollback(backupURL: backupURL, wrapperURL: second.wrapperURL)

        #expect(try String(contentsOf: second.wrapperURL, encoding: .utf8) == originalContent)
        let attributes = try FileManager.default.attributesOfItem(atPath: second.wrapperURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test
    func invalidBackupCannotReplaceCurrentManagedWrapper() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        _ = try manager.install(manager.preview(makeRequest(modelID: "model-one")))
        let second = try manager.install(manager.preview(makeRequest(modelID: "model-two")))
        let backupURL = try #require(second.backupURL)
        let currentContent = try String(contentsOf: second.wrapperURL, encoding: .utf8)
        try "if then\n".write(to: backupURL, atomically: true, encoding: .utf8)

        #expect(throws: ACPWrapperManagerError.syntaxValidationFailed) {
            try manager.rollback(backupURL: backupURL, wrapperURL: second.wrapperURL)
        }
        #expect(try String(contentsOf: second.wrapperURL, encoding: .utf8) == currentContent)
    }

    @Test
    func failedSyntaxValidationLeavesExistingWrapperUntouched() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        let originalContent = "#!/bin/zsh\nexec '/old/kiro-cli' acp\n"
        try originalContent.write(to: wrapperURL, atomically: true, encoding: .utf8)
        let manager = ACPWrapperManager(managedRoot: root, syntaxValidator: { _ in false })
        let preview = try manager.preview(makeRequest())

        #expect(throws: ACPWrapperManagerError.syntaxValidationFailed) {
            try manager.install(preview)
        }
        #expect(try String(contentsOf: wrapperURL, encoding: .utf8) == originalContent)
    }

    @Test
    func failedPostWriteVerificationAutomaticallyRestoresBackup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        let originalContent = "#!/bin/zsh\nexec '/old/kiro-cli' acp\n"
        try originalContent.write(to: wrapperURL, atomically: true, encoding: .utf8)
        let validator = FirstValidationOnly()
        let manager = ACPWrapperManager(
            managedRoot: root,
            syntaxValidator: { _ in validator.validate() }
        )
        let preview = try manager.preview(makeRequest())

        #expect(throws: ACPWrapperManagerError.postWriteVerificationFailed) {
            try manager.install(preview)
        }
        #expect(try String(contentsOf: wrapperURL, encoding: .utf8) == originalContent)
    }

    @Test
    func stalePreviewCannotOverwriteExternallyChangedDestination() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let preview = try manager.preview(makeRequest())
        try "external change".write(to: preview.wrapperURL, atomically: true, encoding: .utf8)

        #expect(throws: ACPWrapperManagerError.destinationChanged) {
            try manager.install(preview)
        }
    }

    @Test
    func rollbackRejectsBackupOutsideManagedBackupDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).sh")
        try "#!/bin/zsh\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let manager = ACPWrapperManager(managedRoot: root)

        #expect(throws: ACPWrapperManagerError.unmanagedBackup) {
            try manager.rollback(
                backupURL: outside,
                wrapperURL: root.appendingPathComponent("kiro-acp-xcode.sh")
            )
        }
    }

    @Test @MainActor
    func viewModelRequiresPreviewThenInstallsManagedWrapper() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = root.appendingPathComponent("kiro-cli")
        let cliScript = """
        #!/bin/zsh
        if [[ "$1" == "--version" ]]; then
          print "kiro-cli 9.9.9"
        else
          print "Estimated Usage | resets on 2026-08-01 | KIRO PRO"
          print "Credits (1 of 100 covered in plan)"
        fi
        """
        try cliScript.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: cliURL.path
        )
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: cliURL),
            usageReader: KiroUsageReader(logsRoot: root.appendingPathComponent("usage")),
            modelReader: KiroModelObservationReader(logsRoot: root.appendingPathComponent("model")),
            wrapperReader: ACPWrapperReader(acpDirectory: root.appendingPathComponent("xcode")),
            wrapperManager: ACPWrapperManager(managedRoot: managedRoot),
            usageLogsRoot: root.appendingPathComponent("usage"),
            modelLogsRoot: root.appendingPathComponent("model")
        )
        await viewModel.refresh()

        await viewModel.prepareWrapperPreview(modelID: "model-one", effort: .medium)
        #expect(viewModel.wrapperManagerStatus == .previewReady)
        #expect(!FileManager.default.fileExists(atPath: viewModel.managedWrapperURL.path))

        await viewModel.installWrapperPreview()
        #expect(viewModel.wrapperManagerStatus == .installed)
        #expect(FileManager.default.fileExists(atPath: viewModel.managedWrapperURL.path))
    }
}

private final class FirstValidationOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func validate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count == 1
    }
}
