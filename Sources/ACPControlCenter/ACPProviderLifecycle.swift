import Darwin
import Foundation

// MARK: - Structured provider observation

/// What the reader observed from the Xcode ACP plist and wrapper file system.
/// Preserves the configured path so the UI can show it even when the file is
/// missing or invalid. This replaces parsing ReaderError reason strings.
enum ACPProviderObservation: Equatable, Sendable {
    /// No ACP plist found or no plist contains an agent path.
    case noProvider
    /// A plist references a wrapper path, but the file does not exist.
    case configuredPathMissing(configuredPath: URL)
    /// A plist references a wrapper path that exists but cannot be parsed or
    /// fails validation.
    case wrapperInvalid(wrapperURL: URL, reason: String)
    /// A plist references a valid, parseable wrapper.
    case wrapperValid(configuration: ACPWrapperConfiguration)
}

// MARK: - Lifecycle state

/// Product-visible lifecycle state combining provider observation with
/// managed-wrapper existence. Each case drives specific UX in the dashboard.
enum ACPWrapperLifecycleState: Equatable, Sendable {
    /// No ACP provider configured in Xcode and no managed wrapper exists.
    case noProvider
    /// Xcode references a path that does not exist on disk, no managed
    /// wrapper available.
    case configuredPathMissing
    /// Xcode points to an invalid wrapper at a path NOT owned by this app.
    case unmanagedWrapperInvalid
    /// Xcode points to the exact managed wrapper path but it is invalid,
    /// or the managed target contains an invalid/unsafe entry.
    case managedWrapperInvalid
    /// Xcode points to a valid wrapper NOT owned by this app.
    case unmanagedWrapperActive
    /// A managed wrapper exists but Xcode is not (yet) pointing to it.
    /// The UI should offer copy-path and Xcode onboarding instructions.
    case managedWrapperInactive
    /// Xcode is actively using the exact managed wrapper and it is valid.
    case managedWrapperActive
}

/// Context preserved alongside the lifecycle state for UX display purposes.
struct ACPWrapperLifecycleContext: Equatable, Sendable {
    let state: ACPWrapperLifecycleState
    /// The wrapper configuration when Xcode points to a valid wrapper
    /// (managed or unmanaged).
    let activeConfiguration: ACPWrapperConfiguration?
    /// The configured path from the Xcode plist, regardless of whether it
    /// exists. Useful for "Copy Path" and showing the user what Xcode expects.
    let configuredPath: URL?
    /// The reason a wrapper is invalid, when `state` is `.unmanagedWrapperInvalid`
    /// or `.managedWrapperInvalid`. Preserved from the observation so the UI
    /// can display it without parsing ReaderError strings.
    let invalidReason: String?
    /// Whether a managed wrapper file exists at the canonical managed URL,
    /// regardless of whether Xcode currently points to it. Useful for showing
    /// "managed wrapper available" notices alongside unmanaged states.
    let managedWrapperAvailable: Bool
    /// A separate problem at the canonical managed location while Xcode is
    /// using an external provider. It never authorizes a write.
    let managedLocationProblemReason: String?

    init(
        state: ACPWrapperLifecycleState,
        activeConfiguration: ACPWrapperConfiguration? = nil,
        configuredPath: URL? = nil,
        invalidReason: String? = nil,
        managedWrapperAvailable: Bool = false,
        managedLocationProblemReason: String? = nil
    ) {
        self.state = state
        self.activeConfiguration = activeConfiguration
        self.configuredPath = configuredPath
        self.invalidReason = invalidReason
        self.managedWrapperAvailable = managedWrapperAvailable
        self.managedLocationProblemReason = managedLocationProblemReason
    }
}

// MARK: - Managed artifact validity reason

/// Describes why a managed artifact at the canonical target is invalid or
/// unsafe. Used for fail-closed reporting rather than silent fallback.
enum ManagedArtifactInvalidReason: Equatable, Sendable {
    /// The entry is a symbolic link (including dangling).
    case isSymbolicLink
    /// The entry exists but is not a regular file (directory, device, etc.).
    case notRegularFile
    /// The entry is not executable.
    case notExecutable
    /// The entry lacks the required ownership marker in generated header position.
    case missingOwnershipMarker
    /// The entry has the marker but does not parse as a valid ACP invocation.
    case doesNotParseAsACPInvocation
    /// The entry fails /bin/zsh -n syntax validation.
    case syntaxInvalid
    /// An I/O error occurred inspecting the entry.
    case inspectionFailed(reason: String)

