import AppIntents
import EventKit
import Foundation

struct DeviceContextError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DeviceAgendaEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let details: String
    var text: String { details.isEmpty ? title : title + " — " + details }
}

struct DeviceEvent: Sendable {
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
}

struct DeviceReminder: Sendable {
    let id: String
    let title: String
    let list: String
    let due: Date?
    /// A reminder due on a day has no hour.
    let timed: Bool
}

@MainActor
final class DeviceAgenda {
    private let store = EKEventStore()

    func events(on day: Date) async throws -> [DeviceAgendaEntry] {
        try await events(from: day, days: 1).map { event in
            let time = event.allDay ? day.formatted(date: .abbreviated, time: .omitted) + ", all day" :
                event.start.formatted(date: .abbreviated, time: .shortened) + " – " +
                event.end.formatted(date: Calendar.current.isDate(event.start, inSameDayAs: event.end) ? .omitted : .abbreviated, time: .shortened)
            let details = [time, event.location].compactMap { $0 }.joined(separator: " · ")
            return DeviceAgendaEntry(id: UUID().uuidString, title: event.title, details: details)
        }
    }

    /// The events of whole days, the first being the day of `day`.
    func events(from day: Date, days: Int) async throws -> [DeviceEvent] {
        try await allowEvents(read: true)
        let start = Calendar.current.startOfDay(for: day)
        guard days > 0, let end = Calendar.current.date(byAdding: .day, value: days, to: start) else {
            throw DeviceContextError("Choose another date.")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let location = event.location.flatMap { $0.isEmpty ? nil : $0 }
                return DeviceEvent(title: title.isEmpty ? "Untitled event" : title, start: event.startDate, end: event.endDate,
                                   allDay: event.isAllDay, location: location)
            }
    }

    func incompleteReminders() async throws -> [DeviceAgendaEntry] {
        try await reminders().map { reminder in
            let when = reminder.due.map { $0.formatted(date: .abbreviated, time: reminder.timed ? .shortened : .omitted) }
            return .init(id: reminder.id, title: reminder.title, details: [reminder.list, when].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// The reminders that are not done, the soonest due first.
    func reminders() async throws -> [DeviceReminder] {
        try await allowReminders()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { @Sendable reminders in
                guard let reminders else {
                    continuation.resume(throwing: DeviceContextError("Reminders could not load this list."))
                    return
                }
                let found = reminders.map { reminder in
                    let components = reminder.dueDateComponents
                    return DeviceReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled reminder",
                                          list: reminder.calendar.title,
                                          due: components.flatMap { ($0.calendar ?? .current).date(from: $0) },
                                          timed: components?.hour != nil)
                }
                continuation.resume(returning: found.sorted {
                    if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                })
            }
        }
    }

    func createEvent(title: String, start: Date, end: Date) async throws -> String {
        let title = try validated(title)
        guard end > start else { throw DeviceContextError("Choose an end time after the start.") }
        try await allowEvents(read: false)
        guard let calendar = store.defaultCalendarForNewEvents else { throw DeviceContextError("Set up a writable calendar on this iPhone first.") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = calendar
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent)
        return "\(title) — \(start.formatted(date: .abbreviated, time: .shortened)), \(calendar.title)"
    }

    func createReminder(title: String, due: Date? = nil) async throws -> String {
        let title = try validated(title)
        try await allowReminders()
        guard let calendar = store.defaultCalendarForNewReminders() else { throw DeviceContextError("Set up a Reminders list on this iPhone first.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let due {
            var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            parts.calendar = Calendar.current
            parts.timeZone = .current
            reminder.dueDateComponents = parts
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return title + " — " + (due.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? calendar.title)
    }

    private func validated(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 512 else { throw DeviceContextError("Enter a title of 1 to 512 characters.") }
        return text
    }

    private func allowEvents(read: Bool) async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess || (!read && status == .writeOnly) { return }
        guard status == .notDetermined || (read && status == .writeOnly) else {
            throw DeviceContextError("Allow Iterate access to Calendar in Settings.")
        }
        let granted = read ? try await store.requestFullAccessToEvents() : try await store.requestWriteOnlyAccessToEvents()
        guard granted else { throw DeviceContextError("Calendar access was declined.") }
    }

    private func allowReminders() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return
        case .notDetermined:
            guard try await store.requestFullAccessToReminders() else { throw DeviceContextError("Reminders access was declined.") }
        default: throw DeviceContextError("Allow Iterate access to Reminders in Settings.")
        }
    }
}

struct ReadIterateCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Calendar Events for Iterate"
    static let description = IntentDescription("Return the events on a chosen day for use in a shortcut.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Day") var day: Date?

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let items = try await DeviceAgenda().events(on: day ?? .now)
        return .result(value: items.isEmpty ? "No events on this day." : items.map(\.text).joined(separator: "\n"))
    }
}

struct ReadIterateRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Incomplete Reminders for Iterate"
    static let description = IntentDescription("Return the next incomplete reminders, ordered by due date.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Maximum reminders", default: 10) var maximum: Int

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard (1...50).contains(maximum) else { throw DeviceContextError("Choose between 1 and 50 reminders.") }
        let items = try await DeviceAgenda().incompleteReminders().prefix(maximum)
        return .result(value: items.isEmpty ? "No incomplete reminders." : items.map(\.text).joined(separator: "\n"))
    }
}

struct CreateIterateCalendarEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Calendar Event with Iterate"
    static let description = IntentDescription("Create an event with a title, start time, and end time in your default calendar.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Event title") var name: String
    @Parameter(title: "Start") var start: Date
    @Parameter(title: "End") var end: Date

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await DeviceAgenda().createEvent(title: name, start: start, end: end))
    }
}

struct CreateIterateReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Reminder with Iterate"
    static let description = IntentDescription("Create a personal reminder in your default list.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Reminder title") var name: String
    @Parameter(title: "Due") var due: Date?

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await DeviceAgenda().createReminder(title: name, due: due))
    }
}
