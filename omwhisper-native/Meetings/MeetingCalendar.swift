//
//  MeetingCalendar.swift
//  OmWhisper
//
//  Read-only EventKit lookup: which calendar event overlaps a finished
//  recording's time window? Gives meetings a real title ("Q3 Planning") and
//  attendee names. Opt-in via AppState.meetingsCalendarEnabled — enabling the
//  toggle is what triggers the macOS Calendar permission prompt. Local data
//  only; nothing is written and nothing egresses.
//
//  nonisolated: called from recordFinishedMeeting (MainActor) but has no UI
//  affinity — matches CallDetection/MeetingStore's convention.
//

import EventKit
import Foundation

nonisolated enum MeetingCalendar {
    struct Match: Equatable {
        var title: String
        var attendees: [String]
    }

    static func hasAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Triggers the system prompt on first call (macOS 14+ full-access API).
    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Pure: index of the candidate with the greatest positive time-overlap
    /// with the recording window; nil when nothing overlaps at all.
    static func bestMatchIndex(
        candidates: [(start: Date, end: Date)], windowStart: Date, windowEnd: Date
    ) -> Int? {
        let overlaps = candidates.map {
            MeetingDiarization.overlap(
                $0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970,
                windowStart.timeIntervalSince1970, windowEnd.timeIntervalSince1970)
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }),
              overlaps[best] > 0 else { return nil }
        return best
    }

    /// Effectful: the best-overlapping non-all-day event for a recording window.
    /// All-day events are excluded — one would swallow every recording that day.
    /// The current user is dropped from attendees (they're the recorder).
    static func match(start: Date, end: Date) -> Match? {
        guard hasAccess() else { return nil }
        let store = EKEventStore()
        let events = store
            .events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
        guard let index = bestMatchIndex(
            candidates: events.map { ($0.startDate, $0.endDate) },
            windowStart: start, windowEnd: end
        ) else { return nil }
        let event = events[index]
        let attendees = (event.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .compactMap(\.name)
        return Match(title: event.title ?? "", attendees: attendees)
    }
}
