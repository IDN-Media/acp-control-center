import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for the structured provider observation and lifecycle classification.
struct ACPProviderLifecycleTests {
    // MARK: - Structured reader: observeProvider

    @Test
    func noProviderWhenNoPlistExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ACPWrapperReader(acpDirectory: root)
        let observation = reader.readProviderObservation()

        #expect(observation == .noProvider)
    }

    @Test
    func configuredPathMissingWhenPlistReferencesAbsentFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingPath = "/tmp/does-not-exist-\(UUID().uuidString).sh"
        let plistURL = root.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": missingPath,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let reader = ACPWrapperReader(acpDirectory: root)
        let observation = reader.readProviderObservation()

        guard case .configuredPathMissing(let configuredPath) = observation else {
            Issue.record("Expected .configuredPathMissing, got \(observation)")
            return
        }
        #expect(configuredPath.path == missingPath)
    }

    // MARK: - Reader error classification

    @Test
    func existingButUnreadableFileIsWrapperInvalidNotMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wrapperDir) }
        let wrapperURL = wrapperDir.appendingPathComponent("wrapper.sh")
        // Write a file then make it unreadable
        try "#!/bin/zsh\nexec '/bin/echo' acp\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: wrapperURL.path
        )

        let plistURL = root.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": wrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let reader = ACPWrapperReader(acpDirectory: root)
        let observation = reader.readProviderObservation()

        // Must be wrapperInvalid, NOT configuredPathMissing
        guard case .wrapperInvalid(let obsURL, let reason) = observation else {
            Issue.record("Expected .wrapperInvalid, got \(observation)")
            // Restore permissions for cleanup
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: wrapperURL.path
            )
            return
        }
        #expect(obsURL == wrapperURL)
        #expect(reason.contains("cannot be read"))

        // Restore permissions for cleanup
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: wrapperURL.path
        )
    }

    @Test
    func directoryAtWrapperPathIsWrapperInvalid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wrapperDir) }
        // The "wrapper" path is actually a directory
        let wrapperURL = wrapperDir.appendingPathComponent("wrapper.sh")
        try FileManager.default.createDirectory(at: wrapperURL, withIntermediateDirectories: true)

        let plistURL = root.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": wrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let reader = ACPWrapperReader(acpDirectory: root)
        let observation = reader.readProviderObservation()

        guard case .wrapperInvalid(_, let reason) = observation else {
            Issue.record("Expected .wrapperInvalid, got \(observation)")
            return
        }
        #expect(reason.contains("directory"))
    }

    @Test
    func wrapperInvalidWhenNotExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wrapperDir) }
        let wrapperURL = wrapperDir.appendingPathComponent("wrapper.sh")
        let content = "#!/bin/zsh\nexec '/bin/echo' acp\n"
        try content.write(to: wrapperURL, atomically: true, encoding: .utf8)
        // Don't set executable permission

        let plistURL = root.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": wrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let reader = ACPWrapperReader(acpDirectory: root)
        let observation = reader.readProviderObservation()

        guard case .wrapperInvalid(let obsURL, _) = observation else {
            Issue.record("Expected .wrapperInvalid, got \(observation)")
            return
        }
        #expect(obsURL == wrapperURL)
    }

    @Test
    func wrapperValidWhenExecutableAndSyntaxOK() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wrapperDir) }
        let wrapperURL = wrapperDir.appendingPathComponent("wrapper.sh")
        let content = "#!/bin/zsh\nexec '/bin/echo' acp --model 'test-model'\n"
        try content.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: wrapperURL.path
        )

        let plistURL = root.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": wrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let reader = ACPWrapperReader(acpDirectory: root)
        let observation = reader.readProviderObservation()

        guard case .wrapperValid(let config) = observation else {
            Issue.record("Expected .wrapperValid, got \(observation)")
            return
        }
        #expect(config.modelID == "test-model")
    }

    // MARK: - Lifecycle classifications

    /// Helper to construct valid managed file info for classifier tests
    private static func validManagedFileInfo() -> ManagedWrapperFileInfo {
        ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: true,
            parsesAsACPInvocation: true,
            passesSyntaxValidation: true,
            invalidReason: nil
        )
    }

    @Test
    func noProviderWithNoManagedWrapper() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .noProvider,
            managedFileInfo: .absent,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .noProvider)
    }

    @Test
    func noProviderWithManagedWrapperExistsBecomesManagedInactive() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .noProvider,
            managedFileInfo: Self.validManagedFileInfo(),
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInactive)
    }

    @Test
    func configuredPathMissingWithNoManagedWrapper() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let configuredPath = URL(fileURLWithPath: "/some/other/path.sh")
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .configuredPathMissing(configuredPath: configuredPath),
            managedFileInfo: .absent,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .configuredPathMissing)
        #expect(result.configuredPath == configuredPath)
    }

    @Test
    func configuredPathMissingWithManagedWrapperExistsBecomesManagedInactive() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let configuredPath = URL(fileURLWithPath: "/some/other/path.sh")
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .configuredPathMissing(configuredPath: configuredPath),
            managedFileInfo: Self.validManagedFileInfo(),
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInactive)
        #expect(result.configuredPath == configuredPath)
    }

    @Test
    func invalidAtExactManagedURLBecomesManagedInvalid() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        // Managed target has an entry but it's invalid (e.g. missing marker)
        let invalidFileInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: false,
            parsesAsACPInvocation: false,
            passesSyntaxValidation: false,
            invalidReason: .missingOwnershipMarker
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperInvalid(wrapperURL: managedURL, reason: "syntax error"),
            managedFileInfo: invalidFileInfo,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInvalid)
        #expect(result.invalidReason == "syntax error")
    }

    @Test
    func invalidAtOtherURLBecomesUnmanagedInvalid() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let otherURL = URL(fileURLWithPath: "/tmp/other/wrapper.sh")
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperInvalid(wrapperURL: otherURL, reason: "not executable"),
            managedFileInfo: .absent,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .unmanagedWrapperInvalid)
        #expect(result.invalidReason == "not executable")
    }

    // MARK: - Invalid at other URL with managed wrapper present

    @Test
    func invalidAtOtherURLWithManagedExistsBecomesUnmanagedInvalid() {
        // Previously this was managedWrapperInactive, which hid the
        // active Xcode problem. Now it's unmanagedWrapperInvalid with
        // managedWrapperAvailable set.
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let otherURL = URL(fileURLWithPath: "/tmp/other/wrapper.sh")
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperInvalid(wrapperURL: otherURL, reason: "syntax error"),
            managedFileInfo: Self.validManagedFileInfo(),
            managedWrapperURL: managedURL
        )
        #expect(result.state == .unmanagedWrapperInvalid)
        #expect(result.managedWrapperAvailable == true)
        #expect(result.invalidReason?.contains("syntax error") == true)
        #expect(result.configuredPath == otherURL)
    }

    @Test
    func validAtExactManagedURLBecomesManagedActive() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let config = ACPWrapperConfiguration(
            wrapperURL: managedURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: "test",
            effort: "high",
            isExecutable: true,
            syntaxIsValid: true
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: Self.validManagedFileInfo(),
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperActive)
        #expect(result.activeConfiguration == config)
    }

    @Test
    func validAtOtherURLWithNoManagedBecomesUnmanagedActive() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let otherURL = URL(fileURLWithPath: "/tmp/other/wrapper.sh")
        let config = ACPWrapperConfiguration(
            wrapperURL: otherURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: "test",
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
        #expect(result.activeConfiguration == config)
    }

    @Test
    func validAtOtherURLWithManagedExistsBecomesManagedInactive() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let otherURL = URL(fileURLWithPath: "/tmp/other/wrapper.sh")
        let config = ACPWrapperConfiguration(
            wrapperURL: otherURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: "model-x",
            effort: "low",
            isExecutable: true,
            syntaxIsValid: true
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: Self.validManagedFileInfo(),
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInactive)
        #expect(result.activeConfiguration == config)
        #expect(result.configuredPath == otherURL)
    }

    // MARK: - Symlink safety

    @Test
    func symlinkAtDifferentPathPointingToManagedTargetIsNotOwned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        let symlinkURL = root.appendingPathComponent("symlink-to-managed.sh")

        try "#!/bin/zsh\nexec '/bin/echo' acp\n".write(to: managedURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: managedURL.path
        )
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: managedURL)

        let config = ACPWrapperConfiguration(
            wrapperURL: symlinkURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil,
            isExecutable: true,
            syntaxIsValid: true
        )
        // Using structured fileInfo with the managed path being a real file
        // that has marker and valid ACP invocation
        let fileInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: true,
            parsesAsACPInvocation: true,
            passesSyntaxValidation: true,
            invalidReason: nil
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: fileInfo,
            managedWrapperURL: managedURL
        )
        // Symlink URL != managed URL → managedWrapperInactive
        #expect(result.state == .managedWrapperInactive)
    }

    @Test
    func exactCanonicalPathBeingSymlinkIsNotClassifiedManagedActive() throws {
        // Even if the path MATCHES the managed URL string exactly,
        // if it's a symlink it must NOT be classified as managed active.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        let targetURL = root.appendingPathComponent("actual-script.sh")

        // Create target and symlink at managed path
        try "#!/bin/zsh\nexec '/bin/echo' acp\n".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: targetURL.path
        )
        try FileManager.default.createSymbolicLink(at: managedURL, withDestinationURL: targetURL)

        let config = ACPWrapperConfiguration(
            wrapperURL: managedURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil,
            isExecutable: true,
            syntaxIsValid: true
        )
        // The managed path IS a symlink
        let fileInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: true,
            isExecutableRegularFile: false,
            hasOwnershipMarker: false,
            parsesAsACPInvocation: false,
            passesSyntaxValidation: false,
            invalidReason: .isSymbolicLink
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: fileInfo,
            managedWrapperURL: managedURL
        )
        // Even though path matches, symlink blocks managed classification
        #expect(result.state != .managedWrapperActive)
        // Exact path but invalid managed artifact = managedWrapperInvalid
        #expect(result.state == .managedWrapperInvalid)
    }

    @Test
    func danglingSymlinkAtManagedTargetBlocksFirstInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        let danglingTarget = root.appendingPathComponent("nonexistent-target.sh")
        try FileManager.default.createSymbolicLink(at: managedURL, withDestinationURL: danglingTarget)

        let fileInfo = ManagedWrapperFileInfo.read(at: managedURL)
        // Should detect the entry exists (the symlink itself)
        #expect(fileInfo.entryExists == true)
        #expect(fileInfo.isSymbolicLink == true)
        #expect(fileInfo.isExecutableRegularFile == false)
        // Must not be safe for first install
        #expect(fileInfo.isAbsentAndSafe == false)
        // Must not be a valid managed wrapper
        #expect(fileInfo.isValidManagedWrapper == false)
    }

    @Test
    func managedWrapperFileInfoDetectsRegularExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("wrapper.sh")
        // Must match the complete deterministic managed-wrapper format.
        let content = """
        #!/bin/zsh
        \(ACPWrapperManager.ownershipMarker)
        # Managed by ACP Control Center. Review changes in the app before installing.
        export HOME='/tmp'
        export PATH='/bin:/usr/bin'

        exec '/bin/echo' acp
        """ + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: fileURL.path
        )

        let info = ManagedWrapperFileInfo.read(at: fileURL)
        #expect(info.entryExists == true)
        #expect(info.isSymbolicLink == false)
        #expect(info.isExecutableRegularFile == true)
        #expect(info.hasOwnershipMarker == true)
        #expect(info.parsesAsACPInvocation == true)
        #expect(info.passesSyntaxValidation == true)
        #expect(info.isValidManagedWrapper == true)
        #expect(info.isAbsentAndSafe == false)
    }

    @Test
    func managedWrapperFileInfoDetectsAbsence() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString).sh")
        let info = ManagedWrapperFileInfo.read(at: missing)
        #expect(info == ManagedWrapperFileInfo.absent)
        #expect(info.isAbsentAndSafe == true)
        #expect(info.isValidManagedWrapper == false)
    }

    @Test
    func enotdirAncestorIsNotSafeAbsence() throws {
        // An ancestor component exists but is not a directory (ENOTDIR): the
        // canonical destination cannot be created, so it must fail closed
        // instead of being reported as absent and safe.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let blockingFile = root.appendingPathComponent("not-a-dir")
        try "x".write(to: blockingFile, atomically: true, encoding: .utf8)

        let broken = blockingFile.appendingPathComponent("wrapper.sh")
        let info = ManagedWrapperFileInfo.read(at: broken)
        #expect(info.entryExists == false)
        #expect(info.isAbsentAndSafe == false)
        #expect(info.isValidManagedWrapper == false)
        if let reason = info.invalidReason {
            guard case .inspectionFailed = reason else {
                Issue.record("Expected .inspectionFailed, got \(reason)")
                return
            }
        } else {
            Issue.record("Expected an invalid reason for ENOTDIR ancestor")
        }
    }

    @Test
    func exactPathMatchIgnoresTrailingSlashDifferences() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let configWithRedundantComponents = URL(fileURLWithPath: "/tmp/managed/./kiro-acp-xcode.sh")
        let config = ACPWrapperConfiguration(
            wrapperURL: configWithRedundantComponents,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil,
            isExecutable: true,
            syntaxIsValid: true
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: Self.validManagedFileInfo(),
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperActive)
    }

    // MARK: - wrapperResult(from:) consistency

    @Test
    func wrapperResultDerivedFromObservationMatchesDirectRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wrapperDir) }
        let wrapperURL = wrapperDir.appendingPathComponent("wrapper.sh")
        let content = "#!/bin/zsh\nexec '/bin/echo' acp --model 'test-model'\n"
        try content.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: wrapperURL.path
        )

        let plistURL = root.appendingPathComponent("Kiro.plist")
        let plistDict: [String: Any] = [
            "agent": wrapperURL.path,
            "arguments": [],
            "environment": [:],
            "name": "kiro"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let reader = ACPWrapperReader(acpDirectory: root)
        let observation = reader.readProviderObservation()
        let derived = ACPWrapperReader.wrapperResult(from: observation)

        guard case .success(let config) = derived else {
            Issue.record("Expected success from derived result")
            return
        }
        #expect(config.modelID == "test-model")
        #expect(config.wrapperURL == wrapperURL)
    }

    @Test
    func wrapperResultFromNoProviderIsMissing() {
        let result = ACPWrapperReader.wrapperResult(from: .noProvider)
        guard case .failure(.missing) = result else {
            Issue.record("Expected .failure(.missing)")
            return
        }
    }

    @Test
    func wrapperResultFromInvalidIsInvalid() {
        let url = URL(fileURLWithPath: "/tmp/wrapper.sh")
        let result = ACPWrapperReader.wrapperResult(from: .wrapperInvalid(wrapperURL: url, reason: "test reason"))
        guard case .failure(.invalid(let reason)) = result else {
            Issue.record("Expected .failure(.invalid)")
            return
        }
        #expect(reason.contains("test reason"))
    }

}
