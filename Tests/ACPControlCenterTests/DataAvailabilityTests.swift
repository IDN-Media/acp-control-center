import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for the `DataAvailability.classify(age:)` freshness thresholds
/// from the plan's freshness semantics table.
struct DataAvailabilityTests {
    @Test
    func withinFifteenMinutesIsAvailable() {
        #expect(DataAvailability.classify(age: 60) == .available)
        #expect(DataAvailability.classify(age: 15 * 60) == .available)
    }

    @Test
    func betweenFifteenMinutesAndTwentyFourHoursIsAging() {
        #expect(DataAvailability.classify(age: 15 * 60 + 1) == .aging)
        #expect(DataAvailability.classify(age: 24 * 60 * 60) == .aging)
    }

    @Test
    func beyondTwentyFourHoursIsStale() {
        #expect(DataAvailability.classify(age: 24 * 60 * 60 + 1) == .stale)
    }

    @Test
    func futureTimestampBeyondClockSkewIsInvalid() {
        guard case .invalid = DataAvailability.classify(age: -301) else {
            Issue.record("Expected a timestamp more than five minutes in the future to be invalid")
            return
        }
        #expect(DataAvailability.classify(age: -300) == .available)
    }
}
