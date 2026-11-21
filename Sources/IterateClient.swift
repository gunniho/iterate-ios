import Foundation

struct Credentials: Codable, Equatable {
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

struct DeviceApproval {
    let userCode: String
    let verificationURL: URL
    fileprivate let deviceCode: String
    fileprivate let clientID: String
    fileprivate let interval: Int
    fileprivate let deadline: ContinuousClock.Instant
}

enum ConnectionIssue: LocalizedError, Equatable {
    case unconfigured, invalidResponse, wrongMind, expired, refused, lostConnection

    var errorDescription: String? {
        switch self {
        case .unconfigured: "Configure this build with your Iterate workspace and mind ID before pairing."
        case .invalidResponse: "Iterate returned an unexpected response. Try connecting again."
        case .wrongMind: "The server answered with a different mind identity."
        case .expired: "Your sign-in expired. Connect again to approve this device."
        case .refused: "Iterate declined this session. Connect again to sign in."
        case .lostConnection: "The connection to your mind was interrupted. Try again."
        }
    }
}

struct OAuthFailure: LocalizedError {
    let code: String?
    let status: Int

    var errorDescription: String? {
        switch code {
        case "access_denied": "Sign-in was declined."
        case "expired_token", "invalid_grant": "This sign-in expired. Connect again for a new code."
        default: status == 429
            ? "Iterate is receiving too many requests. Try again shortly."
            : "Iterate could not complete sign-in (HTTP \(status))."
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct IterateClient {
    private static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"
    let session: URLSession
    private let deployment: Deployment

    init(deployment: Deployment = .current, session: URLSession? = nil) {
        self.deployment = deployment
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    func beginApproval() async throws -> DeviceApproval {
        let registration = try JSONSerialization.data(withJSONObject: [
            "client_name": "Iterate for iOS",
            "token_endpoint_auth_method": "none",
            "grant_types": [Self.deviceGrant, "refresh_token"],
        ])
        struct Registration: Decodable { let clientId: String }
        let client: Registration = try decode(await post("register", body: registration, type: "application/json"))
        guard !client.clientId.isEmpty else { throw ConnectionIssue.invalidResponse }

        struct Device: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationUri: String
            let expiresIn: Int
            let interval: Int?
        }
        let clock = ContinuousClock()
        let started = clock.now
        let device: Device = try decode(await form("device_authorization", [
            "client_id": client.clientId, "scope": "iterate", "resource": deployment.resource.absoluteString,
        ]))
        let interval = device.interval ?? 5
        guard device.verificationUri == deployment.verificationPage.absoluteString,
              !device.deviceCode.isEmpty, !device.userCode.isEmpty, device.expiresIn > 0,
              (1...300).contains(interval) else { throw ConnectionIssue.invalidResponse }
        // Only the human-readable code belongs in the browser. The redemption code stays in memory.
        let verificationURL = deployment.verificationPage.appending(queryItems: [
            URLQueryItem(name: "user_code", value: device.userCode),
        ])
        return DeviceApproval(userCode: device.userCode, verificationURL: verificationURL,
                              deviceCode: device.deviceCode, clientID: client.clientId, interval: interval,
                              deadline: started.advanced(by: .seconds(min(device.expiresIn, 300))))
    }

    func awaitApproval(_ approval: DeviceApproval) async throws -> Credentials {
        let clock = ContinuousClock()
        var interval = approval.interval
        var delay = interval
        while clock.now < approval.deadline {
            try await clock.sleep(until: min(clock.now.advanced(by: .seconds(delay)), approval.deadline))
            guard clock.now < approval.deadline else { break }
            do {
                return try await tokens([
                    "grant_type": Self.deviceGrant, "device_code": approval.deviceCode,
                ], clientID: approval.clientID)
            } catch let error as OAuthFailure {
                switch error.code {
                case "authorization_pending": delay = interval
                case "slow_down":
                    interval += 5
                    delay = interval
                default:
                    guard error.status >= 500 || error.status == 429 else { throw error }
                    delay = max(interval, min(delay * 2, 30))
                }
            } catch let error as URLError where error.isTransient {
                delay = max(interval, min(delay * 2, 30))
            }
        }
        throw ConnectionIssue.expired
    }

    func refresh(_ current: Credentials) async throws -> Credentials {
        guard let refreshToken = current.refreshToken else { throw ConnectionIssue.expired }
        do {
            return try await tokens(["grant_type": "refresh_token", "refresh_token": refreshToken],
                                    clientID: current.clientID, previousRefresh: refreshToken)
        } catch let error as OAuthFailure where ["invalid_grant", "invalid_client"].contains(error.code) {
            throw ConnectionIssue.expired
        }
    }

    func revoke(_ current: Credentials) async throws {
        _ = try await form("token", [
            "client_id": current.clientID, "token": current.refreshToken ?? current.accessToken,
            "token_type_hint": current.refreshToken == nil ? "access_token" : "refresh_token",
        ])
    }

    func socket(for credentials: Credentials) throws -> URLSessionWebSocketTask {
        guard deployment.isConfigured else { throw ConnectionIssue.unconfigured }
        var request = URLRequest(url: deployment.socket)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1024 * 1024
        return socket
    }

    private func tokens(_ grant: [String: String], clientID: String,
                        previousRefresh: String? = nil) async throws -> Credentials {
        struct TokenResponse: Decodable {
            let tokenType: String
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int
            let scope: String?
        }
        var fields = grant
        fields["client_id"] = clientID
        fields["resource"] = deployment.resource.absoluteString
        let started = Date()
        let token: TokenResponse = try decode(await form("token", fields))
        guard token.tokenType.lowercased() == "bearer", !token.accessToken.isEmpty,
              token.scope == nil || token.scope == "iterate", token.expiresIn > 0 else {
            throw ConnectionIssue.invalidResponse
        }
        return Credentials(clientID: clientID, accessToken: token.accessToken,
                           refreshToken: token.refreshToken ?? previousRefresh,
                           expiresAt: started.addingTimeInterval(TimeInterval(token.expiresIn)))
    }

    private func form(_ path: String, _ fields: [String: String]) async throws -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return try await post(path, body: Data(encoded.utf8), type: "application/x-www-form-urlencoded")
    }

    private func post(_ path: String, body: Data, type: String) async throws -> Data {
        guard deployment.isConfigured else { throw ConnectionIssue.unconfigured }
        var request = URLRequest(url: deployment.issuer.appendingPathComponent("oauth2/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url else {
            throw ConnectionIssue.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Refusal: Decodable { let error: String }
            throw OAuthFailure(code: (try? JSONDecoder().decode(Refusal.self, from: data))?.error,
                               status: http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ConnectionIssue.invalidResponse }
    }
}

extension URLError {
    var isTransient: Bool {
        [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
         .cannotFindHost, .dnsLookupFailed].contains(code)
    }
}
