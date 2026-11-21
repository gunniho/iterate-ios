import XCTest
@testable import Iterate

private let testSettings: [String: String] = [
    "IterateApexHost": Deployment.current.apexHost,
    "IterateControlHost": Deployment.current.controlHost,
    "IterateDashHost": Deployment.current.dashHost,
    "IterateBundleID": Deployment.current.bundleID,
    "IterateMindID": String(repeating: "a", count: 64)
]
private let fixtureDeployment = Deployment(info: testSettings)

final class ConnectionTests: XCTestCase {
    func testDistinctWorkspacesKeepSeparateCredentialsEvenAtTheSameHost() {
        var settings = testSettings
        settings["IterateControlHost"] = "control.workspace.test"
        settings["IterateApexHost"] = "workspace.test"
        settings["IterateDashHost"] = "agents.workspace.test"
        settings["IterateBundleID"] = "test.workspace.mobile"
        let first = Deployment(info: settings)
        XCTAssertTrue(first.isConfigured)
        XCTAssertEqual(first.socket.absoluteString, "wss://control.workspace.test/api")
        XCTAssertEqual(first.resource.absoluteString, "https://control.workspace.test/api")
        XCTAssertEqual(first.verificationPage.absoluteString, "https://control.workspace.test/oauth2/device")
        XCTAssertEqual(first.appGroup, "group.test.workspace.mobile")
        XCTAssertEqual(first.urlScheme, "iterate-test.workspace.mobile")
        XCTAssertEqual(first.runURL(UUID()).host, "workspace.test")
        settings["IterateMindID"] = String(repeating: "b", count: 64)
        let changedIdentity = Deployment(info: settings)
        XCTAssertNotEqual(first.credentialAccount, changedIdentity.credentialAccount)
        XCTAssertNotEqual(first.workspaceKey, changedIdentity.workspaceKey)
        settings["IterateControlHost"] = "renamed.workspace.test"
        let changedIssuer = Deployment(info: settings)
        XCTAssertNotEqual(changedIssuer.workspaceKey, changedIdentity.workspaceKey)
    }

    func testAPlaceholderPinOrInvalidHostCannotStartPairing() async throws {
        var settings = testSettings
        settings["IterateMindID"] = String(repeating: "0", count: 64)
        let missingPin = Deployment(info: settings)
        XCTAssertFalse(missingPin.isConfigured)
        let client = IterateClient(deployment: missingPin)
        do {
            _ = try await client.beginApproval()
            XCTFail("Pairing started without a workspace identity.")
        } catch { XCTAssertEqual(error as? ConnectionIssue, .unconfigured) }

        settings["IterateMindID"] = fixtureDeployment.mindID
        for host in ["https://workspace.test", "member@workspace.test", "workspace.test:443", "workspace.test/oauth"] {
            settings["IterateControlHost"] = host
            XCTAssertFalse(Deployment(info: settings).isConfigured)
        }
    }

    @MainActor
    func testOnlyTheExpectedRootAndReplyCanConfirmAConnection() throws {
        var identity: [String: Any] = [
            "mindId": fixtureDeployment.mindID, "mindSlug": fixtureDeployment.controlHost, "path": "/",
            "principal": ["email": "member@example.test"],
        ]
        XCTAssertEqual(try MindSocket.identity(in: ["resolve", 2, identity], for: 2, deployment: fixtureDeployment), "member@example.test")
        XCTAssertThrowsError(try MindSocket.identity(in: ["resolve", 1, identity], for: 2, deployment: fixtureDeployment))
        for field in ["mindId", "mindSlug", "path"] {
            let original = identity[field]
            identity[field] = "different"
            XCTAssertThrowsError(try MindSocket.identity(in: ["resolve", 2, identity], for: 2, deployment: fixtureDeployment)) {
                XCTAssertEqual($0 as? ConnectionIssue, .wrongMind)
            }
            identity[field] = original
        }
        let refusal: [Any] = ["error", "Error", "Sign-in required", NSNull(), ["code": "UNAUTHENTICATED"]]
        XCTAssertThrowsError(try MindSocket.identity(in: ["reject", 2, refusal], for: 2, deployment: fixtureDeployment)) {
            XCTAssertEqual($0 as? ConnectionIssue, .refused)
        }
    }