    var userDescription: String {
        switch self {
        case .isSymbolicLink:
            return "Entry is a symbolic link, not a regular file"
        case .notRegularFile:
            return "Entry is not a regular file"
        case .notExecutable:
            return "Entry is not executable"
        case .missingOwnershipMarker:
            return "Entry lacks the ACC ownership marker"
        case .doesNotParseAsACPInvocation:
            return "Entry does not parse as a valid ACP invocation"
        case .syntaxInvalid:
            return "Entry fails zsh syntax validation"
        case .inspectionFailed(let reason):
            return "Inspection failed: \(reason)"
        }
    }
}

// MARK: - Structured managed artifact information for classifier input

/// Full structured filesystem and content information about the managed
/// wrapper target, used as classifier input so the classifier remains
/// pure/testable. A canonical-path artifact is considered a valid
/// ACC-managed wrapper ONLY when ALL conditions hold:
/// - filesystem entry exists
/// - regular file (not directory/device)
/// - not a symlink (including dangling)
/// - executable
/// - contains the exact ownership marker in the expected header position
/// - parses as the narrow generated ACP invocation
/// - passes /bin/zsh -n syntax validation
struct ManagedWrapperFileInfo: Equatable, Sendable {
    /// Whether any filesystem entry exists at the managed wrapper path
    /// (regular file, symlink, directory, etc.).
    let entryExists: Bool
    /// Whether the entry is a symbolic link (even if dangling).
    let isSymbolicLink: Bool
    /// Whether the entry is an executable regular file (not a symlink).
    let isExecutableRegularFile: Bool
    /// Whether the entry contains the ownership marker in expected position.
    let hasOwnershipMarker: Bool
    /// Whether the entry parses as a valid ACP invocation.
    let parsesAsACPInvocation: Bool
    /// Whether the entry passes /bin/zsh -n syntax validation.
    let passesSyntaxValidation: Bool
    /// If the entry is invalid/unsafe, the structured reason.
    let invalidReason: ManagedArtifactInvalidReason?

    /// A well-formed managed wrapper that satisfies all ownership conditions.
    var isValidManagedWrapper: Bool {
        entryExists
            && !isSymbolicLink
            && isExecutableRegularFile
            && hasOwnershipMarker
            && parsesAsACPInvocation
            && passesSyntaxValidation
            && invalidReason == nil
    }

    /// No filesystem entry at all — safe for first-time install.
    var isAbsentAndSafe: Bool {
        !entryExists && invalidReason == nil
    }

    static let absent = ManagedWrapperFileInfo(
        entryExists: false,
        isSymbolicLink: false,
        isExecutableRegularFile: false,
        hasOwnershipMarker: false,
        parsesAsACPInvocation: false,
        passesSyntaxValidation: false,
        invalidReason: nil
    )

    /// Read actual filesystem state at the given URL (does not follow symlinks
    /// for the existence/type check). Validates content for ownership when
    /// the file is readable.
    static func read(
        at url: URL,
        syntaxValidator: ((URL) -> Bool)? = nil
    ) -> ManagedWrapperFileInfo {
        let fm = FileManager.default
        let path = url.path

        // POSIX lstat distinguishes a genuinely absent path from an
        // inspection failure and never follows the final symbolic link.
        // ENOTDIR means an ancestor component exists but is not a directory —
        // the canonical destination cannot be safely created, so it must be
        // reported as an inspection failure, not as "absent".
        var status = stat()
        let result = path.withCString { lstat($0, &status) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT {
                return .absent
            }
            // ENOTDIR: an ancestor component exists but is not a directory,
            // so the target itself cannot exist. It must still fail closed
            // (not "absent and safe") because the canonical destination
            // cannot be created at all.
            return makeInvalid(
                reason: .inspectionFailed(reason: String(cString: strerror(code))),
                entryExists: code == ENOTDIR ? false : true
            )
        }

        let fileType = status.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) {
            return makeInvalid(reason: .isSymbolicLink, isSymlink: true)
        }
        guard fileType == mode_t(S_IFREG) else {
            return makeInvalid(reason: .notRegularFile)
        }
        guard fm.isExecutableFile(atPath: path) else {
            return makeInvalid(reason: .notExecutable)
        }

