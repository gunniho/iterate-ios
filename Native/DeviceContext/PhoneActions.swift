import Foundation
import MusicKit

/// What an agent of the mind can do on this iPhone. The mind calls an action by its name with one
/// object, and reads one object back.
@MainActor
enum PhoneActions {
    static let catalog: [(call: String, input: String, does: String)] = [
        ("contacts.find", "{ name }", "Up to 20 contacts with that name, their phone numbers and their addresses."),
        ("home.scenes", "{}", "The Home scenes that can be run."),
        ("home.run", "{ scene, home? }", "Runs the Home scene with that name."),
        ("music.search", "{ term, in?: \"library\" | \"catalog\" }", "Songs in the person's library, or in Apple Music with \"catalog\"."),
        ("music.play", "{ term, in?, id? }", "Plays the first song that search finds, or the one with `id`."),
        ("music.pause", "{}", "Pauses what is playing."),
        ("health.steps", "{ day? }", "The steps counted on a day. Today when it is absent."),
    ]

    static func perform(_ path: [String], _ arguments: [Any]) async throws -> Any {
        let input: [String: Any]
        switch arguments.first {
        case nil, is NSNull: input = [:]
        case let fields as [String: Any] where arguments.count == 1: input = fields
        default: throw DeviceContextError("Call an action with one object, like { name: \"Ada\" }.")
        }
        switch path.joined(separator: ".") {
        case "describe":
            return ["timeZone": TimeZone.current.identifier, "now": stamp(.now),
                    "times": "A day is text like 2026-11-24, read in this iPhone's time zone.",
                    "actions": catalog.map { ["call": $0.call, "input": $0.input, "does": $0.does] }]
        case "contacts.find":
            return ["contacts": try await DeviceContacts.find(try text(input, "name")).map { contact in
                var fields: [String: Any] = ["name": contact.name, "phones": contact.phones, "emails": contact.emails]
                fields["organization"] = contact.organization
                return fields
            }]
        case "home.scenes":
            return ["scenes": try await DeviceHome.shared.scenes().map { ["home": $0.home.name, "scene": $0.action.name] }]
        case "home.run":
            let ran = try await DeviceHome.shared.run(scene: try text(input, "scene"), home: try text(input, "home", required: false))
            return ["ran": ["home": ran.home.name, "scene": ran.action.name]]
        case "music.search":
            return ["songs": try await DeviceMusic.songs(term: try text(input, "term"), source: try source(input)).map(fields)]
        case "music.play":
            let source = try source(input), wanted = try text(input, "id", required: false)
            let songs = try await DeviceMusic.songs(term: try text(input, "term"), source: source)
            guard let song = songs.first(where: { wanted == nil || $0.id.rawValue == wanted }) else {
                throw DeviceContextError("No song matched.")
            }
            try await DeviceMusic.play(song, source: source)
            return ["playing": fields(song)]
        case "music.pause":
            SystemMusicPlayer.shared.pause()
            return ["paused": true]
        case "health.steps":
            let on = try moment(input, "day") ?? .now
            return ["day": day(on), "steps": try await DeviceHealth.steps(on: on)]
        default:
            throw DeviceContextError("This iPhone has no action of that name. Call describe() for the ones it has.")
        }
    }

    private static func fields(_ song: Song) -> [String: Any] {
        var fields: [String: Any] = ["id": song.id.rawValue, "title": song.title, "artist": song.artistName]
        fields["album"] = song.albumTitle
        return fields
    }

    private static func source(_ input: [String: Any]) throws -> DeviceMusic.Source {
        switch try text(input, "in", required: false) {
        case nil, "library": return .library
        case "catalog": return .catalog
        default: throw DeviceContextError("Search \"library\" or \"catalog\".")
        }
    }

    private static func text(_ input: [String: Any], _ field: String) throws -> String {
        guard let value = try text(input, field, required: false) else { throw DeviceContextError("Give \(field) as text.") }
        return value
    }

    private static func text(_ input: [String: Any], _ field: String, required: Bool) throws -> String? {
        switch input[field] {
        case nil, is NSNull: return nil
        case let value as String where value.count <= 2000:
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        default: throw DeviceContextError("Give \(field) as text of at most 2,000 characters.")
        }
    }

    /// A time with an offset is that moment. One without is read on this iPhone's clock.
    static func moment(_ input: [String: Any], _ field: String) throws -> Date? {
        guard let value = try text(input, field, required: false) else { return nil }
        let exact = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            exact.formatOptions = options
            if let date = exact.date(from: value) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: value) { return date }
        }
        throw DeviceContextError("Give \(field) as a time like 2026-11-24T09:00, or a day like 2026-11-24.")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Lends those actions to the mind as `itx.<person>.iphone` for as long as a socket lives, the way
/// a member's Mac lends itself. The person is the start of the member's address.
@MainActor
final class PhoneLend {
    private weak var link: MindSocket?
    private var work: Task<Void, Never>?

    static func name(for email: String?) -> String? {
        guard let start = email?.split(separator: "@").first else { return nil }
        let person = start.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard let first = person.first else { return nil }
        // A lent name starts with a letter.
        return (first.isLetter ? person : "member" + person) + ".iphone"
    }

    func offer(on socket: MindSocket, email: String?) {
        guard link !== socket, let name = Self.name(for: email) else { return }
        link = socket
        work?.cancel()
        work = Task {
            let target = socket.exportTarget { path, arguments in try await PhoneActions.perform(path, arguments) }
            let about = "A member's iPhone as an endpoint device, lent by the Iterate app while it is open on the screen. "
                + "It finds contacts, runs Home scenes, plays Apple Music and reads steps. "
                + "`await itx.\(name).describe()` lists each action and its input (iphone.md)."
            do {
                // The mind's handle is kept: the lend lasts until this socket closes.
                _ = try await socket.call(path: ["mind", "provide"],
                                          arguments: ["itx." + name, ["export", target], ["description": about]], timeout: .seconds(30))
            } catch {
                // A mind that takes no lend leaves the rest of the app as it was.
                socket.removeTarget(target)
            }
        }
    }
}
