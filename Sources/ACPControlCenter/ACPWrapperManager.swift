import Foundation

/// Supported Kiro ACP effort levels. Keeping this as an enum prevents arbitrary
/// shell fragments from entering generated wrappers.
enum ACPWrapperEffort: String, CaseIterable, Equatable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
}

/// Structured wrapper input. Environment variables are deliberately not
/// caller-controlled; the renderer emits only its fixed HOME/PATH allowlist.
struct ACPWrapperRequest: Equatable, Sendable {
    let cliExecutableURL: URL
    let modelID: String?
    let effort: ACPWrapperEffort?
}

struct ACPWrapperPreview: Equatable, Sendable {
    let request: ACPWrapperRequest
    let wrapperURL: URL
    let renderedContent: String
    let existingContent: String?
}

struct ACPWrapperInstallResult: Equatable, Sendable {
    let wrapperURL: URL
    let backupURL: URL?
}

enum ACPWrapperManagerError: Error, Equatable, Sendable {
    case invalidExecutablePath
    case invalidModelID
    case destinationChanged
    case syntaxValidationFailed
    case postWriteVerificationFailed
    case unmanagedBackup
    case firstInstallDestinationNotEmpty
    case ioFailure(reason: String)
}

/// Generates only app-managed Kiro ACP wrappers. It never reads or writes
/// Xcode's ACP plist; Xcode remains the owner of provider configuration.
struct ACPWrapperManager: Sendable {
    static func defaultManagedRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("acp-control-center")
            .appendingPathComponent("wrappers")
    }

    let managedRoot: URL
    let wrapperURL: URL
    private let backupsURL: URL
    private let homeDirectory: URL
    private let syntaxValidator: @Sendable (URL) -> Bool
    private let now: @Sendable () -> Date
    private let beforeFirstInstallMove: @Sendable () throws -> Void

    /// Structured filesystem and content info about the managed wrapper target.
    /// Reports entry type, ownership marker presence, parse, and syntax truthfully.
    var managedFileInfo: ManagedWrapperFileInfo {
        ManagedWrapperFileInfo.read(at: wrapperURL, syntaxValidator: syntaxValidator)
    }

    /// Whether the managed wrapper passes full ownership validation.
    var managedWrapperExists: Bool {
        managedFileInfo.isValidManagedWrapper
    }

    init(
        managedRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        processRunner: ProcessRunner = ProcessRunner(),
        syntaxValidator: (@Sendable (URL) -> Bool)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        beforeFirstInstallMove: @escaping @Sendable () throws -> Void = {}
    ) {
        let root = (managedRoot ?? Self.defaultManagedRoot(homeDirectory: homeDirectory))
            .standardizedFileURL
        self.managedRoot = root
        self.wrapperURL = root.appendingPathComponent("kiro-acp-xcode.sh")
        self.backupsURL = root.appendingPathComponent("Backups")
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.syntaxValidator = syntaxValidator ?? { url in
            processRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-n", url.path]
            ).exitCode == 0
        }
        self.now = now
        self.beforeFirstInstallMove = beforeFirstInstallMove
    }

    // MARK: - First-install API (Work Package A)

    /// Preview for first-time install. Rejects immediately if any entry
    /// already exists at the managed target (including symlinks, non-regular
    /// files, foreign executables, etc.).
    func firstInstallPreview(_ request: ACPWrapperRequest) throws -> ACPWrapperPreview {
        let fileInfo = managedFileInfo
        guard fileInfo.isAbsentAndSafe else {
            throw ACPWrapperManagerError.firstInstallDestinationNotEmpty
        }
        try validate(request)
        return ACPWrapperPreview(
            request: request,
            wrapperURL: wrapperURL,
            renderedContent: render(request),
            existingContent: nil
        )
    }

    /// Installs a first-time preview. Re-checks that the destination is
    /// still absent immediately before write. This is the only write API
    /// exposed for Work Package A.
    func firstInstall(_ preview: ACPWrapperPreview) throws -> ACPWrapperInstallResult {
        guard preview.wrapperURL.standardizedFileURL == wrapperURL else {
            throw ACPWrapperManagerError.ioFailure(reason: "Preview destination is not managed by this app")
        }
        guard preview.existingContent == nil else {
            throw ACPWrapperManagerError.ioFailure(reason: "First install preview must have nil existing content")
        }
        try validate(preview.request)
        guard render(preview.request) == preview.renderedContent else {
            throw ACPWrapperManagerError.ioFailure(reason: "Preview content does not match structured input")
        }
        // Re-check: destination must still be absent
        let currentInfo = managedFileInfo
        guard currentInfo.isAbsentAndSafe else {
            throw ACPWrapperManagerError.firstInstallDestinationNotEmpty
        }

        try createPrivateDirectory(at: managedRoot)
        try rejectSymbolicLink(at: wrapperURL)

        let temporaryURL = managedRoot.appendingPathComponent(".wrapper-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try write(preview.renderedContent, to: temporaryURL, permissions: 0o700)
        guard syntaxValidator(temporaryURL) else {
            throw ACPWrapperManagerError.syntaxValidationFailed
        }

        // Final re-check before atomic move
        guard managedFileInfo.isAbsentAndSafe else {
            throw ACPWrapperManagerError.firstInstallDestinationNotEmpty
        }

        try beforeFirstInstallMove()
        var installedByThisOperation = false
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: wrapperURL)
            installedByThisOperation = true
            try setPermissions(0o700, at: wrapperURL)
            let writtenContent = try String(contentsOf: wrapperURL, encoding: .utf8)
            guard writtenContent == preview.renderedContent, syntaxValidator(wrapperURL) else {
                try? removeFirstInstallArtifactIfUnchanged(preview.renderedContent)
                throw ACPWrapperManagerError.postWriteVerificationFailed
            }
        } catch let error as ACPWrapperManagerError {
            throw error
        } catch {
            if installedByThisOperation {
                try? removeFirstInstallArtifactIfUnchanged(preview.renderedContent)
            }
            throw ACPWrapperManagerError.ioFailure(reason: "First install failed: \(error)")
        }

        return ACPWrapperInstallResult(wrapperURL: wrapperURL, backupURL: nil)
    }

    // MARK: - General preview/install (retained for future Work Packages)

    /// Produces an in-memory preview and captures the destination's current
    /// contents. No directory or file is created by this method.
    func preview(_ request: ACPWrapperRequest) throws -> ACPWrapperPreview {
        try validate(request)
        return ACPWrapperPreview(
            request: request,
            wrapperURL: wrapperURL,
            renderedContent: render(request),
            existingContent: try readOptionalContents(at: wrapperURL)
        )
    }

    /// Installs exactly the previously previewed content. A stale preview is
    /// rejected rather than overwriting a destination changed by another tool.
    func install(_ preview: ACPWrapperPreview) throws -> ACPWrapperInstallResult {
        guard preview.wrapperURL.standardizedFileURL == wrapperURL else {
            throw ACPWrapperManagerError.ioFailure(reason: "Preview destination is not managed by this app")
        }
        try validate(preview.request)
        guard render(preview.request) == preview.renderedContent else {
            throw ACPWrapperManagerError.ioFailure(reason: "Preview content does not match structured input")
        }
        guard try readOptionalContents(at: wrapperURL) == preview.existingContent else {
            throw ACPWrapperManagerError.destinationChanged
        }

        try createPrivateDirectory(at: managedRoot)
        try rejectSymbolicLink(at: wrapperURL)

        let temporaryURL = managedRoot.appendingPathComponent(".wrapper-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try write(preview.renderedContent, to: temporaryURL, permissions: 0o700)
        guard syntaxValidator(temporaryURL) else {
            throw ACPWrapperManagerError.syntaxValidationFailed
        }

        guard try readOptionalContents(at: wrapperURL) == preview.existingContent else {
            throw ACPWrapperManagerError.destinationChanged
        }
        let backupURL = try backupExistingWrapperIfNeeded()
        do {
            try atomicallyReplace(destination: wrapperURL, with: temporaryURL)
            try setPermissions(0o700, at: wrapperURL)
            let writtenContent = try String(contentsOf: wrapperURL, encoding: .utf8)
            guard writtenContent == preview.renderedContent, syntaxValidator(wrapperURL) else {
                try restoreAfterFailedInstall(backupURL: backupURL)
                throw ACPWrapperManagerError.postWriteVerificationFailed
            }
        } catch let error as ACPWrapperManagerError {
            throw error
        } catch {
            try? restoreAfterFailedInstall(backupURL: backupURL)
            throw ACPWrapperManagerError.ioFailure(reason: "Atomic wrapper install failed: \(error)")
        }

        return ACPWrapperInstallResult(wrapperURL: wrapperURL, backupURL: backupURL)
    }

    /// Returns only backups created under the app-managed backup directory,
    /// newest first. It never scans outside that single directory.
    func recentBackups(limit: Int = 10) -> [URL] {
        let boundedLimit = min(max(limit, 0), 50)
        guard boundedLimit > 0,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: backupsURL,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls
            .filter { url in
                guard url.pathExtension == "sh" else { return false }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { left, right in
                let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
            }
            .prefix(boundedLimit)
            .map { $0 }
    }

    /// Atomically restores an app-created backup to the single managed wrapper
    /// destination. Arbitrary source or destination paths are rejected.
    func rollback(backupURL: URL, wrapperURL requestedWrapperURL: URL) throws {
        guard requestedWrapperURL.standardizedFileURL == wrapperURL,
              backupURL.standardizedFileURL.deletingLastPathComponent().path
                == backupsURL.standardizedFileURL.path else {
            throw ACPWrapperManagerError.unmanagedBackup
        }
        try rejectSymbolicLink(at: backupURL)
        try rejectSymbolicLink(at: wrapperURL)
        let contents: String
        do {
            contents = try String(contentsOf: backupURL, encoding: .utf8)
        } catch {
            throw ACPWrapperManagerError.ioFailure(reason: "Backup is missing or unreadable")
        }

        try createPrivateDirectory(at: managedRoot)
        let temporaryURL = managedRoot.appendingPathComponent(".rollback-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try write(contents, to: temporaryURL, permissions: 0o700)
        guard syntaxValidator(temporaryURL) else {
            throw ACPWrapperManagerError.syntaxValidationFailed
        }
        let preRollbackBackupURL = try backupExistingWrapperIfNeeded()
        do {
            try atomicallyReplace(destination: wrapperURL, with: temporaryURL)
            try setPermissions(0o700, at: wrapperURL)
            guard try String(contentsOf: wrapperURL, encoding: .utf8) == contents,
                  syntaxValidator(wrapperURL) else {
                try restoreAfterFailedInstall(backupURL: preRollbackBackupURL)
                throw ACPWrapperManagerError.postWriteVerificationFailed
            }
        } catch let error as ACPWrapperManagerError {
            throw error
        } catch {
            try? restoreAfterFailedInstall(backupURL: preRollbackBackupURL)
            throw ACPWrapperManagerError.ioFailure(reason: "Atomic rollback failed: \(error)")
        }
    }

    // MARK: - Rendering

    private func validate(_ request: ACPWrapperRequest) throws {
        let path = request.cliExecutableURL.path
        guard request.cliExecutableURL.isFileURL,
              path.hasPrefix("/"),
              !path.contains(where: \.isNewline),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw ACPWrapperManagerError.invalidExecutablePath
        }
        if let modelID = request.modelID {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/-"))
            guard !modelID.isEmpty,
                  modelID.count <= 200,
                  modelID.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ACPWrapperManagerError.invalidModelID
            }
        }
    }

    /// Deterministic ownership marker embedded in generated wrappers.
    /// The classifier requires this marker plus parse + syntax for ownership.
    static let ownershipMarker = "# ACC-MANAGED-WRAPPER"

    private func render(_ request: ACPWrapperRequest) -> String {
        let pathValue = allowedPath(for: request.cliExecutableURL)
        var arguments = [
            "exec",
            shellQuote(request.cliExecutableURL.path),
            "acp"
        ]
        if let modelID = request.modelID {
            arguments.append(contentsOf: ["--model", shellQuote(modelID)])
        }
        if let effort = request.effort {
            arguments.append(contentsOf: ["--effort", shellQuote(effort.rawValue)])
        }
        return """
        #!/bin/zsh
        \(Self.ownershipMarker)
        # Managed by ACP Control Center. Review changes in the app before installing.
        export HOME=\(shellQuote(homeDirectory.path))
        export PATH=\(shellQuote(pathValue))

        \(arguments.joined(separator: " "))
        """ + "\n"
    }

    private func allowedPath(for executableURL: URL) -> String {
        let candidates = [
            executableURL.deletingLastPathComponent().path,
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            homeDirectory.appendingPathComponent("bin").path
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - Filesystem safety

    private func readOptionalContents(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ACPWrapperManagerError.ioFailure(reason: "Managed wrapper is unreadable")
        }
    }

    /// Removes only the exact bytes written by this first-install operation.
    /// If another process replaced the destination, its file is untouched.
    private func removeFirstInstallArtifactIfUnchanged(_ expectedContent: String) throws {
        guard let currentContent = try readOptionalContents(at: wrapperURL),
              currentContent == expectedContent else {
            return
        }
        try FileManager.default.removeItem(at: wrapperURL)
    }

    private func createPrivateDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try rejectSymbolicLink(at: url)
            try setPermissions(0o700, at: url)
        } catch let error as ACPWrapperManagerError {
            throw error
        } catch {
            throw ACPWrapperManagerError.ioFailure(reason: "Could not create private wrapper directory: \(error)")
        }
    }

    private func write(_ contents: String, to url: URL, permissions: Int) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        ) else {
            throw ACPWrapperManagerError.ioFailure(reason: "Could not create temporary wrapper")
        }
        try setPermissions(permissions, at: url)
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: url.path
            )
        } catch {
            throw ACPWrapperManagerError.ioFailure(reason: "Could not set private file permissions")
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ACPWrapperManagerError.ioFailure(reason: "Managed wrapper paths may not be symbolic links")
            }
        } catch let error as ACPWrapperManagerError {
            throw error
        } catch {
            throw ACPWrapperManagerError.ioFailure(reason: "Could not inspect managed wrapper path")
        }
    }

    private func backupExistingWrapperIfNeeded() throws -> URL? {
        guard FileManager.default.fileExists(atPath: wrapperURL.path) else { return nil }
        try createPrivateDirectory(at: backupsURL)
        let timestamp = Int(now().timeIntervalSince1970)
        let backupURL = backupsURL
            .appendingPathComponent("kiro-acp-xcode-\(timestamp)-\(UUID().uuidString).sh")
        do {
            try FileManager.default.copyItem(at: wrapperURL, to: backupURL)
            try setPermissions(0o600, at: backupURL)
            return backupURL
        } catch let error as ACPWrapperManagerError {
            throw error
        } catch {
            throw ACPWrapperManagerError.ioFailure(reason: "Could not create wrapper backup: \(error)")
        }
    }

    private func atomicallyReplace(destination: URL, with temporaryURL: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }
    }

    private func restoreAfterFailedInstall(backupURL: URL?) throws {
        if let backupURL {
            try restoreBackupExactly(backupURL)
        } else {
            try? FileManager.default.removeItem(at: wrapperURL)
        }
    }

    /// Restores a byte-for-byte pre-operation backup. This path deliberately
    /// does not require the old wrapper to pass current syntax validation: an
    /// automatic rollback must always return the user's previous state.
    private func restoreBackupExactly(_ backupURL: URL) throws {
        let contents = try String(contentsOf: backupURL, encoding: .utf8)
        let temporaryURL = managedRoot.appendingPathComponent(".restore-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try write(contents, to: temporaryURL, permissions: 0o700)
        try atomicallyReplace(destination: wrapperURL, with: temporaryURL)
        try setPermissions(0o700, at: wrapperURL)
        guard try String(contentsOf: wrapperURL, encoding: .utf8) == contents else {
            throw ACPWrapperManagerError.postWriteVerificationFailed
        }
    }
}