        return validateContent(at: url, path: path, syntaxValidator: syntaxValidator)
    }

    /// Validates content of a readable executable regular file for ownership.
    private static func validateContent(
        at url: URL,
        path: String,
        syntaxValidator: ((URL) -> Bool)?
    ) -> ManagedWrapperFileInfo {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return makeInvalid(reason: .inspectionFailed(reason: error.localizedDescription), isExec: true)
        }

        guard contentHasOwnershipMarker(contents) else {
            return makeInvalid(reason: .missingOwnershipMarker, isExec: true)
        }
        guard ACPWrapperReader.isGeneratedManagedWrapper(contents) else {
            return makeInvalid(reason: .doesNotParseAsACPInvocation, isExec: true, hasMarker: true)
        }

        let passesValidation: Bool
        if let validator = syntaxValidator {
            passesValidation = validator(url)
        } else {
            let runner = ProcessRunner()
            passesValidation = runner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-n", path]
            ).exitCode == 0
        }
        guard passesValidation else {
            return makeInvalid(reason: .syntaxInvalid, isExec: true, hasMarker: true, parsesACP: true)
        }

        return ManagedWrapperFileInfo(
            entryExists: true,
            isSymbolicLink: false,
            isExecutableRegularFile: true,
            hasOwnershipMarker: true,
            parsesAsACPInvocation: true,
            passesSyntaxValidation: true,
            invalidReason: nil
        )
    }

    private static func makeInvalid(
        reason: ManagedArtifactInvalidReason,
        entryExists: Bool = true,
        isSymlink: Bool = false,
        isExec: Bool = false,
        hasMarker: Bool = false,
        parsesACP: Bool = false
    ) -> ManagedWrapperFileInfo {
        ManagedWrapperFileInfo(
            entryExists: entryExists,
            isSymbolicLink: isSymlink,
            isExecutableRegularFile: isExec,
            hasOwnershipMarker: hasMarker,
            parsesAsACPInvocation: parsesACP,
            passesSyntaxValidation: false,
            invalidReason: reason
        )
    }

    /// Checks that the ownership marker appears as a complete line in the
    /// expected header position (within the first few lines).
    private static func contentHasOwnershipMarker(_ contents: String) -> Bool {
        let lines = contents.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false)
        // Marker should be on line 2 (index 1) in generated wrappers
        return lines.prefix(4).contains {
            $0.trimmingCharacters(in: .whitespaces) == ACPWrapperManager.ownershipMarker
        }
    }
}

// MARK: - Lifecycle classifier

/// Pure/testable classifier. Determines lifecycle state from a provider
/// observation and managed-wrapper filesystem info at the exact canonical URL.
enum ACPWrapperLifecycleClassifier {
    /// Classifies the current lifecycle state.
    ///
    /// - Parameters:
    ///   - observation: Structured provider observation from ACPWrapperReader.
    ///   - managedFileInfo: Structured filesystem info about the managed
    ///     wrapper target (symlink-aware, marker-aware, syntax-aware).
    ///   - managedWrapperURL: The exact canonical managed wrapper URL
    ///     (standardized). Ownership requires exact match, not prefix or
    ///     symlink resolution.
    static func classify(
        observation: ACPProviderObservation,
        managedFileInfo: ManagedWrapperFileInfo,
        managedWrapperURL: URL
    ) -> ACPWrapperLifecycleContext {
        switch observation {
        case .noProvider:
            return classifyNoProvider(managedFileInfo: managedFileInfo)
        case .configuredPathMissing(let configuredPath):
            return classifyConfiguredPathMissing(
                configuredPath: configuredPath, managedFileInfo: managedFileInfo
            )
        case .wrapperInvalid(let wrapperURL, let reason):
            return classifyWrapperInvalid(
                wrapperURL: wrapperURL, reason: reason,
                managedFileInfo: managedFileInfo, managedWrapperURL: managedWrapperURL
            )
        case .wrapperValid(let configuration):
            return classifyWrapperValid(
                configuration: configuration,
                managedFileInfo: managedFileInfo, managedWrapperURL: managedWrapperURL
            )
        }
    }

