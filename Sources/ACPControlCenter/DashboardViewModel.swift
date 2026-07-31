import Foundation
import Observation

/// Composes the read-only readers into a single dashboard snapshot for the
/// menu bar UI. Performs no writes and never opens Kiro IDE or executes the
/// ACP wrapper as an agent.
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var snapshot: DashboardSnapshot?
    private(set) var isRefreshing: Bool = false
    private var refreshGeneration: UInt = 0
    private var hasStartedInitialRefresh: Bool = false

    private let cliResolver: KiroCLIResolver
    private let usageReader: KiroUsageReader
    private let liveUsageReader: KiroUsageLiveReader?
    private let modelReader: KiroModelObservationReader
    private let wrapperReader: ACPWrapperReader

    /// Directories surfaced for diagnostic purposes so the user can inspect
    /// real data without the app claiming to interpret more than it parsed.
    let usageLogsRoot: URL
    let modelLogsRoot: URL

    init(
        cliResolver: KiroCLIResolver = KiroCLIResolver(),
        usageReader: KiroUsageReader = KiroUsageReader(),
        liveUsageReader: KiroUsageLiveReader? = KiroUsageLiveReader(),
        modelReader: KiroModelObservationReader = KiroModelObservationReader(),
        wrapperReader: ACPWrapperReader = ACPWrapperReader(),
        usageLogsRoot: URL = KiroUsageReader.defaultLogsRoot(),
        modelLogsRoot: URL = KiroModelObservationReader.defaultLogsRoot()
    ) {
        self.cliResolver = cliResolver
        self.usageReader = usageReader
        self.liveUsageReader = liveUsageReader
        self.modelReader = modelReader
        self.wrapperReader = wrapperReader
        self.usageLogsRoot = usageLogsRoot
        self.modelLogsRoot = modelLogsRoot
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
        // NSDecimalNumber.stringValue produces a plain decimal representation
        // without grouping separators or scientific notation, and omits
        // unnecessary trailing zeros automatically.
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

    /// Re-reads all sources. Safe to call repeatedly; each call is a fresh,
    /// read-only pass over local files.
    ///
    /// Usage data strategy:
    /// 1. If a `liveUsageReader` is configured, attempt a live CLI request
    ///    first (`kiro-cli chat --no-interactive '/usage'`).
    /// 2. If the live request succeeds, use its result with `.liveCLI` source.
    /// 3. If it fails (not logged in, timeout, parse error, CLI missing),
    ///    fall back to the local `q-client.log` reader with `.localLog`
    ///    source, preserving the stale timestamp.
    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }

        // File enumeration, log decoding, and short process invocations can
        // take noticeable time. Keep them off MainActor so opening or
        // refreshing the menu does not freeze the UI.
        let cliResolver = self.cliResolver
        let usageReader = self.usageReader
        let liveUsageReader = self.liveUsageReader
        let modelReader = self.modelReader
        let wrapperReader = self.wrapperReader

        async let cli = Task.detached { cliResolver.resolve() }.value
        async let usage = Task.detached {
            Self.resolveUsage(live: liveUsageReader, local: usageReader)
        }.value
        async let model = Task.detached { modelReader.readLatestObservation() }.value
        async let wrapper = Task.detached { wrapperReader.readWrapperConfiguration() }.value

        let (resolvedCLI, accountUsage, observedModel, wrapperConfiguration) =
            await (cli, usage, model, wrapper)

        // If a newer refresh started or the SwiftUI task was cancelled while
        // readers were working, discard this older result rather than
        // overwriting fresher state.
        guard refreshGeneration == generation, !Task.isCancelled else { return }

        snapshot = DashboardSnapshot(
            cli: resolvedCLI,
            accountUsage: accountUsage,
            observedModel: observedModel,
            wrapper: wrapperConfiguration,
            refreshedAt: Date()
        )
    }

    /// Attempts a live usage fetch first, falling back to local log if it
    /// fails. Runs off MainActor.
    private nonisolated static func resolveUsage(
        live: KiroUsageLiveReader?,
        local: KiroUsageReader
    ) -> Result<KiroAccountUsage, ReaderError> {
        if let live {
            let liveResult = live.fetchLiveUsage()
            switch liveResult {
            case .success(let liveUsage):
                // Convert to KiroAccountUsage with .liveCLI source.
                // sourceURL is nil because there is no backing file for
                // live CLI responses.
                return .success(KiroAccountUsage(
                    used: liveUsage.used,
                    limit: liveUsage.limit,
                    currentOverages: nil,
                    resetDate: liveUsage.resetDate,
                    subscriptionTitle: liveUsage.planName,
                    overageStatus: nil,
                    observedAt: liveUsage.observedAt,
                    sourceURL: nil,
                    source: .liveCLI
                ))
            case .failure:
                // Fall through to local reader
                break
            }
        }

        // Fallback: local q-client.log reader (source is already .localLog)
        return local.readLatestUsage()
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
    /// Never includes profile ARNs, emails, request IDs, prompts, or message
    /// content. File paths are emitted with the user's home-directory prefix
    /// replaced by `~` to reduce incidental PII exposure.
    func diagnosticSummary(now: Date = Date(), redactor: PathRedactor = PathRedactor()) -> String {
        guard let snapshot else {
            return "ACP Control Center diagnostic summary\nNo data has been read yet."
        }

        var lines: [String] = []
        lines.append("ACP Control Center diagnostic summary")
        lines.append("Generated: \(Self.iso8601.string(from: now))")
        lines.append("")

        lines.append("CLI")
        lines.append("  Executable: \(redactor.redact(snapshot.cli.executableURL))")
        if let resolved = snapshot.cli.resolvedExecutableURL {
            lines.append("  Resolved target: \(redactor.redact(resolved))")
        }
        lines.append("  Executable permission: \(snapshot.cli.isExecutable)")
        lines.append("  Version: \(snapshot.cli.version ?? "unknown")")
        lines.append("")

        lines.append("Account usage")
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

    private static func describeUsageSource(_ source: UsageSource) -> String {
        switch source {
        case .liveCLI:
            return "live Kiro CLI"
        case .localLog:
            return "local log (fallback)"
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

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
