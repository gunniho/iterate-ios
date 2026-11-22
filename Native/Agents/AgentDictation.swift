import AVFAudio
import Observation
import Speech

@MainActor @Observable
final class AgentDictation {
    enum Phase { case idle, requesting, recording, finishing }
    enum Issue: Equatable {
        case permissions, unavailable(String)
        var message: String {
            switch self {
            case .permissions: "Allow Microphone and Speech Recognition in Settings to dictate."
            case .unavailable(let detail): detail
            }
        }
    }

    private(set) var phase = Phase.idle
    var issue: Issue?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var interruptObserver: NSObjectProtocol?
    @ObservationIgnored private var finalDeadline: Task<Void, Never>?
    @ObservationIgnored private var audioActive = false

    static func inserting(_ words: String, after draft: String) -> String {
        guard !words.isEmpty else { return draft }
        let separator = draft.last.map { $0.isWhitespace ? "" : " " } ?? ""
        return draft + separator + words
    }

    func start(after draft: String, update: @escaping @MainActor (String) -> Void) {
        guard phase == .idle else { return }
        let id = UUID()
        sessionID = id
        phase = .requesting
        issue = nil
        Task { await record(id: id, after: draft, update: update) }
    }

    private func record(id: UUID, after draft: String, update: @escaping @MainActor (String) -> Void) async {
        guard sessionID == id else { return }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        guard sessionID == id else { return }
        guard speech == .authorized else { fail(.permissions); return }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard sessionID == id else { return }
        guard allowed else { fail(.permissions); return }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            fail(.unavailable("Dictation is unavailable for this language right now.")); return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            audioActive = true
            try await CallAudio.changeSession { session in
                try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                try session.setActive(true)
            }
            // Leaving while the microphone opened has already queued its release.
            guard sessionID == id else { return }
            let recorder = AVAudioEngine()
            let input = recorder.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceAudioIssue.unavailable }
            let buffer = SFSpeechAudioBufferRecognitionRequest()
            buffer.shouldReportPartialResults = true
            buffer.taskHint = .dictation
            buffer.addsPunctuation = true
            buffer.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.recognizer = recognizer
            self.request = buffer
            Self.installTap(input, format: format, request: buffer)
            engine = recorder
            recognition = Self.recognize(with: recognizer, request: buffer) { [weak self] words, final, error in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if let words, !words.isEmpty { update(Self.inserting(words, after: draft)) }
                    if let error, self.phase != .finishing { self.fail(.unavailable(error)) }
                    else if final || error != nil { self.cancel() }
                }
            }
            interruptObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: audio, queue: .main) { [weak self] notification in
                guard (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ==
                        AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated { if self?.sessionID == id { self?.stop() } }
            }
            recorder.prepare()
            try recorder.start()
            phase = .recording
        } catch {
            fail(.unavailable(error.localizedDescription))
        }
    }

    func stop() {
        guard phase == .recording else { if phase == .requesting { cancel() }; return }
        phase = .finishing
        releaseMicrophone()
        request?.endAudio()
        let id = sessionID
        finalDeadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if sessionID == id { cancel() }
        }
    }

    func cancel() {
        sessionID = nil
        finalDeadline?.cancel()
        finalDeadline = nil
        releaseMicrophone()
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        request = nil
        phase = .idle
    }

    private func fail(_ problem: Issue) {
        cancel()
        issue = problem
    }

    private func releaseMicrophone() {
        if let interruptObserver { NotificationCenter.default.removeObserver(interruptObserver) }
        interruptObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        if audioActive {
            CallAudio.releaseSession()
            audioActive = false
        }
    }

    // These framework callbacks run on audio/Speech queues, outside the UI actor.
    private nonisolated static func installTap(_ input: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                             receive: @escaping @Sendable (String?, Bool, String?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            receive(result?.bestTranscription.formattedString, result?.isFinal == true, error?.localizedDescription)
        }
    }
}
