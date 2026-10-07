import EventKit
import Foundation

let eventLookaheadSecs: TimeInterval = 10 * 60
let eventStore = EKEventStore()

func eventSidecar(_ recording: String) -> String {
    recording.replacingOccurrences(of: ".m4a", with: ".event.json")
}

// 進行中か 10 分以内に始まる予定。録音は会議の少し前に始めることが多い
func currentCalendarEvents() -> [[String: Any]] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
    let now = Date()
    let predicate = eventStore.predicateForEvents(withStart: now, end: now.addingTimeInterval(eventLookaheadSecs), calendars: nil)
    let formatter = ISO8601DateFormatter()
    return eventStore.events(matching: predicate).filter { !$0.isAllDay }
        .sorted { $0.startDate < $1.startDate }.map { event in
        [
            "title": event.title ?? "",
            "start": formatter.string(from: event.startDate),
            "end": formatter.string(from: event.endDate),
            "attendees": (event.attendees ?? []).compactMap { $0.name },
        ]
    }
}

// 録音を促す対象。開始の少し前から、始まってしばらくの間に 1 回だけ出す
let reminderBeforeSecs: TimeInterval = 2 * 60
let reminderAfterSecs: TimeInterval = 5 * 60

func startingCalendarEvents() -> [EKEvent] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
    let now = Date()
    let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-reminderAfterSecs),
                                                  end: now.addingTimeInterval(reminderBeforeSecs), calendars: nil)
    return eventStore.events(matching: predicate).filter {
        !$0.isAllDay && $0.startDate >= now.addingTimeInterval(-reminderAfterSecs)
            && $0.startDate <= now.addingTimeInterval(reminderBeforeSecs)
    }
}
