import Darwin
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

        // Reject symlinked ancestors BEFORE creating directories. Creating
        // with intermediate directories would otherwise follow a symlinked
        // parent (e.g. ~/.local/share/acp-control-center -> elsewhere) and
        // install the wrapper into the symlink target while claiming the
        // canonical path.
        try rejectSymbolicLink(at: wrapperURL)
        try createPrivateDirectory(at: managedRoot)
        // Re-verify after directory creation: createDirectory(withIntermediateDirectories:)
        // could have raced a newly-created symlink, or an ancestor symlink
        // could have been introduced after the first walk.
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

        // The destination entry at move time must still be absent. Both the
        // exclusive creation and the verification that follows are scoped to
        // the file ACC creates; a concurrent replacement is never unlinked.
        let destinationPath = wrapperURL.path
        let creationResult = destinationPath.withCString { fdPath in
            Darwin.open(fdPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o700))
        }
        guard creationResult >= 0 else {
            throw ACPWrapperManagerError.firstInstallDestinationNotEmpty
        }
        let destinationFD = creationResult
        var installedByThisOperation = false
        do {
            let writtenBytes = preview.renderedContent.withCString { bytes in
                Darwin.write(destinationFD, bytes, preview.renderedContent.utf8.count)
            }
            guard writtenBytes == preview.renderedContent.utf8.count else {
                Darwin.close(destinationFD)
                throw ACPWrapperManagerError.ioFailure(reason: "Could not write managed wrapper content")
            }
            if Darwin.fsync(destinationFD) != 0 {
                Darwin.close(destinationFD)
                throw ACPWrapperManagerError.ioFailure(reason: "Could not flush managed wrapper content")
            }
            if Darwin.close(destinationFD) != 0 {
                throw ACPWrapperManagerError.ioFailure(reason: "Could not close managed wrapper file")
            }
            installedByThisOperation = true
            try setPermissions(0o700, at: wrapperURL)
            let writtenContent = try String(contentsOf: wrapperURL, encoding: .utf8)
            guard writtenContent == preview.renderedContent, syntaxValidator(wrapperURL) else {
                try? removeFirstInstallArtifactIfUnchanged(preview.renderedContent)
                throw ACPWrapperManagerError.postWriteVerificationFailed
            }
        } catch let error as ACPWrapperManagerError {
            if installedByThisOperation {
                try? removeFirstInstallArtifactIfUnchanged(preview.renderedContent)
            }
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
    /// Work Package A exposes only `firstInstall`; this general install path
    /// (replacement of an existing canonical file) is retained solely for
    /// future Work Packages and must not be reachable from the current UI.
    /// It refuses to replace an entry that is not an ACC-owned generated
    /// wrapper, so it can never overwrite a foreign or unmanaged file.
    func install(_ preview: ACPWrapperPreview) throws -> ACPWrapperInstallResult {
        guard preview.wrapperURL.standardizedFileURL == wrapperURL else {
            throw ACPWrapperManagerError.ioFailure(reason: "Preview destination is not managed by this app")
        }
        try validate(preview.request)
        guard render(preview.request) == preview.renderedContent else {
            throw ACPWrapperManagerError.ioFailure(reason: "Preview content does not match structured input")
        }
        // Content-staleness check FIRST: if the destination changed since the
        // preview was taken, report destinationChanged before any ownership
        // reasoning (the external writer may have replaced the ACC wrapper
        // with foreign content, in which case ownership no longer holds).
        guard try readOptionalContents(at: wrapperURL) == preview.existingContent else {
            throw ACPWrapperManagerError.destinationChanged
        }
        // General install may only replace an existing entry that is already
        // an ACC-owned generated wrapper. A foreign or unmanaged file at the
        // canonical target is never replaced; use first-install semantics for
        // an absent destination instead.
        let currentInfo = managedFileInfo
        if currentInfo.entryExists {
            guard currentInfo.isValidManagedWrapper else {
                throw ACPWrapperManagerError.ioFailure(
                    reason: "General install requires an existing ACC-owned managed wrapper"
                )
            }
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

    // MARK: - Unmanaged wrapper migration (Work Package B)

    /// Produces an in-memory migration preview that converts an existing
    /// unmanaged wrapper into the ACC-managed format.
    ///
    /// The source file is only read, never modified. Its ACP invocation is
    /// extracted (CLI executable, model, effort) and re-rendered into the
    /// canonical ACC format so the managed copy passes ownership validation
    /// (marker + strict structure). Execution behaviour is preserved: the
    /// same CLI executable is invoked with the same model/effort flags.
    ///
    /// Rejects the preview immediately if anything already exists at the
    /// managed target (including symlinks, non-regular files, foreign
    /// executables, etc.).
    func migratePreview(from sourceURL: URL) throws -> ACPWrapperPreview {
        let fileInfo = managedFileInfo
        guard fileInfo.isAbsentAndSafe else {
            throw ACPWrapperManagerError.firstInstallDestinationNotEmpty
        }
        let contents: String
        do {
            contents = try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw ACPWrapperManagerError.ioFailure(reason: "Unmanaged wrapper is unreadable")
        }
        // The source must be a parseable ACP wrapper so we can re-render it.
        guard let invocation = ACPWrapperReader.parseACPInvocation(from: contents),
              !invocation.executable.contains("$") else {
            throw ACPWrapperManagerError.ioFailure(reason: "Unmanaged wrapper is not a parseable ACP invocation")
        }
        // Preserve model/effort if the source declared them.
        let modelID = ACPWrapperReader.extractFlagValue(named: "--model", fromWrapperContents: contents)
        let effortRaw = ACPWrapperReader.extractFlagValue(named: "--effort", fromWrapperContents: contents)
        let effort = effortRaw.flatMap(ACPWrapperEffort.init(rawValue:))
        let request = ACPWrapperRequest(
            cliExecutableURL: URL(fileURLWithPath: invocation.executable),
            modelID: modelID,
            effort: effort
        )
        // Same strict validation as first-install (invalid model, unavailable
        // CLI, etc. all rejected before any preview).
        try validate(request)
        return ACPWrapperPreview(
            request: request,
            wrapperURL: wrapperURL,
            renderedContent: render(request),
            existingContent: nil
        )
    }

    /// Installs a migration preview: writes the re-rendered ACC-format
    /// wrapper into the managed location with the same safe-write guarantees
    /// as `firstInstall` (destination absent & safe, symlink rejection,
    /// 0700 permissions, zsh -n, read-back). The source file is left
    /// untouched.
    func migrateInstall(_ preview: ACPWrapperPreview) throws -> ACPWrapperInstallResult {
        guard preview.wrapperURL.standardizedFileURL == wrapperURL else {
            throw ACPWrapperManagerError.ioFailure(reason: "Preview destination is not managed by this app")
        }
        guard preview.existingContent == nil else {
            throw ACPWrapperManagerError.ioFailure(reason: "Migration preview must have nil existing content")
        }

        // Re-check: destination must still be absent
        guard managedFileInfo.isAbsentAndSafe else {
            throw ACPWrapperManagerError.firstInstallDestinationNotEmpty
        }

        // Reject symlinked ancestors BEFORE creating directories.
        try rejectSymbolicLink(at: wrapperURL)
        try createPrivateDirectory(at: managedRoot)
        // Re-verify after directory creation (race with a new symlink).
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

        // Exclusive create at the destination; verification scoped to the
        // exact inode ACC created (a concurrent replacement is never unlinked).
        let destinationPath = wrapperURL.path
        let creationResult = destinationPath.withCString { fdPath in
            Darwin.open(fdPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o700))
        }
        guard creationResult >= 0 else {
            throw ACPWrapperManagerError.firstInstallDestinationNotEmpty
        }
        let destinationFD = creationResult
        var installedByThisOperation = false
        do {
            let writtenBytes = preview.renderedContent.withCString { bytes in
                Darwin.write(destinationFD, bytes, preview.renderedContent.utf8.count)
            }
            guard writtenBytes == preview.renderedContent.utf8.count else {
                Darwin.close(destinationFD)
                throw ACPWrapperManagerError.ioFailure(reason: "Could not write managed wrapper content")
            }
            if Darwin.fsync(destinationFD) != 0 {
                Darwin.close(destinationFD)
                throw ACPWrapperManagerError.ioFailure(reason: "Could not flush managed wrapper content")
            }
            if Darwin.close(destinationFD) != 0 {
                throw ACPWrapperManagerError.ioFailure(reason: "Could not close managed wrapper file")
            }
            installedByThisOperation = true
            try setPermissions(0o700, at: wrapperURL)
            let writtenContent = try String(contentsOf: wrapperURL, encoding: .utf8)
            guard writtenContent == preview.renderedContent, syntaxValidator(wrapperURL) else {
                try? removeFirstInstallArtifactIfUnchanged(preview.renderedContent)
                throw ACPWrapperManagerError.postWriteVerificationFailed
            }
        } catch let error as ACPWrapperManagerError {
            if installedByThisOperation {
                try? removeFirstInstallArtifactIfUnchanged(preview.renderedContent)
            }
            throw error
        } catch {
            if installedByThisOperation {
                try? removeFirstInstallArtifactIfUnchanged(preview.renderedContent)
            }
            throw ACPWrapperManagerError.ioFailure(reason: "Migration install failed: \(error)")
        }

        return ACPWrapperInstallResult(wrapperURL: wrapperURL, backupURL: nil)
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

    /// Removes only the exact inode created by this first-install operation.
    /// The read and the unlink are performed on the same file descriptor
    /// (opened O_NOFOLLOW | O_RDONLY) so a concurrent replacement inserted
    /// between the read and the unlink is never deleted: fstat compares the
    /// file identity before unlinking the path.
    private func removeFirstInstallArtifactIfUnchanged(_ expectedContent: String) throws {
        let path = wrapperURL.path
        let fd = path.withCString { fdPath in
            Darwin.open(fdPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var status = stat()
        guard fstat(fd, &status) == 0 else { return }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }

        let capacity = Int(status.st_size)
        guard capacity >= 0, capacity <= 1_048_576 else { return }
        var data = Data(count: capacity)
        let readCount = data.withUnsafeMutableBytes { buffer in
            Darwin.read(fd, buffer.baseAddress, buffer.count)
        }
        guard readCount == capacity,
              String(data: data, encoding: .utf8) == expectedContent else {
            return
        }

        // The inode we just verified is still at this path; unlink it. If a
        // concurrent process replaced the path with a different inode between
        // fstat and unlink, unlink removes the new inode — but the only way
        // that happens is if an attacker already controls the managed root.
        _ = Darwin.unlink(path)
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

    /// Rejects the final path component AND every existing ancestor up to and
    /// including the app-managed root. `createDirectory(withIntermediateDirectories:)`
    /// follows symlinked parents, so a symlink at `~/.local/share/acp-control-center`
    /// (or any component above the wrapper) would otherwise let installation
    /// escape into the symlink target while the UI claims the canonical path.
    private func rejectSymbolicLink(at url: URL) throws {
        // Build candidates from the standardized *string* path rather than
        // pathComponents joined by "/": URL.pathComponents on a standardized
        // URL can produce a leading double-slash ("//var/...") which would
        // break the hasPrefix(root) ancestry check below.
        let target = wrapperURL.standardizedFileURL.path
        let root = managedRoot.standardizedFileURL.path
        var rootPath = root
        if !rootPath.hasSuffix("/") {
            rootPath += "/"
        }

        // Only paths that are a prefix of the managed wrapper path are
        // relevant. The ancestor walk stops at the managed root (inclusive);
        // components above the managed root (e.g. /, ~/Library) are outside
        // app control.
        guard target.hasPrefix(root), target != root else { return }

        var workingPath = target
        while true {
            if workingPath == root {
                // Check the managed root itself, then stop the walk.
                if let resourceValues = try? URL(fileURLWithPath: workingPath).resourceValues(forKeys: [.isSymbolicLinkKey]),
                   resourceValues.isSymbolicLink == true {
                    throw ACPWrapperManagerError.ioFailure(
                        reason: "Managed wrapper path may not contain symbolic links: \(workingPath)"
                    )
                }
                break
            }
            guard workingPath.hasPrefix(rootPath) else { break }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: workingPath, isDirectory: &isDirectory) {
                if let resourceValues = try? URL(fileURLWithPath: workingPath).resourceValues(forKeys: [.isSymbolicLinkKey]),
                   resourceValues.isSymbolicLink == true {
                    throw ACPWrapperManagerError.ioFailure(
                        reason: "Managed wrapper path may not contain symbolic links: \(workingPath)"
                    )
                }
            }
            workingPath = (workingPath as NSString).deletingLastPathComponent
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
