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
        let preview = try manager.firstInstallPreview(makeRequest())

        let result = try manager.firstInstall(preview)

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
        // First install an ACC-owned wrapper, then replace it via general
        // install (which requires an existing ACC-owned target).
        let first = try manager.firstInstall(manager.firstInstallPreview(makeRequest(modelID: "model-one", effort: .low)))
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
        _ = try manager.firstInstall(manager.firstInstallPreview(makeRequest(modelID: "model-one")))
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
        let manager = ACPWrapperManager(managedRoot: root, syntaxValidator: { _ in false })
        let preview = try manager.firstInstallPreview(makeRequest())

        #expect(throws: ACPWrapperManagerError.syntaxValidationFailed) {
            try manager.firstInstall(preview)
        }
        #expect(!FileManager.default.fileExists(atPath: preview.wrapperURL.path))
    }

    @Test
    func failedPostWriteVerificationAutomaticallyRestoresBackup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Install a valid ACC-owned wrapper first.
        let manager = ACPWrapperManager(managedRoot: root)
        _ = try manager.firstInstall(manager.firstInstallPreview(makeRequest(modelID: "model-one")))
        let originalContent = try String(contentsOf: manager.wrapperURL, encoding: .utf8)

        // Replace it with a validator that fails only on the post-write check.
        // NOTE: the ownership guard inside install() also runs the validator
        // (for the destination file) before any temp-file validation, so the
        // failing call must be the LAST one. Pass a validator that returns
        // true until told otherwise.
        let validator = FailOnNthValidation(failAt: 3)
        let replacingManager = ACPWrapperManager(
            managedRoot: root,
            syntaxValidator: { _ in validator.validate() }
        )
        let preview = try replacingManager.preview(makeRequest(modelID: "model-two"))
        #expect(preview.existingContent == originalContent)

        #expect(throws: ACPWrapperManagerError.postWriteVerificationFailed) {
            try replacingManager.install(preview)
        }
        #expect(try String(contentsOf: manager.wrapperURL, encoding: .utf8) == originalContent)
    }

    @Test
    func stalePreviewCannotOverwriteExternallyChangedDestination() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        // Create an ACC-owned wrapper first, then take a preview that the
        // external process later mutates.
        _ = try manager.firstInstall(manager.firstInstallPreview(makeRequest(modelID: "model-one")))
        let preview = try manager.preview(makeRequest(modelID: "model-two"))
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

    @Test
    func installBlockedWhenManagedDestinationIsSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let preview = try manager.preview(makeRequest())
        try FileManager.default.createSymbolicLink(
            at: preview.wrapperURL,
            withDestinationURL: root.appendingPathComponent("real-wrapper.sh")
        )

        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.firstInstall(preview)
        }
    }

    @Test
    func firstInstallPreviewBlockedWhenTargetContainsAnyEntry() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        try "#!/bin/zsh\nexec '/old/kiro-cli' acp\n".write(to: wrapperURL, atomically: true, encoding: .utf8)

        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.firstInstallPreview(makeRequest())
        }
    }

    @Test
    func firstInstallRejectedWhenTargetAppearsAfterPreview() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let preview = try manager.preview(makeRequest())
        try "#!/bin/zsh\nexec '/old/kiro-cli' acp\n".write(to: preview.wrapperURL, atomically: true, encoding: .utf8)

        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.firstInstall(preview)
        }
    }

    @Test
    func firstInstallRejectsWhenDestinationExistsAsDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        try FileManager.default.createDirectory(at: wrapperURL, withIntermediateDirectories: true)

        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.firstInstallPreview(makeRequest())
        }
    }

    @Test
    func ancestorSymlinkRejectedForFirstInstall() throws {
        // A symlink anywhere between the managed root and the wrapper must
        // block installation so the wrapper cannot escape into the symlink
        // target while the UI claims the canonical path.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("managed")
        let realDir = root.appendingPathComponent("real-dir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: managedRoot,
            withDestinationURL: realDir
        )

        let manager = ACPWrapperManager(managedRoot: managedRoot)
        let preview = try manager.preview(makeRequest())

        do {
            try manager.firstInstall(preview)
            Issue.record("Expected ancestor symlink to be rejected")
        } catch ACPWrapperManagerError.ioFailure {
            // Expected
        } catch {
            Issue.record("Expected .ioFailure, got \(error)")
        }
        // The wrapper must NOT be created inside the symlink target.
        #expect(!FileManager.default.fileExists(
            atPath: realDir.appendingPathComponent("kiro-acp-xcode.sh").path
        ))
    }

    @Test
    func firstInstallUsesExclusiveCreateSemantics() throws {
        // A destination that appears between the final pre-check and the
        // write must be detected, not silently overwritten.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(
            managedRoot: root,
            beforeFirstInstallMove: {
                try "#!/bin/zsh\n# concurrent writer\n".write(
                    to: root.appendingPathComponent("kiro-acp-xcode.sh"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
        let preview = try manager.preview(makeRequest())

        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.firstInstall(preview)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("kiro-acp-xcode.sh"), encoding: .utf8)
            == "#!/bin/zsh\n# concurrent writer\n")
    }

    @Test
    func generalInstallRequiresExistingACCManagedWrapper() throws {
        // The retained general install path must refuse to replace a foreign
        // or non-ACC file at the canonical target.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        try "#!/bin/zsh\nexec '/foreign/kiro-cli' acp\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
        let manager = ACPWrapperManager(managedRoot: root)
        let preview = try manager.preview(makeRequest())

        do {
            try manager.install(preview)
            Issue.record("Expected general install to reject a foreign wrapper")
        } catch ACPWrapperManagerError.ioFailure {
            // Expected
        } catch {
            Issue.record("Expected .ioFailure, got \(error)")
        }
        #expect(try String(contentsOf: wrapperURL, encoding: .utf8) == "#!/bin/zsh\nexec '/foreign/kiro-cli' acp\n")
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
        #expect(viewModel.wrapperManagerStatus == .installed(modelID: "model-one", effort: "medium"))
        #expect(FileManager.default.fileExists(atPath: viewModel.managedWrapperURL.path))
        #expect(viewModel.lifecycleContext.state == .managedWrapperInactive)
    }

    // MARK: - Edit the managed wrapper

    @MainActor
    private func makeManagedViewModel(
        root: URL,
        managedRoot: URL
    ) async -> DashboardViewModel {
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
        try? cliScript.write(to: cliURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: cliURL.path
        )
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
        return viewModel
    }

    @Test @MainActor
    func viewModelEditsManagedWrapperModelAndEffort() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = await makeManagedViewModel(root: root, managedRoot: managedRoot)

        await viewModel.prepareWrapperPreview(modelID: "model-one", effort: .medium)
        await viewModel.installWrapperPreview()
        #expect(viewModel.lifecycleContext.state == .managedWrapperInactive)

        await viewModel.prepareEditPreview(modelID: "model-two", effort: .high)
        #expect(viewModel.wrapperManagerStatus == .previewReady)
        #expect(viewModel.wrapperPreview?.renderedContent.contains("--model 'model-two'") == true)
        #expect(viewModel.wrapperPreview?.renderedContent.contains("--effort 'high'") == true)

        await viewModel.installEditPreview()
        #expect(viewModel.wrapperManagerStatus == .installed(modelID: "model-two", effort: "high"))
        #expect(viewModel.managedWrapperExists)
        let installed = try String(contentsOf: viewModel.managedWrapperURL, encoding: .utf8)
        #expect(installed.contains("--model 'model-two'"))
        #expect(installed.contains("--effort 'high'"))
        // A backup of the previous version exists.
        #expect(!viewModel.recentBackups().isEmpty)
    }

    @Test @MainActor
    func viewModelEditRequiresExistingManagedWrapper() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = await makeManagedViewModel(root: root, managedRoot: managedRoot)

        // No managed wrapper exists yet → edit must be rejected.
        await viewModel.prepareEditPreview(modelID: "model-two", effort: .high)
        #expect(viewModel.wrapperManagerStatus != .previewReady)
    }

    // MARK: - Backup history & rollback

    @Test @MainActor
    func viewModelBackupHistoryListsAndRestoresBackup() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = await makeManagedViewModel(root: root, managedRoot: managedRoot)

        // Install v1, then edit to v2 → a backup of v1 exists.
        await viewModel.prepareWrapperPreview(modelID: "model-one", effort: .medium)
        await viewModel.installWrapperPreview()
        let v1Content = try String(contentsOf: viewModel.managedWrapperURL, encoding: .utf8)
        #expect(v1Content.contains("--model 'model-one'"))

        await viewModel.prepareEditPreview(modelID: "model-two", effort: .high)
        await viewModel.installEditPreview()
        let v2Content = try String(contentsOf: viewModel.managedWrapperURL, encoding: .utf8)
        #expect(v2Content.contains("--model 'model-two'"))

        // History lists the v1 backup.
        let history = viewModel.backupHistory
        #expect(!history.isEmpty)
        let backupOfV1 = try history.first {
            try String(contentsOf: $0, encoding: .utf8).contains("--model 'model-one'")
        }
        #expect(backupOfV1 != nil)

        // Restore v1 → the managed wrapper returns to v1.
        await viewModel.restoreBackup(backupOfV1!)
        #expect(viewModel.wrapperManagerStatus == .installed(modelID: nil, effort: nil))
        let restored = try String(contentsOf: viewModel.managedWrapperURL, encoding: .utf8)
        #expect(restored.contains("--model 'model-one'"))
        #expect(viewModel.managedWrapperExists)
    }

    // MARK: - Work Package B: migration of an unmanaged wrapper

    @Test
    func migratePreviewRendersACCFormatWithoutWriting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("manual-wrapper.sh")
        let sourceContent = """
        #!/bin/zsh
        # My manual wrapper
        exec '/bin/echo' acp --model 'claude-opus-4.6' --effort 'high'
        """
        try sourceContent.write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        let manager = ACPWrapperManager(managedRoot: root.appendingPathComponent("managed"))
        let preview = try manager.migratePreview(from: source)

        // The preview is re-rendered into the ACC canonical format, not a
        // literal copy: it carries the ownership marker and the strict
        // 7-line structure, and preserves the source's CLI/model/effort.
        #expect(preview.renderedContent.contains("#!/bin/zsh"))
        #expect(preview.renderedContent.contains(ACPWrapperManager.ownershipMarker))
        #expect(preview.renderedContent.contains("exec '/bin/echo' acp --model 'claude-opus-4.6' --effort 'high'"))
        #expect(preview.existingContent == nil)
        // No file is written by preview.
        #expect(!FileManager.default.fileExists(atPath: preview.wrapperURL.path))
        // The source is untouched.
        #expect(try String(contentsOf: source, encoding: .utf8) == sourceContent)
    }

    @Test
    func migrateInstallWritesACCFormatAndLeavesSourceIntact() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("manual-wrapper.sh")
        let sourceContent = """
        #!/bin/zsh
        # My manual wrapper
        exec '/bin/echo' acp
        """
        try sourceContent.write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        let manager = ACPWrapperManager(managedRoot: root.appendingPathComponent("managed"))
        let preview = try manager.migratePreview(from: source)
        let result = try manager.migrateInstall(preview)

        #expect(result.wrapperURL == manager.wrapperURL)
        // The managed wrapper is the ACC-rendered format (marker + exec line),
        // not a literal copy, and passes full ownership validation.
        let installed = try String(contentsOf: manager.wrapperURL, encoding: .utf8)
        #expect(installed.contains(ACPWrapperManager.ownershipMarker))
        #expect(installed.contains("exec '/bin/echo' acp"))
        #expect(manager.managedWrapperExists)
        // The managed wrapper is executable.
        #expect(FileManager.default.isExecutableFile(atPath: manager.wrapperURL.path))
        // The source is untouched.
        #expect(try String(contentsOf: source, encoding: .utf8) == sourceContent)
    }

    @Test
    func migratePreviewRejectsWhenManagedDestinationNotEmpty() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("manual-wrapper.sh")
        try "#!/bin/zsh\nexec '/bin/echo' acp\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        // Pre-create the managed destination with a foreign file.
        let managedRoot = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let managedWrapper = managedRoot.appendingPathComponent("kiro-acp-xcode.sh")
        try "#!/bin/zsh\necho foreign\n".write(to: managedWrapper, atomically: true, encoding: .utf8)

        let manager = ACPWrapperManager(managedRoot: managedRoot)
        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.migratePreview(from: source)
        }
    }

    @Test
    func migrateInstallRejectsSymlinkAtManagedDestination() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("manual-wrapper.sh")
        try "#!/bin/zsh\nexec '/bin/echo' acp\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        let managedRoot = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("some-target.sh")
        try "#!/bin/zsh\n".write(to: target, atomically: true, encoding: .utf8)
        // Symlink at the managed destination.
        let managedWrapper = managedRoot.appendingPathComponent("kiro-acp-xcode.sh")
        try FileManager.default.createSymbolicLink(at: managedWrapper, withDestinationURL: target)

        let manager = ACPWrapperManager(managedRoot: managedRoot)
        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.migratePreview(from: source)
        }
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

/// Returns true for the first (n-1) calls and false on the n-th call.
private final class FailOnNthValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failAt: Int

    init(failAt: Int) {
        self.failAt = failAt
    }

    func validate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count != failAt
    }
}
