import AuthenticationServices
import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import UIKit

/// An act that waits, read from the exact text the vault keeps. It exists only when this iPhone's
/// own hash of that text is the digest a decision will name, so whatever relayed the text could
/// not change what is shown here.
struct HeldAct: Equatable {
    struct Field: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let digest: String
    let text: String
    let isMail: Bool
    let fields: [Field]
    let body: String?

    init?(text: String, reviewURL: String) {
        guard let page = ApprovalReviewLink.item(reviewURL),
              let digest = URLComponents(url: page, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "digest" })?.value,
              ApprovalStatement.hex(SHA256.hash(data: Data(text.utf8))) == digest,
              let act = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let name = act["act"] as? String else { return nil }
        self.digest = digest
        self.text = text
        isMail = name == "email.send"
        var fields: [Field] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { fields.append(Field(label: label, value: value)) }
        }
        if isMail {
            let sender = [act["fromName"] as? String, (act["from"] as? String).map { "<\($0)>" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            add("From", sender)
            add("To", (act["to"] as? [String])?.joined(separator: ", "))
            add("Cc", (act["cc"] as? [String])?.joined(separator: ", "))
            add("Reply to", act["replyTo"] as? String)
            add("Subject", act["subject"] as? String)
            add("Attachments", (act["attachments"] as? [[String: Any]])?
                .compactMap { $0["filename"] as? String }.joined(separator: ", "))
            // A mail with markup alone is read in the exact text below.
            body = act["text"] as? String
        } else if name == "itx.config.confirm",
                  let asked = ((act["args"] as? [Any])?.first as? [String: Any])?["request"] as? String, !asked.isEmpty {
            // A member's yes to one line: the line is what is read, not the call that carries it.
            add("Request", asked)
            add("Asked in", act["at"] as? String)
            body = nil
        } else {
            add("Call", name)
            add("In", act["at"] as? String)
            let arguments = act["args"].flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            }
            body = arguments.map { String(decoding: $0, as: UTF8.self) }
        }
        self.fields = fields
    }
}

/// A member's decision as the platform reads it: a statement, and the envelope that carries its
/// signature. `signedBytes` must match iterate/signed's: DSSE's pre-authentication encoding.
enum ApprovalStatement {
    enum Decision: Equatable {
        case approved
        case rejected(reason: String)

        var type: String {
            switch self {
            case .approved: "events.iterate.com/approval/act-approved"
            case .rejected: "events.iterate.com/approval/act-rejected"
            }
        }
    }

    static let payloadType = "application/vnd.iterate.statement+json"
    static let endpoint = ApprovalReviewLink.inbox.appendingPathComponent("statements")

    static func text(_ decision: Decision, digest: String, at now: Date = .now,
                     nonce: Data = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })) throws -> String {
        let at = Int64((now.timeIntervalSince1970 * 1000).rounded())
        var statement: [String: Any] = [
            "mind": Deployment.current.controlHost, "path": "/approvals", "type": decision.type, "about": [digest],
            "at": at, "expires": at + 5 * 60_000, "nonce": base64url(nonce),
        ]
        if case .rejected(let reason) = decision { statement["payload"] = ["reason": reason] }
        let data = try JSONSerialization.data(withJSONObject: statement, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func signedBytes(_ statement: String) -> Data {
        let body = Data(statement.utf8)
        return Data("DSSEv1 \(payloadType.utf8.count) \(payloadType) \(body.count) ".utf8) + body
    }

    /// The id the platform knows a key by: the SHA-256 of its public key, as SubjectPublicKeyInfo.
    static func keyID(_ publicKey: P256.Signing.PublicKey) -> String {
        base64url(Data(SHA256.hash(data: publicKey.derRepresentation)))
    }

    static func envelope(statement: String, key: String, signature: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "statement": statement,
            "signature": ["format": "p256", "key": key, "sig": base64url(signature)],
        ])
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum ApprovalSigningIssue: LocalizedError {
    case unknownKey
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .unknownKey: "This iPhone’s key is not set up for approvals yet."
        case .refused(let reason): "Not recorded: \(reason)."
        }
    }
}

/// This iPhone's key for approvals: made and kept in the Secure Enclave, and usable only after
/// Face ID or Touch ID. The Keychain holds the Enclave's handle to it, which is no key itself.
struct DeviceApprovalKey: Sendable {
    let session: String

