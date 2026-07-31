import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `KiroUsageReader` covering the current schema, precision
/// fallback, malformed-newest-record fallback, and missing-CREDIT cases from
/// the plan's test fixture matrix.
struct KiroUsageReaderTests {
    /// Copies a fixture log into a fresh temp directory laid out like the
    /// real logs root (`<root>/<session>/window1/exthost/kiro.kiroAgent/q-client.log`)
    /// so directory discovery exercises the same recursive enumeration used
    /// against real data.
    private func makeLogsRoot(withFixtures fixtureNames: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (index, fixtureName) in fixtureNames.enumerated() {
            let sessionDir = root
                .appendingPathComponent("session\(index)")
                .appendingPathComponent("window1")
                .appendingPathComponent("exthost")
                .appendingPathComponent("kiro.kiroAgent")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let sourceURL = FixtureLocator.url("usage/\(fixtureName)")
            let destinationURL = sessionDir.appendingPathComponent("q-client.log")
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        return root
    }

    @Test
    func currentSchemaIsParsed() throws {
        let root = try makeLogsRoot(withFixtures: ["usage-current-schema.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroUsageReader(logsRoot: root)
        let result = reader.readLatestUsage()

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "637.63"))
        #expect(usage.limit == Decimal(1000))
        #expect(usage.currentOverages == Decimal(0))
        #expect(usage.subscriptionTitle == "KIRO PRO")
        #expect(usage.overageStatus == "DISABLED")
        #expect(usage.resetDate != nil)
    }

    @Test
    func precisionFieldsFallBackToNonPrecisionFields() throws {
        let root = try makeLogsRoot(withFixtures: ["usage-precision-fallback.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroUsageReader(logsRoot: root)
        let result = reader.readLatestUsage()

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(410))
        #expect(usage.limit == Decimal(1000))
        #expect(usage.currentOverages == Decimal(0))
    }

    @Test
    func malformedNewestRecordFallsBackToOlderValidRecord() throws {
        let root = try makeLogsRoot(withFixtures: ["usage-malformed-latest.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroUsageReader(logsRoot: root)
        let result = reader.readLatestUsage()

        guard case .success(let usage) = result else {
            Issue.record("Expected success falling back to older valid record, got \(result)")
            return
        }
        // Only the 2026-07-18 record is valid JSON; the 2026-07-19 line is malformed.
        #expect(usage.used == Decimal(string: "200.5"))
    }

    @Test
    func missingCreditResourceIsReportedAsInvalid() throws {
        let root = try makeLogsRoot(withFixtures: ["usage-no-credit.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroUsageReader(logsRoot: root)
        let result = reader.readLatestUsage()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .invalid = error else {
            Issue.record("Expected .invalid, got \(error)")
            return
        }
    }

    @Test
    func missingLogsRootReturnsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Deliberately do not create the directory.
        let reader = KiroUsageReader(logsRoot: root)
        let result = reader.readLatestUsage()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .missing = error else {
            Issue.record("Expected .missing, got \(error)")
            return
        }
    }

    @Test
    func newestRecordIsSelectedAcrossMultipleFiles() throws {
        // usage-current-schema.log (2026-07-26) is newer than
        // usage-precision-fallback.log (2026-07-20); the reader must select
        // by parsed record timestamp, not file order.
        let root = try makeLogsRoot(withFixtures: ["usage-precision-fallback.log", "usage-current-schema.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroUsageReader(logsRoot: root)
        let result = reader.readLatestUsage()

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.used == Decimal(string: "637.63"))
    }
}
