import AVFAudio
import Foundation

enum VoiceAudioIssue: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "The microphone or speaker is unavailable. Check your audio device and try again."
        }
    }
}

/// The input tap owns the converter. Its single audio thread emits 50 ms PCM frames into a bounded stream.
final class MicConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let output: AsyncThrowingStream<Data, Error>.Continuation
    private var remainder = Data()

    init?(input: AVAudioFormat, output: AsyncThrowingStream<Data, Error>.Continuation) {
        guard input.sampleRate > 0, input.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: format) else { return nil }
        self.format = format
        self.converter = converter
        self.output = output
    }

    func process(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        let source = SingleInput(input)
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, result in source.next(result) }
        if status == .error {
            output.finish(throwing: error ?? VoiceAudioIssue.unavailable as NSError)
            return
        }
        guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return }
        remainder.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
        while remainder.count >= CallAudio.frameBytes {
            output.yield(Data(remainder.prefix(CallAudio.frameBytes)))
            remainder.removeFirst(CallAudio.frameBytes)
        }
    }

    // AVAudioConverter pulls synchronously and can ask for the same tap's input more than once.
    private final class SingleInput: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else { status.pointee = .noDataNow; return nil }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    func install(on input: AVAudioInputNode, format: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, _ in process(buffer) }
    }
}

@MainActor
protocol VoiceAudioIO: AnyObject {
    func start(interrupted: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<Data, Error>
    func play(_ pcm: Data, clear: Bool)
    func stop()
}

@MainActor
final class CallAudio: VoiceAudioIO {
    nonisolated static let frameBytes = 1600
    private static let sessionChanges = DispatchQueue(label: Deployment.current.bundleID + ".audio-session")
    private let session = AVAudioSession.sharedInstance()
    private let engine: AVAudioEngine
    private let muteInput: Bool
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var capture: AsyncThrowingStream<Data, Error>.Continuation?
    private var hasTap = false
    private var sessionActive = false
    private var inputFormat: AVAudioFormat?
    private var routeRecovery: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var playbackGeneration = 0
    private var queuedSamples = 0

    init(engine: AVAudioEngine = AVAudioEngine(), muteInput: Bool = false) {
        self.engine = engine
        self.muteInput = muteInput
    }

    func connectSpeaker() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
    }

    func start(interrupted: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<Data, Error> {
        do {
            sessionActive = true
            let session = self.session
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                Self.sessionChanges.async {
                    do {
                        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                                options: [.defaultToSpeaker, .allowBluetoothHFP])
                        try session.setActive(true)
                        done.resume()
                    } catch { done.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            guard sessionActive else { throw CancellationError() }
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            if muteInput { input.isVoiceProcessingInputMuted = true }
            let (frames, sink) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(40))
            capture = sink
            connectSpeaker()
            // Voice processing and Bluetooth routes can briefly publish a zero-rate input.
            for delay in [0, 100, 250, 500] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                try Task.checkCancellation()
                guard sessionActive else { throw CancellationError() }
                do {
                    try startInput(sink)
                    break
                } catch {
                    engine.stop()
                    removeInputTap()
                    if delay == 500 { throw error }
                }
            }
            observeInterruptions(interrupted)
            return frames
        } catch {
            stop()
            throw error
        }
    }

    private func startInput(_ sink: AsyncThrowingStream<Data, Error>.Continuation) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let mic = MicConverter(input: format, output: sink) else { throw VoiceAudioIssue.unavailable }
        mic.install(on: input, format: format)
        hasTap = true
        inputFormat = format
        engine.prepare()
        try engine.start()
    }

    func play(_ pcm: Data, clear: Bool) {
        guard engine.isRunning else { return }
        if clear { flushPlayback() }
        let count = pcm.count / 2
        guard count > 0, count <= 16_000 * 10, pcm.count.isMultiple(of: 2) else { return }
        if queuedSamples + count > 16_000 * 10 { flushPlayback() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(count)),
              let output = buffer.floatChannelData?[0] else { return }
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                output[i] = Float(Int16(littleEndian: sample)) / 32768
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        queuedSamples += count
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedSamples -= count
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func flushPlayback() {
        playbackGeneration += 1
        queuedSamples = 0
        player.stop()
    }

    private func observeInterruptions(_ interrupted: @escaping @MainActor (String) -> Void) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { note in
            guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in interrupted("The call ended because iOS interrupted the audio.") }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in self?.recoverRoute(interrupted) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: .main) { _ in
            Task { @MainActor in interrupted("iOS restarted the audio device. Tap to call again.") }
        })
    }

    private func recoverRoute(_ interrupted: @escaping @MainActor (String) -> Void) {
        guard capture != nil, routeRecovery == nil else { return }
        routeRecovery = Task {
            defer { routeRecovery = nil }
            for delay in [120, 300, 600] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let capture else { return }
                let current = engine.inputNode.outputFormat(forBus: 0)
                if engine.isRunning, current.sampleRate == inputFormat?.sampleRate,
                   current.channelCount == inputFormat?.channelCount,
                   current.commonFormat == inputFormat?.commonFormat,
                   current.isInterleaved == inputFormat?.isInterleaved { return }

                flushPlayback()
                engine.stop()
                removeInputTap()
                do {
                    try startInput(capture)
                    return
                } catch { continue }
            }
            interrupted("iOS could not reopen the audio device. Tap to call again.")
        }
    }

    private func removeInputTap() {
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
            inputFormat = nil
        }
    }

    func stop() {
        routeRecovery?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        removeInputTap()
        playbackGeneration += 1
        queuedSamples = 0
        if player.engine != nil { player.stop() }
        engine.stop()
        capture?.finish()
        capture = nil
        if sessionActive {
            sessionActive = false
            let session = self.session
            Self.sessionChanges.async { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }
}
