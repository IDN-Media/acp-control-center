import Foundation
import Observation

/// Errors indicating why a Work Package A setup operation was denied.
enum WrapperSetupAuthorizationError: Error, Equatable, Sendable {
    case lifecycleStateProhibitsSetup(ACPWrapperLifecycleState)
    case cliNotReady
    case managedDestinationNotEmpty
}

/// Composes local readers and the explicitly confirmed managed-wrapper flow.
/// It never modifies Kiro/Xcode files, opens Kiro IDE, or executes a wrapper.
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var snapshot: DashboardSnapshot?
    private(set) var isRefreshing: Bool = false
    private(set) var liveUsageStatus: KiroLiveUsageStatus = .notAttempted
    private(set) var wrapperManagerStatus: ACPWrapperManagerStatus = .idle
    private(set) var wrapperPreview: ACPWrapperPreview?
    private(set) var managedWrapperExists = false
    private(set) var lifecycleContext: ACPWrapperLifecycleContext = ACPWrapperLifecycleContext(
        state: .noProvider, activeConfiguration: nil, configuredPath: nil
    )
    private var refreshGeneration: UInt = 0
    private var hasStartedInitialRefresh: Bool = false
    private var selectedCLIURL: URL?
    private var providerObservation: ACPProviderObservation = .noProvider

    private let cliResolver: KiroCLIResolver
    private let usageReader: KiroUsageReader
    private let configuredLiveUsageReader: KiroUsageLiveReader?
    private let modelReader: KiroModelObservationReader
    private let wrapperReader: ACPWrapperReader
    private let wrapperManager: ACPWrapperManager
    private let cliSelectionStore: KiroCLISelectionStore

    /// Directories surfaced for diagnostic purposes so the user can inspect
    /// real data without the app claiming to interpret more than it parsed.
    let usageLogsRoot: URL
    let modelLogsRoot: URL

    init(
        cliResolver: KiroCLIResolver = KiroCLIResolver(),
        usageReader: KiroUsageReader = KiroUsageReader(),
        liveUsageReader: KiroUsageLiveReader? = nil,
        modelReader: KiroModelObservationReader = KiroModelObservationReader(),
        wrapperReader: ACPWrapperReader = ACPWrapperReader(),
        wrapperManager: ACPWrapperManager = ACPWrapperManager(),
        cliSelectionStore: KiroCLISelectionStore = KiroCLISelectionStore(),
        usageLogsRoot: URL = KiroUsageReader.defaultLogsRoot(),
        modelLogsRoot: URL = KiroModelObservationReader.defaultLogsRoot()
    ) {
        self.cliResolver = cliResolver
        self.usageReader = usageReader
        self.configuredLiveUsageReader = liveUsageReader
        self.modelReader = modelReader
        self.wrapperReader = wrapperReader
        self.wrapperManager = wrapperManager
        self.cliSelectionStore = cliSelectionStore
        self.selectedCLIURL = cliResolver.acceptsPersistedSelection
            ? cliSelectionStore.load()
            : nil
        self.usageLogsRoot = usageLogsRoot
        self.modelLogsRoot = modelLogsRoot
        self.managedWrapperExists = wrapperManager.managedWrapperExists
    }

    var managedWrapperURL: URL {
        wrapperManager.wrapperURL
    }

    // MARK: - Menu bar label

    /// The compact usage/status text displayed beside the emoji in the menu
    /// bar HStack. Before any data: `…`. Success: `USED / LIMIT`. Local-log
    /// fallback: `USED / LIMIT ⚠`. Unavailable: `—`.
    var menuBarStatusText: String {
        guard let snapshot else { return "\u{2026}" }
        switch snapshot.accountUsage {
        case .success(let usage):
            let usedStr = Self.formatDecimalCredits(usage.used)
            let limitStr = Self.formatDecimalCredits(usage.limit)
            let base = "\(usedStr) / \(limitStr)"
            if usage.source == .localLog {
                return base + " \u{26A0}"
            }
            return base
        case .failure:
            return "\u{2014}"
        }
    }

    /// Dynamic accessibility label for the combined menu bar item. Uses
    /// exact decimal values (not rounded) so VoiceOver reads precise credits.
    var menuBarAccessibilityLabel: String {
        guard let snapshot else { return "Kiro credits loading" }
        switch snapshot.accountUsage {
        case .success(let usage):
            let usedStr = "\(usage.used)"
            let limitStr = "\(usage.limit)"
            let base = "Kiro credits: \(usedStr) of \(limitStr) used"
            if usage.source == .localLog {
                return base + ", local log fallback"
            }
            return base
        case .failure:
            return "Kiro credits unavailable"
        }
    }

    /// Formats a Decimal as a locale-stable plain decimal string for the
    /// menu bar label. No grouping separators, no scientific notation, and
    /// no unnecessary trailing zeros (e.g. 1000, not 1000.00; 771.21, not
    /// 771.210).
    static func formatDecimalCredits(_ value: Decimal) -> String {
        return (value as NSDecimalNumber).stringValue
    }

    // MARK: - Initial refresh

    /// Called once to trigger automatic startup refresh. Guards against
    /// duplicate overlapping calls if the dashboard view appears multiple
    /// times (popover open/close). Returns immediately if already started.
    func performInitialRefreshIfNeeded() async {
        guard !hasStartedInitialRefresh else { return }
        hasStartedInitialRefresh = true
        await refresh()
    }

    // MARK: - Refresh

    /// Re-reads all sources. Provider observation is the single
    /// structured read; the snapshot's wrapper Result is derived from it.
    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }

        let cliResolver = self.cliResolver
        let usageReader = self.usageReader
        let configuredLiveUsageReader = self.configuredLiveUsageReader
        let modelReader = self.modelReader
        let wrapperReader = self.wrapperReader
        let selectedCLIURL = self.selectedCLIURL

        async let cli = Task.detached {
            cliResolver.resolve(preferredExecutableURL: selectedCLIURL)
        }.value
        async let model = Task.detached { modelReader.readLatestObservation() }.value
        // Single structured read — only readProviderObservation()
        async let providerObs = Task.detached {
            wrapperReader.readProviderObservation()
        }.value

        let resolvedCLI = await cli
        let liveUsageReader = configuredLiveUsageReader ?? Self.makeLiveUsageReader(for: resolvedCLI)
        async let usage = Task.detached {
            Self.resolveUsage(live: liveUsageReader, local: usageReader)
        }.value

        let (usageResolution, observedModel, providerObservation) = await (usage, model, providerObs)
        self.providerObservation = providerObservation

        guard refreshGeneration == generation, !Task.isCancelled else { return }

        if selectedCLIURL != nil, resolvedCLI.discoverySource != .selected {
            self.selectedCLIURL = nil
            cliSelectionStore.save(nil)
        }

        // Derive wrapper Result from the single observation
        let wrapperResult = ACPWrapperReader.wrapperResult(from: providerObservation)

        snapshot = DashboardSnapshot(
            cli: resolvedCLI,
            accountUsage: usageResolution.result,
            observedModel: observedModel,
            wrapper: wrapperResult,
            refreshedAt: Date()
        )
        liveUsageStatus = usageResolution.status

        let fileInfo = wrapperManager.managedFileInfo
        managedWrapperExists = fileInfo.isValidManagedWrapper
        lifecycleContext = ACPWrapperLifecycleClassifier.classify(
            observation: providerObservation,
            managedFileInfo: fileInfo,
            managedWrapperURL: wrapperManager.wrapperURL
        )
    }

    /// Reclassifies the lifecycle from the most recently read provider
    /// observation and a fresh managed-file inspection. Used after an
    /// install so the UI reflects the true post-install state instead of a
    /// synthetic context.
    private func classifiedLifecycleContext() -> ACPWrapperLifecycleContext {
        let fileInfo = wrapperManager.managedFileInfo
        managedWrapperExists = fileInfo.isValidManagedWrapper
        return ACPWrapperLifecycleClassifier.classify(
            observation: providerObservation,
            managedFileInfo: fileInfo,
            managedWrapperURL: wrapperManager.wrapperURL
        )
    }

    func searchAgain() async {
        guard let currentSnapshot = snapshot else {
            await refresh()
            return
        }
        await performFocusedRefresh { [self] generation in
            let selectedCLIURL = self.selectedCLIURL
            let cliResolver = self.cliResolver
            let usageReader = self.usageReader
            let configuredLiveUsageReader = self.configuredLiveUsageReader
            let resolvedCLI = await Task.detached {
                cliResolver.resolve(preferredExecutableURL: selectedCLIURL)
            }.value
            let liveReader = configuredLiveUsageReader ?? Self.makeLiveUsageReader(for: resolvedCLI)
            let usageResolution = await Task.detached {
                Self.resolveUsage(live: liveReader, local: usageReader)
            }.value

            guard self.refreshGeneration == generation, !Task.isCancelled else { return }
            if selectedCLIURL != nil, resolvedCLI.discoverySource != .selected {
                self.selectedCLIURL = nil
                self.cliSelectionStore.save(nil)
            }
            self.snapshot = DashboardSnapshot(
                cli: resolvedCLI,
                accountUsage: usageResolution.result,
                observedModel: currentSnapshot.observedModel,
                wrapper: currentSnapshot.wrapper,
                refreshedAt: Date()
            )
            self.liveUsageStatus = usageResolution.status
        }
    }

    func chooseExecutable(_ url: URL) async {
        selectedCLIURL = url.standardizedFileURL
        cliSelectionStore.save(selectedCLIURL)
        await searchAgain()
    }

    func refreshAccountUsage() async {
        guard let currentSnapshot = snapshot else {
            await refresh()
            return
        }
        await performFocusedRefresh { [self] generation in
            let liveReader = self.configuredLiveUsageReader
                ?? Self.makeLiveUsageReader(for: currentSnapshot.cli)
            let usageReader = self.usageReader
            let usageResolution = await Task.detached {
                Self.resolveUsage(live: liveReader, local: usageReader)
            }.value
            guard self.refreshGeneration == generation, !Task.isCancelled else { return }
            self.snapshot = DashboardSnapshot(
                cli: currentSnapshot.cli,
                accountUsage: usageResolution.result,
                observedModel: currentSnapshot.observedModel,
                wrapper: currentSnapshot.wrapper,
                refreshedAt: Date()
            )
            self.liveUsageStatus = usageResolution.status
        }
    }

    func rescanXcode() async {
        guard let currentSnapshot = snapshot else {
            await refresh()
            return
        }
        // Start each rescan from a clean slate so a stale failure from a
        // previous operation (e.g. a migration attempt in an earlier session)
        // cannot linger in the status area after the state has moved on.
        wrapperManagerStatus = .idle
        wrapperPreview = nil
        await performFocusedRefresh { [self] generation in
            let wrapperReader = self.wrapperReader
            let wrapperManager = self.wrapperManager
            // Single structured read for rescan
            let observation = await Task.detached {
                wrapperReader.readProviderObservation()
            }.value
            guard self.refreshGeneration == generation, !Task.isCancelled else { return }

            let wrapperResult = ACPWrapperReader.wrapperResult(from: observation)
            self.snapshot = DashboardSnapshot(
                cli: currentSnapshot.cli,
                accountUsage: currentSnapshot.accountUsage,
                observedModel: currentSnapshot.observedModel,
                wrapper: wrapperResult,
                refreshedAt: Date()
            )
            let fileInfo = wrapperManager.managedFileInfo
            self.managedWrapperExists = fileInfo.isValidManagedWrapper
            self.lifecycleContext = ACPWrapperLifecycleClassifier.classify(
                observation: observation,
                managedFileInfo: fileInfo,
                managedWrapperURL: wrapperManager.wrapperURL
            )
        }
    }

    // MARK: - Managed wrapper (Work Package A first-install only)

    /// States from which Work Package A setup is allowed.
    private static let setupAllowedStates: Set<ACPWrapperLifecycleState> = [
        .noProvider, .configuredPathMissing
    ]

    /// Checks all Work Package A preconditions for prepare/install.
    /// Returns nil if authorized, or an error describing why not.
    private func checkSetupAuthorization() -> WrapperSetupAuthorizationError? {
        guard Self.setupAllowedStates.contains(lifecycleContext.state) else {
            return .lifecycleStateProhibitsSetup(lifecycleContext.state)
        }
        guard snapshot?.cli.availability == .ready else {
            return .cliNotReady
        }
        // First-install requires the managed target to be completely absent
        let fileInfo = wrapperManager.managedFileInfo
        if fileInfo.entryExists {
            return .managedDestinationNotEmpty
        }
        return nil
    }

    func prepareWrapperPreview(modelID: String?, effort: ACPWrapperEffort?) async {
        if let authError = checkSetupAuthorization() {
            wrapperManagerStatus = .failed(message: Self.describeAuthError(authError))
            return
        }
        guard let cliURL = snapshot?.cli.executableURL else {
            wrapperManagerStatus = .failed(message: "Choose a ready Kiro CLI executable first.")
            return
        }
        await performFocusedRefresh { [self] generation in
            let manager = self.wrapperManager
            let request = ACPWrapperRequest(
                cliExecutableURL: cliURL,
                modelID: modelID,
                effort: effort
            )
            do {
                let preview = try await Task.detached {
                    try manager.firstInstallPreview(request)
                }.value
                guard self.refreshGeneration == generation, !Task.isCancelled else { return }
                self.wrapperPreview = preview
                self.wrapperManagerStatus = .previewReady
            } catch {
                guard self.refreshGeneration == generation else { return }
                self.wrapperPreview = nil
                self.wrapperManagerStatus = .failed(message: Self.describeWrapperManagerError(error))
            }
        }
    }

    func installWrapperPreview() async {
        guard let preview = wrapperPreview else {
            wrapperManagerStatus = .failed(message: "Preview the wrapper before installing it.")
            return
        }
        // Re-check authorization at install time (race detection)
        if let authError = checkSetupAuthorization() {
            wrapperManagerStatus = .failed(message: Self.describeAuthError(authError))
            return
        }
        await performFocusedRefresh { [self] generation in
            let manager = self.wrapperManager
            do {
                _ = try await Task.detached {
                    try manager.firstInstall(preview)
                }.value
                guard self.refreshGeneration == generation, !Task.isCancelled else { return }
                self.managedWrapperExists = manager.managedWrapperExists
                self.wrapperPreview = nil
                // Reclassify from fresh provider observation + managed-file info
                // rather than hard-coding a synthetic context. This keeps the
                // post-install state truthful if a concurrent process removed
                // or replaced the wrapper between install and refresh.
                self.lifecycleContext = self.classifiedLifecycleContext()
                self.wrapperManagerStatus = self.managedWrapperExists ? .installed : .failed(
                    message: "Wrapper installed but is no longer valid at the managed path."
                )
            } catch {
                guard self.refreshGeneration == generation else { return }
                self.wrapperManagerStatus = .failed(message: Self.describeWrapperManagerError(error))
            }
        }
    }

    // Rollback and backup browsing are not exposed in Work Package A.
    // The low-level ACPWrapperManager implementation is retained for
    // internal use and future Work Packages.

    func clearWrapperPreview() {
        wrapperPreview = nil
        if wrapperManagerStatus == .previewReady {
            wrapperManagerStatus = .idle
        }
    }

    /// Resets the wrapper manager status area to a clean slate. Called when
    /// the manager window opens so a stale failure from a previous session
    /// cannot linger after the lifecycle state has moved on.
    func resetWrapperManagerStatus() {
        wrapperPreview = nil
        wrapperManagerStatus = .idle
    }

    // MARK: - Unmanaged wrapper migration (Work Package B)

    /// Prepares a migration preview by reading the currently active unmanaged
    /// wrapper (the one Xcode is using) and re-rendering it into the managed
    /// ACC format. The source file is never modified.
    func prepareMigrationPreview() async {
        guard let active = lifecycleContext.activeConfiguration else {
            wrapperManagerStatus = .failed(message: "No active unmanaged wrapper to migrate.")
            return
        }
        await performFocusedRefresh { [self] generation in
            let manager = self.wrapperManager
            do {
                let preview = try await Task.detached {
                    try manager.migratePreview(from: active.wrapperURL)
                }.value
                guard self.refreshGeneration == generation, !Task.isCancelled else { return }
                self.wrapperPreview = preview
                self.wrapperManagerStatus = .previewReady
            } catch {
                guard self.refreshGeneration == generation else { return }
                self.wrapperPreview = nil
                self.wrapperManagerStatus = .failed(message: Self.describeWrapperManagerError(error))
            }
        }
    }

    /// Installs the staged migration preview (re-rendered ACC format) into the
    /// managed location, then reclassifies from fresh provider observation so
    /// the UI reflects the true post-migration state. The source unmanaged
    /// wrapper is left untouched.
    func installMigrationPreview() async {
        guard let preview = wrapperPreview else {
            wrapperManagerStatus = .failed(message: "Preview the wrapper before migrating it.")
            return
        }
        await performFocusedRefresh { [self] generation in
            let manager = self.wrapperManager
            do {
                _ = try await Task.detached {
                    try manager.migrateInstall(preview)
                }.value
                guard self.refreshGeneration == generation, !Task.isCancelled else { return }
                self.managedWrapperExists = manager.managedWrapperExists
                self.wrapperPreview = nil
                self.lifecycleContext = self.classifiedLifecycleContext()
                self.wrapperManagerStatus = self.managedWrapperExists ? .installed : .failed(
                    message: "Wrapper migrated but is no longer valid at the managed path."
                )
            } catch {
                guard self.refreshGeneration == generation else { return }
                self.wrapperManagerStatus = .failed(message: Self.describeWrapperManagerError(error))
            }
        }
    }

    private func performFocusedRefresh(_ operation: (UInt) async -> Void) async {
        guard !isRefreshing else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }
        await operation(generation)
    }

    private nonisolated static func makeLiveUsageReader(
        for installation: KiroCLIInstallation
    ) -> KiroUsageLiveReader? {
        guard installation.availability == .ready,
              let executableURL = installation.executableURL else {
            return nil
        }
        return KiroUsageLiveReader(cliExecutableURL: executableURL)
    }

    /// Attempts a live usage fetch first, falling back to local log if it
    /// fails. Runs off MainActor.
    private struct UsageResolution: Sendable {
        let result: Result<KiroAccountUsage, ReaderError>
        let status: KiroLiveUsageStatus
    }

    private nonisolated static func resolveUsage(
        live: KiroUsageLiveReader?,
        local: KiroUsageReader
    ) -> UsageResolution {
        if let live {
            let liveResult = live.fetchLiveUsage()
            switch liveResult {
            case .success(let liveUsage):
                return UsageResolution(result: .success(KiroAccountUsage(
                    used: liveUsage.used,
                    limit: liveUsage.limit,
                    currentOverages: nil,
                    resetDate: liveUsage.resetDate,
                    subscriptionTitle: liveUsage.planName,
                    overageStatus: nil,
                    observedAt: liveUsage.observedAt,
                    sourceURL: nil,
                    source: .liveCLI
                )), status: .ready)
            case .failure(let error):
                return UsageResolution(
                    result: local.readLatestUsage(),
                    status: status(for: error)
                )
            }
        }

        return UsageResolution(result: local.readLatestUsage(), status: .cliUnavailable)
    }

    private nonisolated static func status(
        for error: KiroUsageLiveReader.LiveReaderError
    ) -> KiroLiveUsageStatus {
        switch error {
        case .cliNotExecutable:
            return .cliUnavailable
        case .notLoggedIn:
            return .authenticationRequired
        case .sessionExpired:
            return .sessionExpired
        case .timeout:
            return .timedOut
        case .permissionDenied:
            return .permissionDenied
        case .commandFailed:
            return .commandFailed
        case .parseFailed:
            return .parseFailed
        }
    }

    /// Freshness classification for the current usage observation, if any.
    func usageAvailability(now: Date = Date()) -> DataAvailability {
        guard let snapshot else { return .missing }
        switch snapshot.accountUsage {
        case .success(let usage):
            return DataAvailability.classify(age: now.timeIntervalSince(usage.observedAt))
        case .failure(.missing):
            return .missing
        case .failure(.invalid(let reason)), .failure(.ioFailure(let reason)):
            return .invalid(reason: reason)
        }
    }

    /// Builds a plain-text diagnostic summary containing only structural
    /// state: paths, versions, freshness, and parsed configuration flags.
    func diagnosticSummary(now: Date = Date(), redactor: PathRedactor = PathRedactor()) -> String {
        guard let snapshot else {
            return "ACP Control Center diagnostic summary\nNo data has been read yet."
        }

        var lines: [String] = []
        lines.append("ACP Control Center diagnostic summary")
        lines.append("Generated: \(Self.iso8601.string(from: now))")
        lines.append("")

        lines.append("CLI")
        if let executableURL = snapshot.cli.executableURL {
            lines.append("  Executable: \(redactor.redact(executableURL))")
        } else {
            lines.append("  Executable: not found")
        }
        if let resolved = snapshot.cli.resolvedExecutableURL {
            lines.append("  Resolved target: \(redactor.redact(resolved))")
        }
        lines.append("  Discovery state: \(Self.describe(snapshot.cli.availability))")
        lines.append("  Executable permission: \(snapshot.cli.isExecutable)")
        lines.append("  Version: \(snapshot.cli.version ?? "unknown")")
        lines.append("")

        lines.append("Account usage")
        lines.append("  Live state: \(Self.describe(liveUsageStatus))")
        switch snapshot.accountUsage {
        case .success(let usage):
            lines.append("  Source: \(Self.describeUsageSource(usage.source))")
            lines.append("  Used: \(usage.used)")
            lines.append("  Limit: \(usage.limit)")
            if let overages = usage.currentOverages {
                lines.append("  Current overages: \(overages)")
            }
            lines.append("  Plan: \(usage.subscriptionTitle ?? "unknown")")
            if let overageStatus = usage.overageStatus {
                lines.append("  Overage status: \(overageStatus)")
            }
            if let resetDate = usage.resetDate {
                lines.append("  Resets: \(Self.iso8601.string(from: resetDate))")
            }
            lines.append("  Observed at: \(Self.iso8601.string(from: usage.observedAt))")
            lines.append("  Freshness: \(Self.describe(DataAvailability.classify(age: now.timeIntervalSince(usage.observedAt))))")
            if usage.source == .localLog, let sourceFile = usage.sourceURL {
                lines.append("  Source file: \(redactor.redact(sourceFile))")
            }
        case .failure(let error):
            lines.append("  State: \(Self.describe(error, redactor: redactor))")
        }
        lines.append("")

        lines.append("Latest observed model activity")
        switch snapshot.observedModel {
        case .success(let observation):
            lines.append("  Model: \(observation.modelID)")
            lines.append("  Agent mode: \(observation.agentMode ?? "unknown")")
            lines.append("  Origin: \(observation.origin ?? "unknown")")
            lines.append("  Client: \(observation.clientName ?? "unknown")")
            lines.append("  Attribution: \(observation.source.rawValue)")
            lines.append("  Observed at: \(Self.iso8601.string(from: observation.observedAt))")
            lines.append("  Source file: \(redactor.redact(observation.sourceURL))")
        case .failure(let error):
            lines.append("  State: \(Self.describe(error, redactor: redactor))")
        }
        lines.append("")

        lines.append("ACP wrapper")
        switch snapshot.wrapper {
        case .success(let wrapper):
            lines.append("  Wrapper: \(redactor.redact(wrapper.wrapperURL))")
            lines.append("  CLI executable: \(wrapper.cliExecutableURL.map { redactor.redact($0) } ?? "unspecified")")
            lines.append("  Model: \(wrapper.modelID ?? "unspecified")")
            lines.append("  Effort: \(wrapper.effort ?? "unspecified")")
            lines.append("  Executable permission: \(wrapper.isExecutable)")
            lines.append("  Syntax valid: \(wrapper.syntaxIsValid)")
        case .failure(let error):
            lines.append("  State: \(Self.describe(error, redactor: redactor))")
        }

        return lines.joined(separator: "\n")
    }

    private static func describeAuthError(_ error: WrapperSetupAuthorizationError) -> String {
        switch error {
        case .lifecycleStateProhibitsSetup(let state):
            return "Setup is not available in the current state (\(state))."
        case .cliNotReady:
            return "Kiro CLI must be ready before creating a wrapper."
        case .managedDestinationNotEmpty:
            return "A file already exists at the managed wrapper destination. Cannot perform first-time setup."
        }
    }

    private static func describeUsageSource(_ source: UsageSource) -> String {
        switch source {
        case .liveCLI:
            return "live Kiro CLI"
        case .localLog:
            return "local log (fallback)"
        }
    }

    private static func describe(_ availability: KiroCLIAvailability) -> String {
        switch availability {
        case .ready:
            return "ready"
        case .notFound:
            return "not found"
        case .notExecutable:
            return "not executable"
        case .launchFailed(let reason):
            return "launch failed (\(reason))"
        }
    }

    private static func describe(_ status: KiroLiveUsageStatus) -> String {
        switch status {
        case .notAttempted:
            return "not attempted"
        case .ready:
            return "ready"
        case .cliUnavailable:
            return "CLI unavailable"
        case .authenticationRequired:
            return "authentication required"
        case .sessionExpired:
            return "session expired"
        case .timedOut:
            return "timed out"
        case .permissionDenied:
            return "permission denied"
        case .commandFailed:
            return "command failed"
        case .parseFailed:
            return "parse failed"
        }
    }

    private static func describe(_ error: ReaderError, redactor: PathRedactor? = nil) -> String {
        let redactReason: (String) -> String = { reason in
            redactor?.redactText(reason) ?? reason
        }
        switch error {
        case .missing(let reason):
            return "missing (\(redactReason(reason)))"
        case .invalid(let reason):
            return "invalid (\(redactReason(reason)))"
        case .ioFailure(let reason):
            return "I/O failure (\(redactReason(reason)))"
        }
    }

    private static func describe(_ availability: DataAvailability) -> String {
        switch availability {
        case .available:
            return "available"
        case .aging:
            return "aging"
        case .stale:
            return "stale"
        case .missing:
            return "missing"
        case .invalid(let reason):
            return "invalid (\(reason))"
        }
    }

    private static func describeWrapperManagerError(_ error: Error) -> String {
        guard let managerError = error as? ACPWrapperManagerError else {
            return "Wrapper operation failed."
        }
        switch managerError {
        case .invalidExecutablePath:
            return "The selected Kiro CLI path is not valid for a managed wrapper."
        case .invalidModelID:
            return "The model ID contains unsupported characters."
        case .destinationChanged:
            return "The wrapper changed after preview. Preview it again before installing."
        case .syntaxValidationFailed:
            return "The generated wrapper failed zsh syntax validation. Nothing was installed."
        case .postWriteVerificationFailed:
            return "Wrapper verification failed after installation. The previous version was restored."
        case .unmanagedBackup:
            return "Only backups created by ACP Control Center can be restored."
        case .firstInstallDestinationNotEmpty:
            return "A file already exists at the managed wrapper destination. Cannot perform first-time setup."
        case .ioFailure(let reason):
            return reason
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
