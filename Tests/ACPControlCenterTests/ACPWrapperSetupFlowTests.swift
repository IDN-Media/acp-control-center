import Foundation
import Testing
@testable import ACPControlCenter

/// Integration tests for the lifecycle-aware wrapper setup flow, exercising
/// the full ViewModel state machine with injected temporary paths.
@MainActor
struct ACPWrapperSetupFlowTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPSetupFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCLI(in root: URL) throws -> URL {
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
        return cliURL
    }

    private func makeViewModel(
        root: URL,
        cliURL: URL,
        managedRoot: URL,
        acpDirectory: URL? = nil
    ) -> DashboardViewModel {
        DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: cliURL),
            usageReader: KiroUsageReader(logsRoot: root.appendingPathComponent("usage")),
            modelReader: KiroModelObservationReader(logsRoot: root.appendingPathComponent("model")),
            wrapperReader: ACPWrapperReader(acpDirectory: acpDirectory ?? root.appendingPathComponent("xcode")),
            wrapperManager: ACPWrapperManager(managedRoot: managedRoot),
            usageLogsRoot: root.appendingPathComponent("usage"),
            modelLogsRoot: root.appendingPathComponent("model")
        )
    }

    // MARK: - First-time preview does not write

    @Test
    func previewDoesNotCreateFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()
        await viewModel.prepareWrapperPreview(modelID: "test-model", effort: .high)

        #expect(viewModel.wrapperManagerStatus == .previewReady)
        #expect(!FileManager.default.fileExists(atPath: viewModel.managedWrapperURL.path))
        #expect(!FileManager.default.fileExists(atPath: managedRoot.path))
    }

    // MARK: - Install without preview fails without writing

    @Test
    func installWithoutPreviewFailsWithoutWriting() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()
        await viewModel.installWrapperPreview()

        guard case .failed = viewModel.wrapperManagerStatus else {
            Issue.record("Expected failed status, got \(viewModel.wrapperManagerStatus)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: viewModel.managedWrapperURL.path))
    }

    // MARK: - Setup installs exact managed target and transitions

    @Test
    func setupInstallsAndTransitionsToInactive() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()
        #expect(viewModel.lifecycleContext.state == .noProvider)

        await viewModel.prepareWrapperPreview(modelID: "claude-opus-4.6", effort: .high)
        #expect(viewModel.wrapperManagerStatus == .previewReady)

        await viewModel.installWrapperPreview()
        #expect(viewModel.wrapperManagerStatus == .installed(modelID: "claude-opus-4.6", effort: "high"))
        #expect(FileManager.default.fileExists(atPath: viewModel.managedWrapperURL.path))
        #expect(viewModel.managedWrapperExists == true)
        #expect(viewModel.lifecycleContext.state == .managedWrapperInactive)
    }

    // MARK: - Simulated Xcode rescan transitions to managedWrapperActive

    @Test
    func rescanXcodePointingToManagedTransitionsToActive() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let acpDirectory = root.appendingPathComponent("xcode-acp")
        try FileManager.default.createDirectory(at: acpDirectory, withIntermediateDirectories: true)

        let viewModel = makeViewModel(
            root: root, cliURL: cliURL, managedRoot: managedRoot, acpDirectory: acpDirectory
        )

        await viewModel.refresh()
        await viewModel.prepareWrapperPreview(modelID: nil, effort: nil)
        await viewModel.installWrapperPreview()
        #expect(viewModel.lifecycleContext.state == .managedWrapperInactive)

        let plistURL = acpDirectory.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": viewModel.managedWrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDict, format: .xml, options: 0
        )
        try data.write(to: plistURL)

        await viewModel.rescanXcode()
        #expect(viewModel.lifecycleContext.state == .managedWrapperActive)
    }

    // MARK: - No startup/refresh/rescan writes

    @Test
    func refreshDoesNotWriteAnything() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()
        await viewModel.refresh()
        await viewModel.rescanXcode()
        await viewModel.searchAgain()

        #expect(!FileManager.default.fileExists(atPath: managedRoot.path))
    }

    // MARK: - Generated wrapper round-trips through ACPWrapperReader

    @Test
    func generatedWrapperRoundTripsThroughReader() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let request = ACPWrapperRequest(
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: "claude-opus-4.6",
            effort: .high
        )
        let preview = try manager.preview(request)
        _ = try manager.install(preview)

        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: manager.wrapperURL)
        guard case .success(let config) = result else {
            Issue.record("Expected wrapper to be parseable: \(result)")
            return
        }
        #expect(config.cliExecutableURL?.path == "/bin/echo")
        #expect(config.modelID == "claude-opus-4.6")
        #expect(config.effort == "high")
        #expect(config.syntaxIsValid == true)
        #expect(config.isExecutable == true)
    }

    // MARK: - Nil model/effort emits no flags

    @Test
    func nilModelAndEffortEmitsNoFlags() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let request = ACPWrapperRequest(
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil
        )
        let preview = try manager.preview(request)
        #expect(!preview.renderedContent.contains("--model"))
        #expect(!preview.renderedContent.contains("--effort"))
        #expect(preview.renderedContent.contains("exec '/bin/echo' acp"))
    }

    // MARK: - Executable paths with spaces and quotes

    @Test
    func executablePathWithSpacesIsQuotedAndParseable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let spacedDir = root.appendingPathComponent("App With Spaces.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: spacedDir, withIntermediateDirectories: true)
        let cliURL = spacedDir.appendingPathComponent("kiro-cli")
        try "#!/bin/zsh\necho ok".write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: cliURL.path
        )

        let manager = ACPWrapperManager(managedRoot: root)
        let request = ACPWrapperRequest(
            cliExecutableURL: cliURL,
            modelID: nil,
            effort: nil
        )
        let preview = try manager.preview(request)
        _ = try manager.install(preview)

        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: manager.wrapperURL)
        guard case .success(let config) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(config.cliExecutableURL?.path == cliURL.path)
        #expect(config.syntaxIsValid == true)
    }

    @Test
    func executablePathWithSingleQuoteIsQuotedAndParseable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let quotedDir = root.appendingPathComponent("User's Apps/bin")
        try FileManager.default.createDirectory(at: quotedDir, withIntermediateDirectories: true)
        let cliURL = quotedDir.appendingPathComponent("kiro-cli")
        try "#!/bin/zsh\necho ok".write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: cliURL.path
        )

        let manager = ACPWrapperManager(managedRoot: root)
        let request = ACPWrapperRequest(
            cliExecutableURL: cliURL,
            modelID: nil,
            effort: nil
        )
        let preview = try manager.preview(request)
        _ = try manager.install(preview)

        let reader = ACPWrapperReader()
        let result = reader.readWrapperConfiguration(atWrapperURL: manager.wrapperURL)
        guard case .success(let config) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(config.cliExecutableURL?.path == cliURL.path)
        #expect(config.syntaxIsValid == true)
    }

    // MARK: - Ownership marker

    @Test
    func generatedWrapperContainsOwnershipMarker() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(managedRoot: root)
        let request = ACPWrapperRequest(
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil
        )
        let preview = try manager.preview(request)
        #expect(preview.renderedContent.contains(ACPWrapperManager.ownershipMarker))
    }

    // MARK: - Unmanaged states expose no write operation

    @Test
    func unmanagedActiveLifecycleDoesNotAllowWrapperSetup() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let otherURL = URL(fileURLWithPath: "/tmp/other/wrapper.sh")
        let config = ACPWrapperConfiguration(
            wrapperURL: otherURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil,
            isExecutable: true,
            syntaxIsValid: true
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: .absent,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .unmanagedWrapperActive)
    }

    @Test
    func unmanagedInvalidLifecycleDoesNotAllowWrapperSetup() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let otherURL = URL(fileURLWithPath: "/tmp/other/wrapper.sh")
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperInvalid(wrapperURL: otherURL, reason: "not executable"),
            managedFileInfo: .absent,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .unmanagedWrapperInvalid)
    }

    // MARK: - Authorization enforcement integration tests

    @Test
    func prepareBlockedInUnmanagedActiveState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let acpDirectory = root.appendingPathComponent("xcode-acp")
        try FileManager.default.createDirectory(at: acpDirectory, withIntermediateDirectories: true)

        // Create a valid unmanaged wrapper
        let unmanagedWrapper = root.appendingPathComponent("unmanaged-wrapper.sh")
        try "#!/bin/zsh\nexec '/bin/echo' acp\n".write(to: unmanagedWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: unmanagedWrapper.path
        )
        let plistURL = acpDirectory.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": unmanagedWrapper.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot, acpDirectory: acpDirectory)
        await viewModel.refresh()
        #expect(viewModel.lifecycleContext.state == .unmanagedWrapperActive)

        // Attempt setup — must fail
        await viewModel.prepareWrapperPreview(modelID: "test", effort: .high)
        guard case .failed(let msg) = viewModel.wrapperManagerStatus else {
            Issue.record("Expected failed, got \(viewModel.wrapperManagerStatus)")
            return
        }
        #expect(msg.contains("not available"))
        // No filesystem changes
        #expect(!FileManager.default.fileExists(atPath: managedRoot.path))
    }

    @Test
    func prepareBlockedInManagedActiveState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let acpDirectory = root.appendingPathComponent("xcode-acp")
        try FileManager.default.createDirectory(at: acpDirectory, withIntermediateDirectories: true)

        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot, acpDirectory: acpDirectory)

        // Do initial setup to get a managed wrapper installed
        await viewModel.refresh()
        await viewModel.prepareWrapperPreview(modelID: nil, effort: nil)
        await viewModel.installWrapperPreview()

        // Point Xcode at it
        let plistURL = acpDirectory.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": viewModel.managedWrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)
        await viewModel.rescanXcode()
        #expect(viewModel.lifecycleContext.state == .managedWrapperActive)

        // Attempting another setup must fail (managed wrapper already active)
        await viewModel.prepareWrapperPreview(modelID: "new-model", effort: .max)
        guard case .failed(let msg) = viewModel.wrapperManagerStatus else {
            Issue.record("Expected failed, got \(viewModel.wrapperManagerStatus)")
            return
        }
        #expect(msg.contains("not available"))
    }

    @Test
    func installBlockedWhenManagedDestinationAlreadyExists() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()
        #expect(viewModel.lifecycleContext.state == .noProvider)

        // Preview first (should succeed since managed dest doesn't exist yet)
        await viewModel.prepareWrapperPreview(modelID: "model-one", effort: .high)
        #expect(viewModel.wrapperManagerStatus == .previewReady)

        // Now externally create the managed wrapper (simulates race condition)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let wrapperURL = managedRoot.appendingPathComponent("kiro-acp-xcode.sh")
        try "#!/bin/zsh\nexec '/bin/echo' acp\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: wrapperURL.path
        )

        // Install must fail because destination now exists
        await viewModel.installWrapperPreview()
        guard case .failed(let msg) = viewModel.wrapperManagerStatus else {
            Issue.record("Expected failed, got \(viewModel.wrapperManagerStatus)")
            return
        }
        #expect(msg.contains("already exists") || msg.contains("not available") || msg.contains("not absent"))
    }

    @Test
    func installBlockedWhenManagedDestinationIsSymlink() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()
        await viewModel.prepareWrapperPreview(modelID: nil, effort: nil)
        #expect(viewModel.wrapperManagerStatus == .previewReady)

        // Create a symlink at the managed wrapper destination
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let wrapperURL = managedRoot.appendingPathComponent("kiro-acp-xcode.sh")
        let targetURL = root.appendingPathComponent("some-target.sh")
        try "#!/bin/zsh\n".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: wrapperURL, withDestinationURL: targetURL)

        // Install must fail (symlink counts as existing entry)
        await viewModel.installWrapperPreview()
        guard case .failed(let msg) = viewModel.wrapperManagerStatus else {
            Issue.record("Expected failed, got \(viewModel.wrapperManagerStatus)")
            return
        }
        #expect(msg.contains("already exists") || msg.contains("not available") || msg.contains("not empty"))
    }

    @Test
    func prepareBlockedWhenCLINotReady() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("managed")
        // Use a nonexistent CLI so it's not ready
        let viewModel = DashboardViewModel(
            cliResolver: KiroCLIResolver(executableURL: root.appendingPathComponent("nonexistent-cli")),
            usageReader: KiroUsageReader(logsRoot: root.appendingPathComponent("usage")),
            modelReader: KiroModelObservationReader(logsRoot: root.appendingPathComponent("model")),
            wrapperReader: ACPWrapperReader(acpDirectory: root.appendingPathComponent("xcode")),
            wrapperManager: ACPWrapperManager(managedRoot: managedRoot),
            usageLogsRoot: root.appendingPathComponent("usage"),
            modelLogsRoot: root.appendingPathComponent("model")
        )
        await viewModel.refresh()
        #expect(viewModel.snapshot?.cli.availability != .ready)

        await viewModel.prepareWrapperPreview(modelID: nil, effort: nil)
        guard case .failed(let msg) = viewModel.wrapperManagerStatus else {
            Issue.record("Expected failed, got \(viewModel.wrapperManagerStatus)")
            return
        }
        #expect(msg.contains("CLI") || msg.contains("ready"))
        #expect(!FileManager.default.fileExists(atPath: managedRoot.path))
    }

    // MARK: - No observed model prefill

    @Test
    func wrapperManagerViewDoesNotPrefillFromObservedModel() async throws {
        // This is a unit-level check: ACPWrapperManagerView init must not
        // use observed model. We verify by checking the ViewModel does not
        // inject observed model into the wrapper when no modelID is provided.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()

        // Preview with nil (empty string in UI = nil) to ensure no model
        // is prefilled from observation
        await viewModel.prepareWrapperPreview(modelID: nil, effort: nil)
        #expect(viewModel.wrapperManagerStatus == .previewReady)
        guard let preview = viewModel.wrapperPreview else {
            Issue.record("Expected preview")
            return
        }
        // The rendered wrapper must NOT contain --model
        #expect(!preview.renderedContent.contains("--model"))
    }

    // MARK: - Managed artifact presence detection

    @Test
    func nonExecutableFileAtManagedPathBlocksFirstInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedArtifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        // Non-executable file
        try "#!/bin/zsh\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: wrapperURL.path
        )

        let info = ManagedWrapperFileInfo.read(at: wrapperURL)
        #expect(info.entryExists == true)
        #expect(info.isSymbolicLink == false)
        #expect(info.isExecutableRegularFile == false)
        // Not safe for first install because something is there
        #expect(info.isAbsentAndSafe == false)
        // Not a valid managed wrapper
        #expect(info.isValidManagedWrapper == false)
    }

    // MARK: - First-install race regression tests

    @Test
    func firstInstallPreviewBlockedWhenTargetContainsAnyEntry() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let wrapperURL = managedRoot.appendingPathComponent("kiro-acp-xcode.sh")
        // Create a foreign file at the managed target
        try "#!/bin/zsh\necho foreign\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: wrapperURL.path
        )

        let manager = ACPWrapperManager(managedRoot: managedRoot)
        let request = ACPWrapperRequest(
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil
        )
        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.firstInstallPreview(request)
        }
    }

    @Test
    func firstInstallRejectedWhenTargetAppearsAfterPreview() throws {
        // Target appears between preview and install => install rejected,
        // existing bytes unchanged
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("managed")
        let manager = ACPWrapperManager(managedRoot: managedRoot)
        let request = ACPWrapperRequest(
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: "test-model",
            effort: .high
        )
        // Preview succeeds (target absent)
        let preview = try manager.firstInstallPreview(request)

        // Simulate race: another process creates a file at the target
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let foreignContent = "#!/bin/zsh\necho race-winner\n"
        try foreignContent.write(to: manager.wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: manager.wrapperURL.path
        )

        // Install must fail
        #expect(throws: ACPWrapperManagerError.firstInstallDestinationNotEmpty) {
            try manager.firstInstall(preview)
        }
        // Existing bytes remain unchanged
        let currentContent = try String(contentsOf: manager.wrapperURL, encoding: .utf8)
        #expect(currentContent == foreignContent)
    }

    @Test
    func firstInstallViewModelRejectedWhenTargetAppearsAfterPreview() async throws {
        // Integration test: ViewModel preview + external appearance => install fails
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliURL = try makeCLI(in: root)
        let managedRoot = root.appendingPathComponent("managed")
        let viewModel = makeViewModel(root: root, cliURL: cliURL, managedRoot: managedRoot)

        await viewModel.refresh()
        #expect(viewModel.lifecycleContext.state == .noProvider)

        // Preview succeeds
        await viewModel.prepareWrapperPreview(modelID: "model-one", effort: .high)
        #expect(viewModel.wrapperManagerStatus == .previewReady)

        // External race: file appears at managed target
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let wrapperURL = managedRoot.appendingPathComponent("kiro-acp-xcode.sh")
        let foreignContent = "#!/bin/zsh\necho appeared-after-preview\n"
        try foreignContent.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: wrapperURL.path
        )

        // Install must fail at ViewModel level (authorization re-check)
        await viewModel.installWrapperPreview()
        guard case .failed(let msg) = viewModel.wrapperManagerStatus else {
            Issue.record("Expected failed, got \(viewModel.wrapperManagerStatus)")
            return
        }
        #expect(msg.contains("already exists") || msg.contains("not available") || msg.contains("not empty"))

        // Foreign bytes remain unchanged
        let currentContent = try String(contentsOf: wrapperURL, encoding: .utf8)
        #expect(currentContent == foreignContent)
    }
}
