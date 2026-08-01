import Foundation
import Testing
@testable import OmWhisper

@Suite("MeetingCalendar")
struct MeetingCalendarTests {
    private func date(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: Double(minutes) * 60)
    }

    @Test func picksGreatestOverlap() {
        // Recording 10:00–10:50. Event A 09:00–10:10 (10 min overlap),
        // event B 10:00–11:00 (50 min overlap) → B.
        let idx = MeetingCalendar.bestMatchIndex(
            candidates: [(date(540), date(610)), (date(600), date(660))],
            windowStart: date(600), windowEnd: date(650))
        #expect(idx == 1)
    }

    @Test func noOverlapMeansNoMatch() {
        let idx = MeetingCalendar.bestMatchIndex(
            candidates: [(date(0), date(60))],
            windowStart: date(600), windowEnd: date(650))
        #expect(idx == nil)
    }

    @Test func emptyCandidatesMeansNoMatch() {
        #expect(MeetingCalendar.bestMatchIndex(
            candidates: [], windowStart: date(0), windowEnd: date(1)) == nil)
    }
}
