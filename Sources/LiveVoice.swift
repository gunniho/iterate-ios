import AVFAudio
import Foundation
import Observation

enum VoicePhase: Equatable {
    case preparing, ready, permission, microphoneDenied, dialing, live, ending
    case failed(String)

    var canHangUp: Bool { self == .permission || self == .dialing || self == .live }
}

@MainActor
@Observable
final class LiveVoice {
    private(set) var phase: VoicePhase = .preparing
    private(set) var caption: String?
    private(set) var destination: VoiceDestination = .device
    private var activation: String?
    private var started = false
    var activeScreenCallID: String? { phase == .live ? activation : nil }
    func isLive(on link: MindSocket) -> Bool { phase == .live && socket === link }
    @ObservationIgnored var screenDidHearUser: ((String, String) -> Void)?
    @ObservationIgnored var screenCallEnded: ((String) -> Void)?
    @ObservationIgnored private var socket: MindSocket?
    @ObservationIgnored private var relay: VoiceRelay?
    @ObservationIgnored private var audio: (any VoiceAudioIO)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    private var startWhenReady = false
    var isBusy: Bool { startWhenReady || phase.canHangUp || phase == .ending }
    @ObservationIgnored private var dialing: Task<Void, Never>?
    @ObservationIgnored private var microphone: Task<Void, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var openingDeadline: Task<Void, Never>?
    @ObservationIgnored private var keepalive: Task<Void, Never>?
    @ObservationIgnored private var ending: Task<Void, Never>?
    @ObservationIgnored private var frames: [Data] = []
    @ObservationIgnored private var inFlightFrames = 0
    @ObservationIgnored private var pendingEnds: [String: (path: String, reason: String)] = [:]

    private let permission: @MainActor () async -> Bool
    private let makeAudio: @MainActor () -> any VoiceAudioIO

    init(permission: @escaping @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         makeAudio: @escaping @MainActor () -> any VoiceAudioIO = { CallAudio() }) {
        self.permission = permission
        self.makeAudio = makeAudio
    }

    func attach(to link: MindSocket, prepareImmediately: Bool = true) {
        guard socket !== link else { return }
        socket = link
        if prepareImmediately || !pendingEnds.isEmpty { prepare(on: link) }
        else { phase = .ready }
    }

