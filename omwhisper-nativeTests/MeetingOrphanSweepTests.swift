import Foundation
import Testing
@testable import OmWhisper

@Suite("Meeting orphan sweep")
struct MeetingOrphanSweepTests {
    @Test("a directory with no row is an orphan")
    func unknownDirectoryIsAnOrphan() {
        let orphans = MeetingOrphanSweep.orphans(
            onDisk: ["/m/2026-08-06_1000_Teams", "/m/2026-08-06_1100_Zoom"],
            known: ["/m/2026-08-06_1100_Zoom"])
        #expect(orphans == ["/m/2026-08-06_1000_Teams"])
    }

    @Test("a directory WITH a row is left alone")
    func knownDirectoryIsKept() {
        // The half that matters. A sweep that deletes everything passes the
        // test above; only this one fails it.
        let orphans = MeetingOrphanSweep.orphans(
            onDisk: ["/m/a", "/m/b"], known: ["/m/a", "/m/b"])
        #expect(orphans.isEmpty)
    }

    @Test("nothing on disk, nothing deleted")
    func emptyDiskIsSafe() {
        #expect(MeetingOrphanSweep.orphans(onDisk: [], known: ["/m/a"]).isEmpty)
    }
}
