import CoreLocation
import HealthKit
import HomeKit
import MapKit
import MusicKit
import Observation

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
    static func steps(on day: Date) async throws -> String {
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
        let count = Int(quantity.doubleValue(for: .count()).rounded())
        return "\(day.formatted(date: .abbreviated, time: .omitted)) — \(count.formatted()) steps"
    }
}

@MainActor @Observable
final class DeviceHome: NSObject, @preconcurrency HMHomeManagerDelegate {
    struct Scene: Identifiable {
        let home: HMHome
        let action: HMActionSet
        var id: UUID { action.uniqueIdentifier }
        var label: String { home.name + " · " + action.name }
    }

    private var manager: HMHomeManager?
    private(set) var scenes = [Scene]()
    private(set) var status = "Loading Home…"

    func load() {
        if let manager {
            refresh(manager)
            return
        }
        manager = HMHomeManager()
        manager?.delegate = self
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { refresh(manager) }
    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) { refresh(manager) }

    private func refresh(_ manager: HMHomeManager) {
        let auth = manager.authorizationStatus
        if auth.contains(.restricted) || (auth.contains(.determined) && !auth.contains(.authorized)) {
            scenes = []
            status = "Allow Iterate access to Home in Settings to choose a scene."
            return
        }
        scenes = manager.homes.flatMap { home in home.actionSets.filter { !$0.actions.isEmpty }.map { Scene(home: home, action: $0) } }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        status = scenes.isEmpty ? "No configured Home scenes are available." : ""
    }

    func run(_ scene: Scene) async throws {
        guard let manager, manager.authorizationStatus.contains(.authorized),
              let current = scenes.first(where: { $0.id == scene.id }) else {
            throw DeviceContextError("This Home scene is no longer available.")
        }
        try await current.home.executeActionSet(current.action)
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
