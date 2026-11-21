import ContactsUI
import MusicKit
import SwiftUI

struct DevicePlaceView: View {
    let include: (String) -> Void
    @State private var place: DevicePlace?
    @State private var work: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        Form {
            Button("Find current place") {
                message = nil
                work = Task {
                    defer { work = nil }
                    do { place = try await DeviceLocation().currentPlace() }
                    catch { if !Task.isCancelled { message = error.localizedDescription } }
                }
            }.disabled(work != nil)
            if work != nil { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let place {
                Section("Current place") {
                    Text(place.label)
                    Button("Include in request") { include(place.label) }
                    NavigationLink("Add a place reminder") {
                        AgendaEditor(kind: .reminders, place: place, include: include)
                    }
                }
            }
        }
        .navigationTitle("Current place")
        .onDisappear { work?.cancel() }
    }
}

struct DeviceHealthView: View {
    let include: (String) -> Void
    @State private var day = Date.now
    @State private var result: String?
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        Form {
            DatePicker("Day", selection: $day, in: ...Date.now, displayedComponents: .date).disabled(loading)
            Button("Read steps") {
                result = nil
                message = nil
                loading = true
                Task {
                    defer { loading = false }
                    do { result = try await DeviceHealth.steps(on: day) }
                    catch { message = error.localizedDescription }
                }
            }.disabled(loading)
            if loading { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let result {
                Text(result)
                Button("Include in request") { include(result) }
            }
        }
        .onChange(of: day) { _, _ in
            result = nil
            message = nil
        }
        .navigationTitle("Steps")
    }
}

private struct PickedContact {
    let name: String
    let details: [String]
}

private struct SystemContactPicker: UIViewControllerRepresentable {
    let choose: (PickedContact) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(choose: choose, cancel: cancel) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let choose: (PickedContact) -> Void
        let cancel: () -> Void
        init(choose: @escaping (PickedContact) -> Void, cancel: @escaping () -> Void) {
            self.choose = choose
            self.cancel = cancel
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { cancel() }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let required = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
            let name = contact.areKeysAvailable([required]) ? CNContactFormatter.string(from: contact, style: .fullName) : nil
            var fields: [String] = []
            if contact.isKeyAvailable(CNContactPhoneNumbersKey) { fields += contact.phoneNumbers.map { $0.value.stringValue } }
            if contact.isKeyAvailable(CNContactEmailAddressesKey) { fields += contact.emailAddresses.map { $0.value as String } }
            choose(.init(name: name ?? "Contact", details: fields))
        }
    }
}

struct DeviceContactsView: View {
    let include: (String) -> Void
    @State private var picking = false
    @State private var contact: PickedContact?

    var body: some View {
        List {
            Button("Choose in Contacts") { picking = true }
            if let contact {
                Section("Include in request") {
                    Button(contact.name) { include(contact.name) }
                    ForEach(Array(contact.details.enumerated()), id: \.offset) { _, detail in
                        Button(detail) { include(contact.name + " — " + detail) }
                    }
                }
            }
        }
        .navigationTitle("Contacts")
        .sheet(isPresented: $picking) {
            SystemContactPicker(choose: { chosen in
                contact = chosen
                picking = false
            }, cancel: { picking = false })
        }
    }
}

struct DeviceHomeView: View {
    let include: (String) -> Void
    @State private var home = DeviceHome()
    @State private var confirmation: DeviceHome.Scene?
    @State private var executing = false
    @State private var feedback: String?

    var body: some View {
        List {
            if !home.status.isEmpty { Text(home.status).foregroundStyle(.secondary) }
            if let feedback { Text(feedback).font(.footnote) }
            ForEach(home.scenes) { scene in
                Section(scene.label) {
                    Button("Include scene in request") { include(scene.label) }
                    Button("Run scene") { confirmation = scene }.disabled(executing)
                }
            }
        }
        .navigationTitle("Home scenes")
        .task { home.load() }
        .alert(item: $confirmation) { scene in
            Alert(title: Text("Run \(scene.action.name)?"), message: Text(scene.home.name),
                  primaryButton: .default(Text("Run")) {
                      executing = true
                      feedback = nil
                      Task {
                          defer { executing = false }
                          do {
                              try await home.run(scene)
                              feedback = "Ran \(scene.label)."
                          }
                          catch { feedback = error.localizedDescription }
                      }
                  }, secondaryButton: .cancel())
        }
    }
}

struct DeviceMusicView: View {
    let include: (String) -> Void
    @State private var term = ""
    @State private var source = DeviceMusic.Source.library
    @State private var songs = [Song]()
    @State private var selected: Song?
    @State private var busy = false
    @State private var feedback: String?

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: $source) { ForEach(DeviceMusic.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .disabled(busy)
                TextField(source == .library ? "Song title (optional)" : "Title or artist", text: $term)
                Button(source == .library && term.isEmpty ? "Browse library" : "Search") { search() }.disabled(busy)
                if busy { ProgressView() }
                if let feedback { Text(feedback).foregroundStyle(.secondary) }
            }
            if let selected {
                Section(selected.title + " · " + selected.artistName) {
                    Button("Include in request") { include(selected.title + " — " + selected.artistName) }
                    Button("Play") {
                        busy = true
                        feedback = nil
                        Task {
                            defer { busy = false }
                            do {
                                try await DeviceMusic.play(selected, source: source)
                                feedback = "Playing \(selected.title)."
                            }
                            catch { feedback = error.localizedDescription }
                        }
                    }.disabled(busy)
                }
            }
            ForEach(songs, id: \.id) { song in
                Button { selected = song } label: {
                    VStack(alignment: .leading) {
                        Text(song.title)
                        Text(song.artistName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Music")
        .onChange(of: source) { _, _ in
            songs.removeAll()
            selected = nil
            feedback = nil
        }
    }

    private func search() {
        busy = true
        feedback = nil
        selected = nil
        Task {
            defer { busy = false }
            do {
                songs = try await DeviceMusic.songs(term: term, source: source)
                if songs.isEmpty { feedback = "No songs matched." }
            } catch {
                songs.removeAll()
                feedback = error.localizedDescription
            }
        }
    }
}