    static var isAvailable: Bool { SecureEnclave.isAvailable }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Deployment.current.bundleID + ".approval-key",
         kSecAttrAccount as String: session]
    }

    private func handle() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }

    /// The public half. The first call makes the key, which asks the member for nothing.
    func publicKey() throws -> P256.Signing.PublicKey {
        if let handle = try handle() {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle).publicKey
        }
        var failure: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &failure
        ) else { throw failure!.takeRetainedValue() as Error }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        var item = query
        item[kSecValueData as String] = key.dataRepresentation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key.publicKey
    }

    /// r‖s over `bytes`. The Enclave asks for Face ID with `reason` before it signs.
    func signature(for bytes: Data, reason: String) async throws -> Data {
        guard let handle = try handle() else { throw ApprovalSigningIssue.unknownKey }
        return try await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle, authenticationContext: context)
            return try key.signature(for: bytes).rawRepresentation
        }.value
    }

    /// Where a member adds this key, confirmed by a passkey they already hold.
    func enrolmentPage() throws -> URL {
        let der = try publicKey().derRepresentation
        return Deployment.current.issuer.appendingPathComponent("keys/device").appending(queryItems: [
            URLQueryItem(name: "publicKey", value: ApprovalStatement.base64url(der)),
            URLQueryItem(name: "label", value: "Iterate on iPhone"),
        ])
    }

    /// Signs the decision here and hands it to the platform, which needs no session for it.
    func decide(_ decision: ApprovalStatement.Decision, on act: HeldAct, reason: String,
                send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async throws {
        let key = ApprovalStatement.keyID(try publicKey())
        let statement = try ApprovalStatement.text(decision, digest: act.digest)
        let signature = try await signature(for: ApprovalStatement.signedBytes(statement), reason: reason)
        var request = URLRequest(url: ApprovalStatement.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try ApprovalStatement.envelope(statement: statement, key: key, signature: signature)
        let (data, response) = try await send(request)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let reason = answer?["error"] as? String {
            throw reason.contains("not one this mind knows") ? ApprovalSigningIssue.unknownKey : .refused(reason)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, answer?["ok"] as? Bool == true else {
            throw ConnectionIssue.invalidResponse
        }
    }
}

/// The native review: the act as this iPhone checked it, and a decision signed with Face ID.
struct ApprovalDecisionSheet: View {
    let act: HeldAct
    let title: String
    let kind: PendingApproval.Kind
    let approvalID: Int
    let reviewPage: URL
    let sessionID: String
    let finished: (ApprovalResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working: ApprovalStatement.Decision?
    @State private var issue: String?
    @State private var setupCode: String?
    @State private var askReason = false
    @State private var reason = ""
    @State private var page: ApprovalReview?

    private var unlock: (name: String, symbol: String) { ApprovalReviewLink.deviceUnlock }
    private var key: DeviceApprovalKey { DeviceApprovalKey(session: sessionID) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(act.fields) { field in
                        LabeledContent(field.label) {
                            Text(verbatim: field.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                }
                if let body = act.body, !body.isEmpty {
                    Section(act.isMail ? "Message" : "With") {
                        Text(verbatim: body)
                            .font(act.isMail ? .body : .callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Section {
                    DisclosureGroup("The exact text you sign for") {
                        Text(verbatim: act.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Label("Checked on this iPhone: this is exactly what waits. Request \(String(act.digest.prefix(12))).",
                          systemImage: "checkmark.shield")
                }
                if let setupCode {
                    Section {
                        LabeledContent("This iPhone’s code") { Text(verbatim: setupCode).monospaced().textSelection(.enabled) }
                        Button("Set up \(unlock.name) approvals") { openSetup() }
                    } header: {
                        Text("One-time setup")
                    } footer: {
                        Text("The next page adds this iPhone’s key to your account. Check that it shows the same code, then confirm with a passkey you already have. After that, approve here.")
                    }
                }
                if let issue {
                    Section { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
            }
            .privacySensitive()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { page = ApprovalReview(url: reviewPage, approval: approvalID, kind: kind) } label: {
                        Label("Open review page", systemImage: "safari")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { decisions }
        }
        .interactiveDismissDisabled(working != nil)
        .alert("Reject this request?", isPresented: $askReason) {
            TextField("Reason", text: $reason)
            Button("Reject", role: .destructive) { decide(.rejected(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))) }
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Whoever asked is told your reason.")
        }
        .approvalReview($page, sessionID: sessionID) { result in
            if let result {
                // Decided on the review page after all.
                finished(result)
                dismiss()
            } else if setupCode != nil {
                // Back from setup: the key may be known now.
                setupCode = nil
                issue = nil
            }
        }
    }

    private var decisions: some View {
        VStack(spacing: 10) {
            Button { decide(.approved) } label: {
                Group {
                    if working == .approved { ProgressView().tint(.white) }
                    else { Label("Approve with \(unlock.name)", systemImage: unlock.symbol) }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            Button(role: .destructive) { askReason = true } label: {
                Group {
                    if case .rejected = working { ProgressView() } else { Text("Reject") }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(working != nil)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .background(.bar)
    }

    private func decide(_ decision: ApprovalStatement.Decision) {
        guard working == nil else { return }
        working = decision
        issue = nil
        Task {
            defer { working = nil }
            do {
                guard try CredentialStore().load()?.clientID == sessionID else { throw AssistantIssue.changedSession }
                try await key.decide(decision, on: act,
                                     reason: decision == .approved ? "Approve “\(title)”" : "Reject “\(title)”")
                finished(ApprovalResolution(kind: kind, outcome: decision == .approved ? .approved : .rejected))
                dismiss()
            } catch ApprovalSigningIssue.unknownKey {
                setupCode = (try? key.publicKey()).map { String(ApprovalStatement.keyID($0).prefix(8)) }
                if setupCode == nil { issue = "This iPhone could not make a key for approvals. Use the review page." }
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                // The member closed the Face ID prompt: nothing was signed.
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func openSetup() {
        do { page = ApprovalReview(url: try key.enrolmentPage()) }
        catch { issue = error.localizedDescription }
    }
}

// MARK: - A statement, signed with a passkey this iPhone asks for itself

/// A statement that waits for one person's passkey, as the platform's sign page holds it. The
/// platform answers it as JSON to an app that the mind's deploy names; a platform that answers a
/// page instead has no such app, and the page signs.
struct StatementDraft: Equatable, Identifiable {
    let id: String
    let path: String
    let type: String
    /// The payload's own JSON text, as the platform keeps it and compares a press with.
    let payload: String
    let signerEmail: String?
    let askedBy: String
    let fields: [HeldAct.Field]

    init?(json: Data) {
        guard let draft = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = draft["id"] as? String, !id.isEmpty,
              // a statement for another mind is not one this iPhone signs
              draft["mind"] as? String == Deployment.current.controlHost,
              let path = draft["path"] as? String, path.hasPrefix("/"),
              let type = draft["type"] as? String, !type.isEmpty,
              let payload = draft["payload"] as? String,
              let values = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        self.id = id
        self.path = path
        self.type = type
        self.payload = payload
        signerEmail = draft["signerEmail"] as? String
        let by = draft["askedBy"] as? [String: Any]
        let from = (draft["askedFrom"] as? String).map { "code running in \($0)" }
        askedBy = switch by?["kind"] as? String {
        case "member": (by?["email"] as? String).map { "\($0), a member" } ?? "A member"
        case "person": "\(by?["email"] as? String ?? "Someone"), who is not a member"
        case "guest": "A guest who gave the name “\(by?["name"] as? String ?? "")”"
        case "mind": "The mind \(by?["hostname"] as? String ?? "")"
        default: from.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Code running in this mind"
        }
        fields = values.keys.sorted().compactMap { key in
            let shown: String? = switch values[key] {
            case let text as String: text
            case let other?: (try? JSONSerialization.data(withJSONObject: other, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) }
            case nil: nil
            }
            return shown.map { HeldAct.Field(label: key.prefix(1).uppercased() + key.dropFirst(), value: $0) }
        }
    }

    /// What the statement asks, in the asker's one line, when its payload has one.
    var request: String? { fields.first { $0.label == "Request" }?.value }
    /// The payload's other fields.
    var details: [HeldAct.Field] { fields.filter { $0.label != "Request" } }

    /// The draft behind a sign page's link, or nil when the platform answers a page alone.
    static func load(page: URL, send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async throws -> StatementDraft? {
        var request = URLRequest(url: page)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true else { return nil }
        return StatementDraft(json: data)
    }

    /// The statement as the sign page writes it. The payload goes in as its own text, so its
    /// keys and numbers stay as the platform compares them.
    func statement(at now: Date = .now, nonce: Data = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })) throws -> String {
        func quoted(_ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        let at = Int64((now.timeIntervalSince1970 * 1000).rounded())
        return "{\"mind\":\(try quoted(Deployment.current.controlHost)),\"path\":\(try quoted(path)),\"type\":\(try quoted(type)),\"payload\":\(payload)," +
            "\"at\":\(at),\"expires\":\(at + 5 * 60_000),\"nonce\":\(try quoted(ApprovalStatement.base64url(nonce)))}"
    }

    /// What the passkey signs: the hash of the statement's signed bytes, as on the sign page.
    static func challenge(_ statement: String) -> Data {
        Data(SHA256.hash(data: ApprovalStatement.signedBytes(statement)))
    }

    /// The press, as the sign page sends it.
    func press(statement: String, credentialID: Data, signature: Data, authenticatorData: Data, clientDataJSON: Data) throws -> URLRequest {
        var request = URLRequest(url: ApprovalReviewLink.statement)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "draft": id, "statement": statement,
            "credentialId": ApprovalStatement.base64url(credentialID),
            "sig": ApprovalStatement.base64url(signature),
            "authenticatorData": ApprovalStatement.base64url(authenticatorData),
            "clientDataJSON": ApprovalStatement.base64url(clientDataJSON),
        ])
        return request
    }
}

/// One passkey prompt for the mind, shown by iOS itself. iOS shows it only for an app that the
/// mind's association file names; for any other it fails, and the sign page is the way.
@MainActor
final class PasskeyPrompt: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var waiting: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>?
    /// iOS keeps neither the controller nor its delegate: a prompt that nothing holds is dropped
    /// before it shows, and answers nobody. Each stays here until it has answered.
    private var controller: ASAuthorizationController?
    private static var open: Set<PasskeyPrompt> = []

    static func assertion(challenge: Data) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        let prompt = PasskeyPrompt()
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Deployment.current.controlHost)
            .createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = prompt
        controller.presentationContextProvider = prompt
        prompt.controller = controller
        open.insert(prompt)
        defer { open.remove(prompt) }
        return try await withCheckedThrowingContinuation { continuation in
            prompt.waiting = continuation
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            waiting?.resume(returning: assertion)
        } else {
            waiting?.resume(throwing: ASAuthorizationError(.failed))
        }
        waiting = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        waiting?.resume(throwing: error)
        waiting = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// The native signing of a statement: what it says, as the platform holds it, and one passkey
/// prompt. The sign page stays one tap away, and takes over when iOS shows no prompt here.
struct StatementSignSheet: View {
    let draft: StatementDraft
    let title: String
    let approvalID: Int
    let signPage: URL
    let sessionID: String
    let finished: (ApprovalResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var issue: String?
    @State private var page: ApprovalReview?
    @State private var showsDetails = false

    private var unlock: (name: String, symbol: String) { ApprovalReviewLink.deviceUnlock }

    var body: some View {
        NavigationStack {
            List {
                // What is asked, and nothing else: the rest is one tap down.
                Section {
                    Text(verbatim: draft.request ?? title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
                }
                Section {
                    DisclosureGroup("Details", isExpanded: $showsDetails) {
                        ForEach(draft.details) { field in
                            LabeledContent(field.label) {
                                Text(verbatim: field.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                        LabeledContent("Asked by") { Text(verbatim: draft.askedBy).multilineTextAlignment(.trailing) }
                        if let signer = draft.signerEmail {
                            LabeledContent("Signer") { Text(verbatim: signer).multilineTextAlignment(.trailing) }
                        }
                        LabeledContent("Context") { Text(verbatim: draft.path).font(.callout.monospaced()).multilineTextAlignment(.trailing) }
                        LabeledContent("Event type") { Text(verbatim: draft.type).font(.callout.monospaced()).multilineTextAlignment(.trailing) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("The exact text you sign").font(.subheadline).foregroundStyle(.secondary)
                            Text(verbatim: draft.payload).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("Signing adds this to the mind, with you as its signer.")
                }
                if let issue {
                    Section {
                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Button("Open the sign page") { openPage() }
                    }
                }
            }
            .privacySensitive()
            .navigationTitle("Signature request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { openPage() } label: { Label("Open sign page", systemImage: "safari") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { sign() } label: {
                    Group {
                        if working { ProgressView().tint(.white) }
                        else { Label("Sign with \(unlock.name)", systemImage: unlock.symbol) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled(working)
        .approvalReview($page, sessionID: sessionID) { result in
            if let result {
                finished(result)
                dismiss()
            }
        }
    }

    private func openPage() { page = ApprovalReview(url: signPage, approval: approvalID, kind: .signature) }

    private func sign() {
        guard !working else { return }
        working = true
        issue = nil
        Task {
            defer { working = false }
            do {
                guard try CredentialStore().load()?.clientID == sessionID else { throw AssistantIssue.changedSession }
                let statement = try draft.statement()
                let passkey = try await PasskeyPrompt.assertion(challenge: StatementDraft.challenge(statement))
                let (data, response) = try await URLSession.shared.data(for: draft.press(
                    statement: statement, credentialID: passkey.credentialID, signature: passkey.signature,
                    authenticatorData: passkey.rawAuthenticatorData, clientDataJSON: passkey.rawClientDataJSON))
                let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    if let say = answer?["say"] as? String { issue = say; return }
                    throw ApprovalSigningIssue.refused(answer?["refused"] as? String ?? "the mind did not take it")
                }
                finished(ApprovalResolution(kind: .signature, outcome: .approved))
                dismiss()
            } catch let error as ASAuthorizationError where error.code == .canceled {
                // The member closed the passkey prompt: nothing was signed.
            } catch let error as ASAuthorizationError {
                // The reason goes to the console: it names the app and the domain, not what to do.
                print("ITERATE-PASSKEY", (error as NSError).code, (error as NSError).userInfo)
                issue = "This iPhone could not ask for your passkey here yet. Try again in a moment, or use the sign page."
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}