    private func prepare(on link: MindSocket) {
        guard preparation == nil else { return }
        let target = destination
        phase = .preparing
        preparation = Task { [self] in
            defer { if !Task.isCancelled, socket === link { preparation = nil } }
            do {
                for (id, end) in pendingEnds {
                    let context = try link.reference(target: MindSocket.root, path: ["mind", "cd"], arguments: [end.path])
                    defer { link.release(context) }
                    try await VoiceRelay.end(id, reason: end.reason, context: context, on: link)
                    pendingEnds.removeValue(forKey: id)
                }
                try Task.checkCancellation()
                let device = try await VoiceRelay.open(on: link, destination: target) { [weak self] events in self?.receive(events) }
                guard !Task.isCancelled, socket === link else { device.close(); return }
                relay = device
                guard !Task.isCancelled, socket === link else { return }
                phase = .ready
                if startWhenReady {
                    startWhenReady = false
                    start(for: target)
                }
            } catch {
                guard !Task.isCancelled, socket === link else { return }
                relay?.close()
                relay = nil
                startWhenReady = false
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func start() { start(for: .device) }

    func start(for target: VoiceDestination) {
        guard activation == nil, ending == nil, let socket else { return }
        if destination != target {
            preparation?.cancel()
            preparation = nil
            relay?.close()
            relay = nil
            destination = target
            phase = .ready
        }
        guard let relay, phase != .preparing else {
            startWhenReady = true
            prepare(on: socket)
            return
        }
        let id = VoiceRelay.randomID()
        activation = id
        caption = nil
        phase = .permission
        dialing = Task { [self] in
            do {
                let allowed = await permission()
                try Task.checkCancellation()
                guard activation == id else { return }
                guard allowed else {
                    activation = nil
                    phase = .microphoneDenied
                    return
                }
                let sound = makeAudio()
                audio = sound
                let stream = try await sound.start { [weak self] message in
                    guard self?.activation == id else { return }
                    self?.finish(reason: message, message: message)
                }
                try Task.checkCancellation()
                guard activation == id else { return }
                phase = .dialing
                started = true
                openingDeadline = Task {
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard activation == id, phase == .dialing else { return }
                    finish(reason: "Opening timed out", message: "GPT did not answer in time. Tap to call again.")
                }
                microphone = Task {
                    do {
                        for try await frame in stream {
                            guard activation == id, !Task.isCancelled else { return }
                            if frames.count + inFlightFrames < 40 { frames.append(frame) }
                            sendWaiting(to: relay, activation: id)
                        }
                    } catch {
                        guard activation == id, !Task.isCancelled else { return }
                        finish(reason: "Microphone interrupted", message: error.localizedDescription)
                    }
                }
                try await relay.start(id)
                guard activation == id, !Task.isCancelled else { return }
                keepalive = Task {
                    do {
                        while true {
                            try await Task.sleep(for: .seconds(20))
                            try await relay.keepAlive(id)
                        }
                    } catch {
                        guard activation == id, !Task.isCancelled else { return }
                        finish(reason: "Connection interrupted", message: "The voice connection was interrupted.")
                    }
                }
            } catch {
                guard activation == id, !Task.isCancelled else { return }
                finish(reason: "Could not start the call", message: error.localizedDescription)
            }
        }
    }

    func hangUp() {
        if startWhenReady {
            preparation?.cancel()
            preparation = nil
            phase = socket == nil ? .preparing : .ready
        }
        startWhenReady = false
        finish(reason: "Hung up on this device")
    }

    func speakScreenAnswer(_ text: String, for callID: String, runID: UUID) async throws {
        guard activeScreenCallID == callID, let relay else { throw ConnectionIssue.lostConnection }
        try await relay.speakScreenAnswer(text, activation: callID, runID: runID)
    }

    private func sendWaiting(to relay: VoiceRelay, activation id: String) {
        guard sending == nil, !frames.isEmpty else { return }
        sending = Task {
            do {
                while activation == id, !frames.isEmpty {
                    let count = min(20, frames.count)
                    let batch = Array(frames.prefix(count))
                    frames.removeFirst(count)
                    inFlightFrames = count
                    try await relay.sendMic(batch, activation: id)
                    guard activation == id else { return }
                    inFlightFrames = 0
                }
                if activation == id { sending = nil }
            } catch {
                guard activation == id, !Task.isCancelled else { return }
                finish(reason: "Microphone link interrupted", message: "Iterate stopped receiving microphone audio. Tap to call again.")
            }
        }
    }

    private func receive(_ events: [[String: Any]]) {
        for raw in events {
            guard let activation, let event = VoiceEvent.decode(raw, activation: activation) else { continue }
            switch event {
            case .accepted:
                openingDeadline?.cancel()
                phase = .live
            case .speaker(let data, let clear): audio?.play(data, clear: clear)
            case .caption(let text, let fromGPT):
                caption = (fromGPT ? "GPT · " : "You · ") + text
                if !fromGPT { screenDidHearUser?(text, activation) }
            case .ended(let reason): finish(reason: reason, message: reason, remoteEnded: true)
            case .providerError(let message): finish(reason: "GPT reported an error", message: message)
            }
        }
    }

    private func finish(reason: String, message: String? = nil, remoteEnded: Bool = false) {
        guard let id = activation else { return }
        let needsHangUp = started && !remoteEnded
        activation = nil
        screenCallEnded?(id)
        started = false
        dialing?.cancel()
        microphone?.cancel()
        sending?.cancel()
        openingDeadline?.cancel()
        keepalive?.cancel()
        sending = nil
        frames.removeAll()
        inFlightFrames = 0
        audio?.stop()
        audio = nil
        caption = nil
        let result = message.map(VoicePhase.failed) ?? .ready
        guard needsHangUp, let relay else { phase = result; return }
        phase = .ending
        pendingEnds[id] = (relay.path, reason)
        ending = Task {
            do {
                try await relay.end(id, reason: reason)
                pendingEnds.removeValue(forKey: id)
            } catch {
                if self.relay === relay { self.relay = nil; relay.close() }
            }
            ending = nil
            if socket === relay.socket, phase == .ending { phase = result }
        }
    }

    /// Release the microphone immediately, and let an outgoing hang-up finish before the socket closes.
    @discardableResult
    func detach(from link: MindSocket) -> Task<Void, Never>? {
        guard socket === link else { return nil }
        preparation?.cancel()
        preparation = nil
        startWhenReady = false
        finish(reason: "Device left the call")
        socket = nil
        destination = .device
        let device = relay
        relay = nil
        let hangUp = ending
        phase = .preparing
        if let hangUp {
            return Task {
                await hangUp.value
                device?.close()
            }
        }
        device?.close()
        return nil
    }
}
