import CryptoKit
import Foundation

/// The app and its embedded targets load the same settings from their own Info.plist.
struct Deployment: Sendable {
    static let current = Deployment(info: Bundle.main.infoDictionary ?? [:])

    let apexHost: String
    let controlHost: String
    let dashHost: String
    let mindID: String
    let bundleID: String
    let isConfigured: Bool
    let website: URL
    let issuer: URL
    let resource: URL
    let socket: URL
    let verificationPage: URL
    let credentialAccount: String
    let workspaceKey: String

    var appGroup: String { "group." + bundleID }
    var urlScheme: String { "iterate-" + bundleID.lowercased() }

    init(info: [String: Any]) {
        let apex = Self.hostname(info["IterateApexHost"])
        let control = Self.hostname(info["IterateControlHost"])
        let dash = Self.hostname(info["IterateDashHost"])
        let bundle = info["IterateBundleID"] as? String ?? ""
        let pin = (info["IterateMindID"] as? String)?.lowercased() ?? ""
        let emptyPin = String(repeating: "0", count: 64)
        let validPin = pin.utf8.count == 64 && pin.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
        let validBundle = Self.hostname(bundle) != nil

        apexHost = apex ?? "example.org"
        controlHost = control ?? "iterate.example.org"
        dashHost = dash ?? "dash.example.org"
        mindID = validPin ? pin : emptyPin
        bundleID = validBundle ? bundle : "org.example.iterate"
        #if DEBUG
        // A Debug build launched with ITERATE_DEV_MIND=http://127.0.0.1:8787 talks to the local stand-in
        // in Server/tests/dev-mind.mjs. Its sign-in has its own Keychain entry, apart from the workspace's.
        let standIn = ProcessInfo.processInfo.environment["ITERATE_DEV_MIND"].flatMap(URL.init(string:)).flatMap {
            $0.scheme == "http" && $0.host == "127.0.0.1" && $0.path.isEmpty ? $0 : nil
        }
        #else
        let standIn: URL? = nil
        #endif
        isConfigured = standIn != nil || (apex != nil && control != nil && dash != nil && validBundle && mindID != emptyPin)
        website = URL(string: "https://" + apexHost)!
        issuer = standIn ?? URL(string: "https://" + controlHost)!
        resource = issuer.appendingPathComponent("api")
        socket = standIn.map { URL(string: "ws://127.0.0.1:\($0.port ?? 80)/api")! } ?? URL(string: "wss://" + controlHost + "/api")!
        verificationPage = issuer.appendingPathComponent("oauth2/device")
        credentialAccount = resource.absoluteString + "#" + mindID
        // The issuer is also part of the scope because OAuth tokens have a specific audience.
        workspaceKey = SHA256.hash(data: Data(credentialAccount.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    func runURL(_ id: UUID) -> URL {
        website.appendingPathComponent("runs").appendingPathComponent(id.uuidString.lowercased())
    }

    private static func hostname(_ value: Any?) -> String? {
        guard let name = (value as? String)?.lowercased(), name.utf8.count <= 253 else { return nil }
        let labels = name.components(separatedBy: ".")
        guard labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return name
    }
}
