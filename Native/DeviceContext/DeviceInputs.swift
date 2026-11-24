import Contacts
import CoreLocation
import HealthKit
import HomeKit
import MapKit
import MusicKit

struct DevicePlace: Sendable {
    let label: String
    let latitude: Double
    let longitude: Double
}

@MainActor
final class DeviceLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation, Error>?
    private var requestID: UUID?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentPlace() async throws -> DevicePlace {
        guard requestID == nil else { throw DeviceContextError("A location request is already in progress.") }
        let id = UUID()
        requestID = id
        let location: CLLocation = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                    return
                }
                if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
                else { requestAuthorizedLocation() }
            }
        } onCancel: {
            Task { @MainActor in if self.requestID == id { self.finish(.failure(CancellationError())) } }
        }
        try Task.checkCancellation()
        let name: String?
        if #available(iOS 26.0, *) {
            if let request = MKReverseGeocodingRequest(location: location),
               let first = try? await request.mapItems.first { name = first.address?.fullAddress ?? first.name }
            else { name = nil }
        } else {
            let place = try? await CLGeocoder().reverseGeocodeLocation(location).first
            name = [place?.name, place?.locality, place?.country].compactMap { $0 }.joined(separator: ", ")
        }
        try Task.checkCancellation()
        let latitude = location.coordinate.latitude, longitude = location.coordinate.longitude
        let coordinates = "\(latitude.formatted(.number.precision(.fractionLength(4)))), \(longitude.formatted(.number.precision(.fractionLength(4))))"
        return DevicePlace(label: name.flatMap { $0.isEmpty ? nil : $0 } ?? coordinates, latitude: latitude, longitude: longitude)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waiting != nil, manager.authorizationStatus != .notDetermined else { return }
        requestAuthorizedLocation()
    }

    private func requestAuthorizedLocation() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            guard timeout == nil else { return }
            timeout = Task {
                do { try await Task.sleep(for: .seconds(18)) } catch { return }
                finish(.failure(DeviceContextError("iPhone could not find your current location. Try again nearby.")))
            }
            manager.requestLocation()
        case .notDetermined: break
        default: finish(.failure(DeviceContextError("Allow location access for Iterate in Settings to choose your current place.")))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else {
            finish(.failure(DeviceContextError("iPhone did not return a usable location.")))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<CLLocation, Error>) {
        let continuation = waiting
        waiting = nil
        requestID = nil
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        continuation?.resume(with: result)
    }
}

enum DeviceHealth {
    static func steps(on day: Date) async throws -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { throw DeviceContextError("Health data is unavailable on this device.") }
        let start = Calendar.current.startOfDay(for: day)
        guard let following = Calendar.current.date(byAdding: .day, value: 1, to: start), start <= .now else {
            throw DeviceContextError("Choose today or an earlier day.")
        }
        let store = HKHealthStore()
        let type = HKQuantityType(.stepCount)
        try await store.requestAuthorization(toShare: [], read: [type])
        let predicate = HKQuery.predicateForSamples(withStart: start, end: min(following, .now), options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum)
        let statistics = try await descriptor.result(for: store)
        guard let quantity = statistics?.sumQuantity() else {
            throw DeviceContextError("No readable step data for this day. You can review Iterate’s access in Health.")
        }
        return Int(quantity.doubleValue(for: .count()).rounded())
    }
}

struct DeviceContact: Sendable {
    let name: String
    let organization: String?
    let phones: [String]
    let emails: [String]
}

enum DeviceContacts {
    static func find(_ name: String) async throws -> [DeviceContact] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw DeviceContextError("Give a name to look for.") }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            guard try await CNContactStore().requestAccess(for: .contacts) else { throw DeviceContextError("Contacts access was declined.") }
        case .denied, .restricted: throw DeviceContextError("Allow Iterate access to Contacts in Settings.")
        default: break
        }
        // The store reads from disk, so the search stays off the main thread.
        return try await Task.detached {
            let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
                        CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
            return try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
                .prefix(20).map { contact in
                    let organization = contact.organizationName.isEmpty ? nil : contact.organizationName
                    return DeviceContact(name: CNContactFormatter.string(from: contact, style: .fullName) ?? organization ?? "Contact",
                                         organization: organization,
                                         phones: contact.phoneNumbers.map { $0.value.stringValue },
                                         emails: contact.emailAddresses.map { $0.value as String })
                }
        }.value
    }
}

@MainActor
final class DeviceHome: NSObject, @preconcurrency HMHomeManagerDelegate {
    static let shared = DeviceHome()

    struct Scene {
        let home: HMHome
        let action: HMActionSet
    }

    private var manager: HMHomeManager?
    private var loaded = false

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { loaded = true }

    /// The scenes that do something, once Home has told this iPhone what homes there are.
    func scenes() async throws -> [Scene] {
        let manager = manager ?? HMHomeManager()
        if self.manager == nil {
            manager.delegate = self
            self.manager = manager
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let access = manager.authorizationStatus
        if access.contains(.restricted) || (access.contains(.determined) && !access.contains(.authorized)) {
            throw DeviceContextError("Allow Iterate access to Home in Settings.")
        }
        guard loaded else { throw DeviceContextError("Home did not answer on this iPhone. Try again.") }
        return manager.homes.flatMap { home in home.actionSets.filter { !$0.actions.isEmpty }.map { Scene(home: home, action: $0) } }
    }

    /// Runs the one scene with this name, in the named home when several homes have it.
    func run(scene name: String, home: String?) async throws -> Scene {
        let same = { (a: String, b: String) in a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let found = try await scenes().filter { same($0.action.name, name) && (home == nil || same($0.home.name, home!)) }
        guard let scene = found.first else { throw DeviceContextError("No Home scene has that name.") }
        guard found.count == 1 else { throw DeviceContextError("Several homes have a scene with that name. Name the home too.") }
        try await scene.home.executeActionSet(scene.action)
        return scene
    }
}

@MainActor
enum DeviceMusic {
    enum Source: String, CaseIterable { case library = "Library", catalog = "Apple Music" }

    static func songs(term: String, source: Source) async throws -> [Song] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == .library || !term.isEmpty else {
            throw DeviceContextError("Enter a title or artist to search Apple Music.")
        }
        guard await MusicAuthorization.request() == .authorized else {
            throw DeviceContextError("Allow Music access for Iterate in Settings.")
        }
        switch source {
        case .library:
            var request = MusicLibraryRequest<Song>()
            if !term.isEmpty { request.filter(matching: \.title, contains: term) }
            request.limit = 30
            return Array(try await request.response().items)
        case .catalog:
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 25
            return Array(try await request.response().songs)
        }
    }

    static func play(_ song: Song, source: Source) async throws {
        if source == .catalog, !(try await MusicSubscription.current.canPlayCatalogContent) {
            throw DeviceContextError("Apple Music playback requires an active subscription for this account.")
        }
        let player = SystemMusicPlayer.shared
        player.queue = [song]
        try await player.play()
    }
}
