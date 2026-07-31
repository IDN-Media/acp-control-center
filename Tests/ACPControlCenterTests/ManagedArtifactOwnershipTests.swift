import Foundation
import Testing
@testable import ACPControlCenter

/// Regression tests for managed artifact ownership validation.
/// Covers requirement: exact path + marker + non-symlink + parse + syntax.
struct ManagedArtifactOwnershipTests {
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
    func foreignExecutableAtCanonicalTargetNoProviderIsManagedInvalid() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let foreignFileInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: false,
            parsesAsACPInvocation: false,
            passesSyntaxValidation: true,
            invalidReason: .missingOwnershipMarker
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .noProvider,
            managedFileInfo: foreignFileInfo,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInvalid)
        #expect(result.invalidReason?.contains("ownership marker") == true)
    }

    @Test
    func markerMissingIsNotManagedActive() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let noMarkerFileInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: false,
            parsesAsACPInvocation: true,
            passesSyntaxValidation: true,
            invalidReason: .missingOwnershipMarker
        )
        let config = ACPWrapperConfiguration(
            wrapperURL: managedURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil,
            isExecutable: true,
            syntaxIsValid: true
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: noMarkerFileInfo,
            managedWrapperURL: managedURL
        )
        #expect(result.state != .managedWrapperActive)
        #expect(result.state == .managedWrapperInvalid)
    }

    @Test
    func markerPresentButSyntaxInvalidIsNotManagedActive() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let syntaxBadFileInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: true,
            parsesAsACPInvocation: true,
            passesSyntaxValidation: false,
            invalidReason: .syntaxInvalid
        )
        let config = ACPWrapperConfiguration(
            wrapperURL: managedURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: nil,
            effort: nil,
            isExecutable: true,
            syntaxIsValid: true
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: syntaxBadFileInfo,
            managedWrapperURL: managedURL
        )
        #expect(result.state != .managedWrapperActive)
        #expect(result.state == .managedWrapperInvalid)
    }

    @Test
    func markerPresentValidWrapperIsManagedActiveWhenXcodePoints() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let config = ACPWrapperConfiguration(
            wrapperURL: managedURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: "model-x",
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
    }

    @Test
    func symlinkAtCanonicalPathIsInvalidNotActiveOrAbsent() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let symlinkInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: true,
            isExecutableRegularFile: false,
            hasOwnershipMarker: false,
            parsesAsACPInvocation: false,
            passesSyntaxValidation: false,
            invalidReason: .isSymbolicLink
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .noProvider,
            managedFileInfo: symlinkInfo,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInvalid)
        #expect(result.state != .noProvider)
        #expect(result.state != .managedWrapperActive)
    }

    @Test
    func danglingSymlinkAtCanonicalPathIsInvalid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        let danglingTarget = root.appendingPathComponent("does-not-exist.sh")
        try FileManager.default.createSymbolicLink(at: managedURL, withDestinationURL: danglingTarget)

        let fileInfo = ManagedWrapperFileInfo.read(at: managedURL)
        #expect(fileInfo.entryExists == true)
        #expect(fileInfo.isSymbolicLink == true)
        #expect(fileInfo.isValidManagedWrapper == false)
        #expect(fileInfo.isAbsentAndSafe == false)
        #expect(fileInfo.invalidReason == .isSymbolicLink)

        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .noProvider,
            managedFileInfo: fileInfo,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInvalid)
    }

    @Test
    func inspectionFailureFailsClosed() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let failedInfo = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: false,
            parsesAsACPInvocation: false,
            passesSyntaxValidation: false,
            invalidReason: .inspectionFailed(reason: "permission denied")
        )
        #expect(failedInfo.isAbsentAndSafe == false)
        #expect(failedInfo.isValidManagedWrapper == false)

        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .noProvider,
            managedFileInfo: failedInfo,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .managedWrapperInvalid)
    }

    @Test
    func unmanagedProviderPlusInvalidCanonicalArtifactIsReadOnly() {
        let managedURL = URL(fileURLWithPath: "/tmp/managed/kiro-acp-xcode.sh")
        let otherURL = URL(fileURLWithPath: "/tmp/other/wrapper.sh")
        let invalidAtManaged = ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: false,
            parsesAsACPInvocation: false,
            passesSyntaxValidation: true,
            invalidReason: .missingOwnershipMarker
        )
        let config = ACPWrapperConfiguration(
            wrapperURL: otherURL,
            cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
            modelID: "model-x",
            effort: nil,
            isExecutable: true,
            syntaxIsValid: true
        )
        let result = ACPWrapperLifecycleClassifier.classify(
            observation: .wrapperValid(configuration: config),
            managedFileInfo: invalidAtManaged,
            managedWrapperURL: managedURL
        )
        #expect(result.state == .unmanagedWrapperActive)
        #expect(result.activeConfiguration == config)
        #expect(result.managedLocationProblemReason?.contains("ownership marker") == true)
    }

    @Test
    func markerAndExecWithAdditionalCommandIsNotManagedFormat() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ACPWrapperManager(
            managedRoot: root,
            syntaxValidator: { _ in true }
        )
        let preview = try manager.firstInstallPreview(
            ACPWrapperRequest(
                cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
                modelID: nil,
                effort: nil
            )
        )
        #expect(ACPWrapperReader.isGeneratedManagedWrapper(preview.renderedContent))

        let injected = preview.renderedContent.replacingOccurrences(
            of: "\n\nexec ",
            with: "\n\nprint 'unexpected command'\nexec "
        )
        #expect(!ACPWrapperReader.isGeneratedManagedWrapper(injected))

        let dynamicEnvironment = preview.renderedContent.replacingOccurrences(
            of: "export HOME='",
            with: "export HOME='$"
        )
        #expect(!ACPWrapperReader.isGeneratedManagedWrapper(dynamicEnvironment))

        let arbitraryArgument = preview.renderedContent.replacingOccurrences(
            of: " acp\n",
            with: " acp --danger yes\n"
        )
        #expect(!ACPWrapperReader.isGeneratedManagedWrapper(arbitraryArgument))
    }

    @Test
    func filesystemInspectionErrorFailsClosedRatherThanAppearingAbsent() {
        let oversizedName = String(repeating: "a", count: 5_000)
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(oversizedName)
        let info = ManagedWrapperFileInfo.read(at: url, syntaxValidator: { _ in true })

        #expect(!info.isAbsentAndSafe)
        guard case .inspectionFailed = info.invalidReason else {
            Issue.record("Expected inspection failure, got \(String(describing: info.invalidReason))")
            return
        }
    }

    @Test
    func destinationCreatedImmediatelyBeforeMoveIsNotDeleted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        let externalBytes = Data("external-owner\n".utf8)
        let manager = ACPWrapperManager(
            managedRoot: root,
            syntaxValidator: { _ in true },
            beforeFirstInstallMove: {
                try externalBytes.write(to: wrapperURL)
            }
        )
        let preview = try manager.firstInstallPreview(
            ACPWrapperRequest(
                cliExecutableURL: URL(fileURLWithPath: "/bin/echo"),
                modelID: nil,
                effort: nil
            )
        )

        #expect(throws: (any Error).self) {
            try manager.firstInstall(preview)
        }
        #expect(try Data(contentsOf: wrapperURL) == externalBytes)
    }
}
