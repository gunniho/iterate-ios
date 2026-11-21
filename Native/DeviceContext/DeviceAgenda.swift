import AppIntents
import CoreLocation
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

enum DeviceAgendaKind: String { case calendar = "Calendar", reminders = "Reminders" }

@MainActor
final class DeviceAgenda {
    private let store = EKEventStore()

    func events(on day: Date) async throws -> [DeviceAgendaEntry] {
        try await allowEvents(read: true)
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else {
            throw DeviceContextError("Choose another date.")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let time = event.isAllDay ? day.formatted(date: .abbreviated, time: .omitted) + ", all day" :
                    event.startDate.formatted(date: .abbreviated, time: .shortened) + " – " +
                    event.endDate.formatted(date: Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) ? .omitted : .abbreviated, time: .shortened)
                let details = [time, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return DeviceAgendaEntry(id: event.calendarItemIdentifier + String(event.startDate.timeIntervalSince1970),
                                        title: title.isEmpty ? "Untitled event" : title, details: details)
            }
    }

    func incompleteReminders() async throws -> [DeviceAgendaEntry] {
        try await allowReminders()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { @Sendable reminders in
                guard let reminders else {
                    continuation.resume(throwing: DeviceContextError("Reminders could not load this list."))
                    return
                }
                let entries = reminders.map { reminder -> (DeviceAgendaEntry, Date?) in
                    let components = reminder.dueDateComponents
                    let due = components.flatMap { ($0.calendar ?? .current).date(from: $0) }
                    let when = due.map { $0.formatted(date: .abbreviated, time: components?.hour == nil ? .omitted : .shortened) }
                    let details = [reminder.calendar.title, when].compactMap { $0 }.joined(separator: " · ")
                    return (.init(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled reminder", details: details), due)
                }
                let sorted = entries.sorted {
                    if $0.1 != $1.1 { return ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
                    return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
                }
                continuation.resume(returning: sorted.map(\.0))
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

    func createReminder(title: String, due: Date? = nil, place: DevicePlace? = nil, onArrival: Bool = true) async throws -> String {
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
        if let place {
            let region = EKStructuredLocation(title: place.label)
            region.geoLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            region.radius = 150
            let alarm = EKAlarm()
            alarm.structuredLocation = region
            alarm.proximity = onArrival ? .enter : .leave
            reminder.addAlarm(alarm)
        }
        try store.save(reminder, commit: true)
        let detail = place.map { (onArrival ? "Arriving at " : "Leaving ") + $0.label }
            ?? due.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? calendar.title
        return title + " — " + detail
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