    func testApprovalRefreshAndRevocationUseTheDeviceGrant() async throws {
        let client = fixtureClient()
        let approval = try await client.beginApproval()
        XCTAssertEqual(approval.userCode, "BCDF-GHJK")
        XCTAssertEqual(approval.verificationURL.absoluteString,
                       fixtureDeployment.verificationPage.absoluteString + "?user_code=BCDF-GHJK")
        let issued = try await client.awaitApproval(approval)
        XCTAssertEqual(issued.accessToken, "example-access")
        let renewed = try await client.refresh(issued)
        XCTAssertEqual(renewed.accessToken, "example-renewed")
        XCTAssertEqual(renewed.refreshToken, issued.refreshToken)
        try await client.revoke(renewed)
    }

    func testApprovalRejectsAnUnexpectedVerificationHost() async throws {
        let client = fixtureClient(wrongHost: true)
        do {
            _ = try await client.beginApproval()
            XCTFail("Unexpected verification origin was accepted")
        } catch { XCTAssertEqual(error as? ConnectionIssue, .invalidResponse) }
    }

    func testCancellingApprovalStopsPolling() async throws {
        let client = fixtureClient()
        let approval = try await client.beginApproval()
        let pending = Task { try await client.awaitApproval(approval) }
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("A cancelled approval returned a credential")
        } catch is CancellationError {}
    }

    func testKeychainReplacesAndRemovesTheWholeSession() throws {
        let keychain = CredentialStore(account: "fixture-\(UUID().uuidString)")
        defer { try? keychain.clear() }
        XCTAssertNil(try keychain.load())
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Credentials(clientID: "fixture", accessToken: "first", refreshToken: "old", expiresAt: expires)
        let next = Credentials(clientID: "fixture", accessToken: "next", refreshToken: "rotated", expiresAt: expires)
        try keychain.save(first)
        try keychain.save(next)
        XCTAssertEqual(try keychain.load(), next)
        try keychain.clear()
        XCTAssertNil(try keychain.load())
    }

    private func fixtureClient(wrongHost: Bool = false) -> IterateClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthFixture.self]
        if wrongHost { config.httpAdditionalHeaders = ["X-Fixture": "wrong-host"] }
        return IterateClient(deployment: fixtureDeployment, session: URLSession(configuration: config))
    }
}

private final class OAuthFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, url.host == fixtureDeployment.controlHost, request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 512)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = request.httpBody ?? Data() }
        var encoded = URLComponents()
        if url.lastPathComponent != "register" {
            encoded.percentEncodedQuery = String(decoding: body, as: UTF8.self)
                .replacingOccurrences(of: "+", with: "%20")
        }
        let form = Dictionary((encoded.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                              uniquingKeysWith: { first, _ in first })
        var response: [String: Any] = ["error": "invalid_request"]
        var status = 400
        let audienceMatches = form["resource"] == fixtureDeployment.resource.absoluteString
        switch url.lastPathComponent {
        case "register":
            let metadata = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if metadata?["token_endpoint_auth_method"] as? String == "none",
               (metadata?["grant_types"] as? [String])?.contains("urn:ietf:params:oauth:grant-type:device_code") == true {
                response = ["client_id": "fixture"]
                status = 201
            }
        case "device_authorization" where audienceMatches && form["client_id"] == "fixture" && form["scope"] == "iterate":
            let page = request.value(forHTTPHeaderField: "X-Fixture") == "wrong-host"
                ? "https://wrong." + fixtureDeployment.controlHost + "/oauth2/device" : fixtureDeployment.verificationPage.absoluteString
            response = ["device_code": "private+&=code", "user_code": "BCDF-GHJK",
                        "verification_uri": page, "expires_in": 30, "interval": 1]
            status = 200
        case "token" where form["client_id"] == "fixture":
            if audienceMatches && form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
                && form["device_code"] == "private+&=code" {
                response = ["token_type": "bearer", "access_token": "example-access",
                            "refresh_token": "example+refresh", "expires_in": 3600, "scope": "iterate"]
                status = 200
            } else if audienceMatches && form["grant_type"] == "refresh_token" && form["refresh_token"] == "example+refresh" {
                response = ["token_type": "Bearer", "access_token": "example-renewed", "expires_in": 3600]
                status = 200
            } else if form["token"] == "example+refresh" && form["token_type_hint"] == "refresh_token" {
                response = [:]
                status = 200
            }
        default: break
        }
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocolDidFinishLoading(self)
    }
}
