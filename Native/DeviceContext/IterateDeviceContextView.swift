import SwiftUI

struct IterateDeviceContextView: View {
    let include: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Calendar and Reminders") {
                    NavigationLink { AgendaSelection(kind: .calendar, include: use) } label: { Label("Choose events", systemImage: "calendar") }
                    NavigationLink { AgendaSelection(kind: .reminders, include: use) } label: { Label("Choose reminders", systemImage: "list.bullet") }
                    NavigationLink { AgendaEditor(kind: .calendar, include: use) } label: { Label("Add an event", systemImage: "calendar.badge.plus") }
                    NavigationLink { AgendaEditor(kind: .reminders, include: use) } label: { Label("Add a reminder", systemImage: "plus.circle") }
                }
                Section("From this iPhone") {
                    NavigationLink { DeviceContactsView(include: use) } label: { Label("Choose a contact", systemImage: "person.crop.circle") }
                    NavigationLink { DevicePlaceView(include: use) } label: { Label("Current place", systemImage: "location") }
                    NavigationLink { DeviceHealthView(include: use) } label: { Label("Steps", systemImage: "figure.walk") }
                    NavigationLink { DeviceHomeView(include: use) } label: { Label("Home scenes", systemImage: "house") }
                    NavigationLink { DeviceMusicView(include: use) } label: { Label("Music", systemImage: "music.note") }
                }
            }
            .navigationTitle("iPhone context")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func use(_ text: String) {
        include(text)
        dismiss()
    }
}

private struct AgendaSelection: View {
    let kind: DeviceAgendaKind
    let include: (String) -> Void
    @State private var day = Date.now
    @State private var entries = [DeviceAgendaEntry]()
    @State private var selected = Set<String>()
    @State private var loading = true
    @State private var error: String?
    @State private var revision = 0

    var body: some View {
        List {
            if kind == .calendar { DatePicker("Day", selection: $day, displayedComponents: .date) }
            if loading { ProgressView() }
            else if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Try again") { revision += 1 }
            } else if entries.isEmpty {
                Text(kind == .calendar ? "No events on this day." : "No incomplete reminders.")
            }
            ForEach(entries) { entry in
                Button {
                    if !selected.insert(entry.id).inserted { selected.remove(entry.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.title).foregroundStyle(.primary)
                            Text(entry.details).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
                .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected : [])
            }
        }
        .navigationTitle(kind.rawValue)
        .toolbar {
            if !selected.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Include \(selected.count)") {
                        include(entries.filter { selected.contains($0.id) }.map(\.text).joined(separator: "\n"))
                    }
                }
            }
        }
        .task(id: "\(Calendar.current.startOfDay(for: day).timeIntervalSince1970)-\(revision)") {
            loading = true
            selected.removeAll()
            entries.removeAll()
            error = nil
            do {
                let agenda = DeviceAgenda()
                let new = kind == .calendar ? try await agenda.events(on: day) : try await agenda.incompleteReminders()
                try Task.checkCancellation()
                entries = new
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct AgendaEditor: View {
    let kind: DeviceAgendaKind
    var place: DevicePlace?
    let include: (String) -> Void
    @State private var title = ""
    @State private var start = Date.now
    @State private var end = Date.now.addingTimeInterval(3600)
    @State private var hasDue = false
    @State private var arrival = true
    @State private var saving = false
    @State private var message: String?
    @State private var saved: String?

    var body: some View {
        Form {
            if let saved {
                Section("Added to " + kind.rawValue) {
                    Text(saved)
                    Button("Include in request") { include(saved) }
                }
            } else {
                TextField("Title", text: $title)
                if kind == .calendar {
                    DatePicker("Starts", selection: $start)
                    DatePicker("Ends", selection: $end)
                } else if let place {
                    LabeledContent("Place", value: place.label)
                    Picker("Remind me", selection: $arrival) {
                        Text("When I arrive").tag(true)
                        Text("When I leave").tag(false)
                    }
                } else {
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue { DatePicker("Due", selection: $start) }
                }
                Button(kind == .calendar ? "Add to Calendar" : "Add to Reminders") { create() }
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saving { ProgressView() }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(kind == .calendar ? "New event" : "New reminder")
        .onChange(of: start) { _, date in if end <= date { end = date.addingTimeInterval(3600) } }
    }

    private func create() {
        guard !saving else { return }
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                let agenda = DeviceAgenda()
                if kind == .calendar { saved = try await agenda.createEvent(title: title, start: start, end: end) }
                else { saved = try await agenda.createReminder(title: title, due: hasDue ? start : nil, place: place, onArrival: arrival) }
            } catch { message = error.localizedDescription }
        }
    }
}
