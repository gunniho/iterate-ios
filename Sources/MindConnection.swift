import Foundation
import Observation

enum ConnectionPhase: Equatable {
    case disconnected
    case preparing
    case approval(code: String, url: URL)
    case connecting
    case connected(email: String?)
    case disconnecting
    case failed(String)
}

enum DevicePairing: Equatable {
    case checking, unpaired, paired(String)
}

@MainActor
@Observable
final class MindConnection {
    static let shared = MindConnection()
    private(set) var phase = ConnectionPhase.disconnected
    private(set) var pairing = DevicePairing.checking
    var hasSavedSession: Bool {
        if case .paired = pairing { return true }
        return false
    }
    #if !ITERATE_VOICE_ONLY
    let directory = AgentDirectory()
    var agentLink: MindSocket? {
        if case .connected = phase { return socket }
        return nil
    }

    /// A first send can outlive its composer while the foreground socket finishes verification.
    func agentSession(for member: String) async throws -> (link: MindSocket, email: String?) {
        while true {
            try Task.checkCancellation()
            guard pairing == .paired(member) else { throw AssistantIssue.changedSession }
            if case .connected(let email) = phase, let agentLink { return (agentLink, email) }
            if case .failed(let reason) = phase { throw AssistantIssue.remote(reason) }
            guard foreground, phase != .disconnecting else { throw ConnectionIssue.lostConnection }
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = phase
                    _ = pairing
                } onChange: { continuation.resume() }
            }
        }
    }
    #endif
    let voice = LiveVoice()
    private let client = IterateClient()
    private let store = CredentialStore()
    @ObservationIgnored private var launchSession: Task<Credentials?, Error>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var socket: MindSocket?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var backgroundCall: Task<Void, Never>?

    func prepareForLaunch() {
        guard launchSession == nil, pairing == .checking else { return }
        let lookup = readSession()
        launchSession = lookup
        Task {
            if case .success(let saved) = await lookup.result, pairing == .checking, !lookup.isCancelled {
                useSession(saved)
            }
        }
    }

    private func readSession() -> Task<Credentials?, Error> {
        let credentials = store
        return Task.detached(priority: .userInitiated) { try credentials.load() }
    }

    func activate() {
        foreground = true
        backgroundCall?.cancel()
        backgroundCall = nil
        guard operation == nil, phase == .disconnected else { return }
        let lookup = launchSession
        launchSession = nil
        start {
            let saved: Credentials?
            if let lookup, case .success(let prepared) = await lookup.result { saved = prepared }
            else { saved = try await self.readSession().value }
            try Task.checkCancellation()
            self.useSession(saved)
            if let saved { try await self.maintain(saved) }
        }
    }

    private func useSession(_ credential: Credentials?) {
        let next = credential.map { DevicePairing.paired($0.clientID) } ?? .unpaired
        guard pairing != next else { return }
        pairing = next
        #if !ITERATE_VOICE_ONLY
        directory.selectSession(credential?.clientID)
        #endif
    }

    func background() {
        foreground = false
        #if !ITERATE_VOICE_ONLY
        if voice.phase == .live {
            backgroundCall?.cancel()
            backgroundCall = Task {
                while !foreground, voice.phase == .live, !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                }
                if !foreground, !Task.isCancelled { closeBackgroundConnection() }
            }
            return
        }
        #endif
        closeBackgroundConnection()
    }

    private func closeBackgroundConnection() {
        #if !ITERATE_VOICE_ONLY
        AssistantCenter.shared.foregroundSession = nil
        #endif
        if case .connected = phase { phase = .connecting }
        if let link = socket {
            if let hangUp = voice.detach(from: link) {
                Task { await hangUp.value; link.close() }
            } else { link.close() }
        }
    }

    func connect() {
        guard operation == nil else { return }
        phase = .preparing
        start {
            if let saved = try self.store.load() {
                self.useSession(saved)
                try await self.maintain(saved)
                return
            }
            let approval = try await self.client.beginApproval()
            try Task.checkCancellation()
            self.phase = .approval(code: approval.userCode, url: approval.verificationURL)
            let credentials = try await self.client.awaitApproval(approval)
            try Task.checkCancellation()
            try self.store.save(credentials)
            self.useSession(credentials)
            try await self.maintain(credentials)
        }
    }

    func cancelApproval() {
        operation?.cancel()
        operation = nil
        phase = .disconnected
    }

    func disconnect() {
        launchSession?.cancel()
        launchSession = nil
        backgroundCall?.cancel()
        #if !ITERATE_VOICE_ONLY
        AssistantCenter.shared.foregroundSession = nil
        #endif
        let link = socket
        let hangUp = link.flatMap { voice.detach(from: $0) }
        let previous = operation
        socket = nil
        phase = .disconnecting
        start {
            await hangUp?.value
            previous?.cancel()
            link?.close()
            let saved = try self.store.load()
            try self.store.clear()
            self.useSession(nil)
            if let saved {
                do { try await self.client.revoke(saved) }
                catch {
                    self.phase = .failed("Disconnected on this device. Iterate could not confirm revocation of the sign-in.")
                    return
                }
            }
            self.phase = .disconnected
        }
    }

    private func start(_ work: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        operationID = id
        operation = Task {
            defer { if operationID == id { operation = nil } }
            do {
                try await work()
            } catch {
                guard !Task.isCancelled, operationID == id else { return }
                if let issue = error as? ConnectionIssue, issue == .expired || issue == .refused {
                    do {
                        try store.clear()
                        useSession(nil)
                    } catch {
                        phase = .failed(error.localizedDescription)
                        return
                    }
                }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func maintain(_ initial: Credentials) async throws {
        var credentials = initial
        var failures = 0
        var refreshedAfterRefusal = false
        while foreground {
            try Task.checkCancellation()
            phase = .connecting
            if credentials.expiresAt.timeIntervalSinceNow <= 15 {
                credentials = try await renew(credentials)
            }
            guard foreground else { break }
            let transport = try client.socket(for: credentials)
            #if !ITERATE_VOICE_ONLY
            transport.maximumMessageSize = 8 * 1024 * 1024
            #endif
            let link = MindSocket(transport)
            socket = link
            do {
                try await link.run { email in
                    guard self.socket === link, self.foreground else { return }
                    failures = 0
                    refreshedAfterRefusal = false
                    self.phase = .connected(email: email)
                    #if !ITERATE_VOICE_ONLY
                    AssistantCenter.shared.foregroundSession = (credentials.clientID, link)
                    self.voice.attach(to: link, prepareImmediately: false)
                    #else
                    self.voice.attach(to: link)
                    #endif
                }
                throw ConnectionIssue.lostConnection
            } catch {
                #if !ITERATE_VOICE_ONLY
                if AssistantCenter.shared.foregroundSession?.link === link { AssistantCenter.shared.foregroundSession = nil }
                #endif
                voice.detach(from: link)
                try Task.checkCancellation()
                guard socket === link else { return }
                socket = nil
                guard foreground else { break }
                phase = .connecting
                if let issue = error as? ConnectionIssue {
                    if issue == .refused {
                        guard !refreshedAfterRefusal else { throw issue }
                        credentials = try await renew(credentials)
                        refreshedAfterRefusal = true
                        continue
                    }
                    if issue != .lostConnection { throw issue }
                } else if let failure = error as? URLError, !failure.isTransient && failure.code != .cancelled {
                    throw failure
                }
                failures += 1
                guard failures <= 2 else { throw ConnectionIssue.lostConnection }
                try await Task.sleep(for: .seconds(failures * 2))
            }
        }
        phase = .disconnected
    }

    private func renew(_ credentials: Credentials) async throws -> Credentials {
        #if ITERATE_VOICE_ONLY
        let fresh = try await client.refresh(credentials)
        try Task.checkCancellation()
        try store.save(fresh)
        return fresh
        #else
        return try await PairedSession.credentials(replacing: credentials.accessToken)
        #endif
    }
}
