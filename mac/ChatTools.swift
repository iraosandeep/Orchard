import EventKit
import Foundation
import FoundationModels

private func toolSchema(_ properties: [DynamicGenerationSchema.Property]) -> GenerationSchema {
    try! GenerationSchema(
        root: DynamicGenerationSchema(name: "Arguments", properties: properties), dependencies: [])
}

private actor EventKitReader {
    static let shared = EventKitReader()
    private let store = EKEventStore()

    func events(when: String) async throws -> String {
        guard try await store.requestFullAccessToEvents() else {
            throw ToolAccessError.denied("Calendar access is off. Enable it in Orchard Settings.")
        }
        let calendar = Calendar.current
        let now = Date()
        let start: Date
        let end: Date
        let label: String
        switch when {
        case "today":
            start = calendar.startOfDay(for: now)
            end = calendar.date(byAdding: .day, value: 1, to: start)!
            label = "Today"
        case "tomorrow":
            start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            end = calendar.date(byAdding: .day, value: 1, to: start)!
            label = "Tomorrow"
        case "yesterday":
            end = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .day, value: -1, to: end)!
            label = "Yesterday"
        case "this week":
            start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            end = calendar.dateInterval(of: .weekOfYear, for: now)!.end
            label = "This week"
        case "next week":
            let current = calendar.dateInterval(of: .weekOfYear, for: now)!
            start = current.end
            end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            label = "Next week"
        case "this weekend":
            let weekday = calendar.component(.weekday, from: now)
            let daysUntilSaturday = weekday == 1 ? -1 : (7 - weekday) % 7
            let saturday = calendar.date(byAdding: .day, value: daysUntilSaturday, to: calendar.startOfDay(for: now))!
            start = saturday
            end = calendar.date(byAdding: .day, value: 2, to: saturday)!
            label = "This weekend"
        case "next 30 days":
            start = calendar.startOfDay(for: now)
            end = calendar.date(byAdding: .day, value: 30, to: start)!
            label = "The next 30 days"
        default:
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            guard let target = names.firstIndex(of: when.lowercased()) else {
                throw ToolAccessError.denied("I couldn't determine the requested date.")
            }
            let currentDay = calendar.component(.weekday, from: now) - 1
            let delta = (target - currentDay + 7) % 7
            start = calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: now))!
            end = calendar.date(byAdding: .day, value: 1, to: start)!
            label = calendar.isDateInToday(start) ? "Today" : DateFormatter.localizedString(from: start, dateStyle: .full, timeStyle: .none)
        }

        let results = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        guard !results.isEmpty else { return "\(label): no calendar events." }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let lines = results.prefix(100).map { event in
            let time = event.isAllDay ? "All day" : "\(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate))"
            return "- \(time) \(event.title ?? "Untitled")\(event.location.map { " (\($0))" } ?? "")"
        }
        return "\(label):\n" + lines.joined(separator: "\n")
    }

    func reminders() async throws -> String {
        guard try await store.requestFullAccessToReminders() else {
            throw ToolAccessError.denied("Reminders access is off. Enable it in Orchard Settings.")
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let items: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        let sorted = items.sorted {
            switch ($0.dueDateComponents?.date, $1.dueDateComponents?.date) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            default: ($0.title ?? "") < ($1.title ?? "")
            }
        }
        guard !sorted.isEmpty else { return "No open reminders." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Open reminders:\n" + sorted.prefix(100).map { item in
            let due = item.dueDateComponents?.date.map { " (due \(formatter.string(from: $0)))" } ?? ""
            return "- \(item.title ?? "Untitled")\(due)"
        }.joined(separator: "\n")
    }
}

private enum ToolAccessError: LocalizedError {
    case denied(String)
    var errorDescription: String? { if case .denied(let message) = self { message } else { nil } }
}

struct CalendarEventsTool: Tool {
    let name = "getCalendarEvents"
    let description = "Read calendar events for a requested day or date range. Use for questions about schedules, meetings, plans, and availability."
    var parameters: GenerationSchema {
        let days = ["today", "tomorrow", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "this week", "next week", "this weekend", "next 30 days"]
        return toolSchema([.init(name: "when", description: "The requested day or range. A weekday means the next one, including today.", schema: DynamicGenerationSchema(name: "When", anyOf: days))])
    }
    func call(arguments: GeneratedContent) async throws -> String {
        let when = try arguments.value(String.self, forProperty: "when")
        return try await EventKitReader.shared.events(when: when)
    }
}

struct RemindersTool: Tool {
    let name = "getReminders"
    let description = "Read the user's incomplete reminders and due dates. Use for questions about to-dos, reminders, and what is due."
    var parameters: GenerationSchema { toolSchema([]) }
    func call(arguments: GeneratedContent) async throws -> String {
        try await EventKitReader.shared.reminders()
    }
}
