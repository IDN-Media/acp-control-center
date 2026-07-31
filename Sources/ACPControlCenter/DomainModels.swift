import Foundation

// MARK: - Reader errors

/// Errors surfaced by the read-only reader layer. Every reader reports
/// failures through `Result` so the UI can distinguish "no data yet" from
/// "data exists but could not be parsed".
enum ReaderError: Error, Equatable, Sendable {
    case missing(reason: String)
    case invalid(reason: String)
    case ioFailure(reason: String)
}

// MARK: - CLI resolution

enum KiroCLIDiscoverySource: String, Equatable, Sendable {
    case selected
    case knownLocation
}

enum KiroCLIAvailability: Equatable, Sendable {
    case ready
    case notFound
    case notExecutable
    case launchFailed(reason: String)
}

struct KiroCLIInstallation: Equatable, Sendable {
    let executableURL: URL?
    let resolvedExecutableURL: URL?
    let version: String?
    let discoverySource: KiroCLIDiscoverySource?
    let availability: KiroCLIAvailability
    let isExecutable: Bool
}

// MARK: - Freshness

/// Freshness classification for an observed timestamp, per the plan's
/// freshness semantics table (15 min / 24 hr thresholds).
enum DataAvailability: Equatable, Sendable {
    case available
    case aging
    case stale
    case missing
    case invalid(reason: String)

    /// Classify an observation age against the plan-defined thresholds.
    static func classify(age: TimeInterval) -> DataAvailability {
        let allowedClockSkew: TimeInterval = 5 * 60
        let fifteenMinutes: TimeInterval = 15 * 60
        let twentyFourHours: TimeInterval = 24 * 60 * 60
        if age < -allowedClockSkew {
            return .invalid(reason: "Observation timestamp is in the future")
        } else if age <= fifteenMinutes {
            return .available
        } else if age <= twentyFourHours {
            return .aging
        } else {
            return .stale
        }
    }
}

// MARK: - Account usage

/// Identifies the source of a usage reading so the UI can clearly
/// communicate whether data came from a live control-plane request or
/// a local log file fallback.
enum UsageSource: Equatable, Sendable {
    /// Live data fetched via `kiro-cli chat --no-interactive '/usage'`.
    case liveCLI
    /// Fallback data parsed from local `q-client.log` files.
    case localLog
}

enum KiroLiveUsageStatus: Equatable, Sendable {
    case notAttempted
    case ready
    case cliUnavailable
    case authenticationRequired
    case sessionExpired
    case timedOut
    case permissionDenied
    case commandFailed
    case parseFailed
}

struct KiroAccountUsage: Equatable, Sendable {
    let used: Decimal
    let limit: Decimal
    let currentOverages: Decimal?
    let resetDate: Date?
    let subscriptionTitle: String?
    let overageStatus: String?
    let observedAt: Date
    /// The log file this reading was parsed from. `nil` for live CLI
    /// responses (which have no backing file).
    let sourceURL: URL?
    /// Identifies whether this reading is from a live CLI request or a
    /// local-log fallback.
    let source: UsageSource

    /// Backwards-compatible initializer that defaults to `.localLog`.
    init(
        used: Decimal,
        limit: Decimal,
        currentOverages: Decimal? = nil,
        resetDate: Date? = nil,
        subscriptionTitle: String? = nil,
        overageStatus: String? = nil,
        observedAt: Date,
        sourceURL: URL? = nil,
        source: UsageSource = .localLog
    ) {
        self.used = used
        self.limit = limit
        self.currentOverages = currentOverages
        self.resetDate = resetDate
        self.subscriptionTitle = subscriptionTitle
        self.overageStatus = overageStatus
        self.observedAt = observedAt
        self.sourceURL = sourceURL
        self.source = source
    }
}

// MARK: - Model observation

enum ModelSource: String, Equatable, Sendable {
    case kiroCLI
    case aiEditor
    case unknown
}

struct ModelObservation: Equatable, Sendable {
    let modelID: String
    let agentMode: String?
    let origin: String?
    let clientName: String?
    let observedAt: Date
    let source: ModelSource
    let sourceURL: URL
}

// MARK: - ACP wrapper

struct ACPWrapperConfiguration: Equatable, Sendable {
    let wrapperURL: URL
    let cliExecutableURL: URL?
    let modelID: String?
    let effort: String?
    let isExecutable: Bool
    let syntaxIsValid: Bool
}

// MARK: - Dashboard snapshot

struct DashboardSnapshot: Equatable, Sendable {
    let cli: KiroCLIInstallation
    let accountUsage: Result<KiroAccountUsage, ReaderError>
    let observedModel: Result<ModelObservation, ReaderError>
    let wrapper: Result<ACPWrapperConfiguration, ReaderError>
    let refreshedAt: Date

    static func == (lhs: DashboardSnapshot, rhs: DashboardSnapshot) -> Bool {
        lhs.cli == rhs.cli
            && lhs.refreshedAt == rhs.refreshedAt
            && resultsEqual(lhs.accountUsage, rhs.accountUsage)
            && resultsEqual(lhs.observedModel, rhs.observedModel)
            && resultsEqual(lhs.wrapper, rhs.wrapper)
    }
}

/// `Result` is not automatically `Equatable` even when both associated types
/// are, so we compare manually to keep `DashboardSnapshot` diffable in tests
/// and SwiftUI state comparisons.
private func resultsEqual<T: Equatable>(_ lhs: Result<T, ReaderError>, _ rhs: Result<T, ReaderError>) -> Bool {
    switch (lhs, rhs) {
    case (.success(let left), .success(let right)):
        return left == right
    case (.failure(let left), .failure(let right)):
        return left == right
    default:
        return false
    }
}