    private static func classifyNoProvider(
        managedFileInfo: ManagedWrapperFileInfo
    ) -> ACPWrapperLifecycleContext {
        if managedFileInfo.isValidManagedWrapper {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperInactive,
                managedWrapperAvailable: true
            )
        }
        if managedFileInfo.entryExists {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperInvalid,
                invalidReason: managedFileInfo.invalidReason?.userDescription
                    ?? "Managed wrapper location contains an invalid or unrecognized entry",
                managedWrapperAvailable: false
            )
        }
        return ACPWrapperLifecycleContext(state: .noProvider)
    }

    private static func classifyConfiguredPathMissing(
        configuredPath: URL,
        managedFileInfo: ManagedWrapperFileInfo
    ) -> ACPWrapperLifecycleContext {
        if managedFileInfo.isValidManagedWrapper {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperInactive,
                configuredPath: configuredPath,
                managedWrapperAvailable: true
            )
        }
        if managedFileInfo.entryExists {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperInvalid,
                configuredPath: configuredPath,
                invalidReason: managedFileInfo.invalidReason?.userDescription
                    ?? "Managed wrapper location contains an invalid or unrecognized entry",
                managedWrapperAvailable: false
            )
        }
        return ACPWrapperLifecycleContext(
            state: .configuredPathMissing, configuredPath: configuredPath
        )
    }

    private static func classifyWrapperInvalid(
        wrapperURL: URL,
        reason: String,
        managedFileInfo: ManagedWrapperFileInfo,
        managedWrapperURL: URL
    ) -> ACPWrapperLifecycleContext {
        if isExactManagedPath(wrapperURL, managedWrapperURL: managedWrapperURL) {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperInvalid,
                configuredPath: wrapperURL,
                invalidReason: reason,
                managedWrapperAvailable: false
            )
        }
        let managedValid = managedFileInfo.isValidManagedWrapper
        let managedProblemNote: String? = (managedFileInfo.entryExists && !managedValid)
            ? managedFileInfo.invalidReason?.userDescription : nil
        return ACPWrapperLifecycleContext(
            state: .unmanagedWrapperInvalid,
            configuredPath: wrapperURL,
            invalidReason: reason,
            managedWrapperAvailable: managedValid,
            managedLocationProblemReason: managedProblemNote
        )
    }

    private static func classifyWrapperValid(
        configuration: ACPWrapperConfiguration,
        managedFileInfo: ManagedWrapperFileInfo,
        managedWrapperURL: URL
    ) -> ACPWrapperLifecycleContext {
        let managedValid = managedFileInfo.isValidManagedWrapper
        let isExactPath = isExactManagedPath(configuration.wrapperURL, managedWrapperURL: managedWrapperURL)

        if isExactPath && managedValid {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperActive,
                activeConfiguration: configuration,
                configuredPath: configuration.wrapperURL,
                managedWrapperAvailable: true
            )
        }
        if isExactPath && !managedValid {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperInvalid,
                configuredPath: configuration.wrapperURL,
                invalidReason: managedFileInfo.invalidReason?.userDescription
                    ?? "Managed wrapper fails ownership validation",
                managedWrapperAvailable: false
            )
        }
        if managedValid {
            return ACPWrapperLifecycleContext(
                state: .managedWrapperInactive,
                activeConfiguration: configuration,
                configuredPath: configuration.wrapperURL,
                managedWrapperAvailable: true
            )
        }
        return ACPWrapperLifecycleContext(
            state: .unmanagedWrapperActive,
            activeConfiguration: configuration,
            configuredPath: configuration.wrapperURL,
            managedWrapperAvailable: false,
            managedLocationProblemReason: (managedFileInfo.entryExists && !managedValid)
                ? managedFileInfo.invalidReason?.userDescription
                : nil
        )
    }

    /// Ownership check: exact standardized/canonical path equality.
    /// Symlinks resolving to the managed target do NOT count as owned.
    private static func isExactManagedPath(_ url: URL, managedWrapperURL: URL) -> Bool {
        url.standardizedFileURL.path == managedWrapperURL.standardizedFileURL.path
    }
}
