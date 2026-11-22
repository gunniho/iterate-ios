import AVFAudio
import XCTest
@testable import Iterate

final class VoiceTests: XCTestCase {
    func testOnlyTheCurrentCallCanPlayAudioOrClearTheSpeaker() {
        let bytes = Data([1, 0, 254, 255])
        func frame(_ pcm: String, clear: Bool = false) -> [String: Any] {
            ["type": VoiceEvent.prefix + "speaker-frame",
             "payload": ["activation": "one", "pcm": pcm, "clearSpeakerBufferBeforeFrame": clear]]
        }
        XCTAssertEqual(VoiceEvent.decode(frame(bytes.base64EncodedString()), activation: "one"), .speaker(bytes, clear: false))
        XCTAssertEqual(VoiceEvent.decode(frame("", clear: true), activation: "one"), .speaker(Data(), clear: true))
        XCTAssertNil(VoiceEvent.decode(frame("", clear: true), activation: "another"))
        XCTAssertNil(VoiceEvent.decode(frame(Data([1]).base64EncodedString()), activation: "one"))
        XCTAssertNil(VoiceEvent.decode(frame("broken"), activation: "one"))
    }

    @MainActor
    func testNativeResamplerProducesFiftyMillisecondSpeechFrames() async throws {
        let frames = try await SpeechFixture.greeting()
        XCTAssertTrue((48...60).contains(frames.count), "Unexpected duration of converted greeting")
        XCTAssertTrue(frames.allSatisfy { $0.count == 1600 })
        XCTAssertTrue(frames.contains { $0.contains(where: { $0 != 0 }) })
    }

    @MainActor
    func testSpeakerPlaysSignedPCMAndDiscardsQueuedAudioWhenInterrupted() throws {
        let engine = AVAudioEngine()
        let audio = CallAudio(engine: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        audio.connectSpeaker()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        try engine.start()
        defer { audio.stop() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        let positive = [Int16](repeating: 8192, count: 1600).withUnsafeBytes { Data($0) }
        let negative = [Int16](repeating: -8192, count: 1600).withUnsafeBytes { Data($0) }
        audio.play(positive, clear: false)
        XCTAssertEqual(try engine.renderOffline(256, to: buffer), .success)
        XCTAssertEqual(try XCTUnwrap(buffer.floatChannelData?[0][200]), 0.25, accuracy: 0.02)
        audio.play(Data(), clear: true)
        audio.play(negative, clear: false)
        XCTAssertEqual(try engine.renderOffline(256, to: buffer), .success)
        XCTAssertEqual(try XCTUnwrap(buffer.floatChannelData?[0][200]), -0.25, accuracy: 0.02)
    }

    #if targetEnvironment(simulator)
    @MainActor
    func testVoiceProcessingRestartsAfterAnAudioRouteChange() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ITERATE_AUDIO_ENGINE_TEST"] == "1",
                          "This test needs a simulator with microphone permission.")
        let engine = AVAudioEngine()
        let audio = CallAudio(engine: engine, muteInput: true)
        var interruption: String?
        let stream = try await audio.start { interruption = $0 }
        defer { audio.stop() }
        var frameCount = 0
        let counter = Task {
            for try await frame in stream where frame.count == CallAudio.frameBytes { frameCount += 1 }
        }
        defer { counter.cancel() }
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(interruption)
        XCTAssertTrue(engine.isRunning)
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        let beforeRestart = frameCount
        let deadline = ContinuousClock.now + .seconds(4)
        while frameCount < beforeRestart + 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(interruption)
        XCTAssertTrue(engine.isRunning)
        XCTAssertGreaterThanOrEqual(frameCount, beforeRestart + 3)
    }
    #endif

    @MainActor
    func testACallOpensItsMicrophoneWhileItsRelayIsPreparedAndReleasesItWhenAbandoned() async throws {
        // A socket that never answers keeps the relay in preparation.
        let link = MindSocket(URLSession.shared.webSocketTask(with: Deployment.current.socket))
        defer { link.close() }
        let fixture = SpeechFixture(frames: [])
        fixture.permissionGranted = true
        let voice = LiveVoice(permission: { fixture.permissionGranted }, makeAudio: { fixture })
        voice.attach(to: link, prepareImmediately: false)
        voice.start(for: .agent(path: "/agents/example", draftID: nil))
        XCTAssertEqual(voice.phase, .preparing)
        XCTAssertTrue(voice.isBusy)
        let deadline = ContinuousClock.now + .seconds(2)
        while !fixture.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(fixture.started)
        XCTAssertEqual(voice.phase, .preparing)
        XCTAssertFalse(fixture.stopped)
        voice.hangUp()
        XCTAssertTrue(fixture.stopped)
        XCTAssertFalse(voice.isBusy)

        // Without permission nothing is opened ahead of the call.
        let silent = SpeechFixture(frames: [])
        let refused = LiveVoice(permission: { false }, makeAudio: { silent })
        refused.attach(to: link, prepareImmediately: false)
        refused.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(silent.started)
        refused.detach(from: link)
    }

    @MainActor
    func testSignedInDeviceCanTalkToGPTAndHangUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ITERATE_LIVE_VOICE_TEST"] == "1",
                          "This test opens a real call using the signed-in device.")
        let saved = try XCTUnwrap(CredentialStore().load(), "Sign the test device into Iterate first.")
        let link = MindSocket(try IterateClient().socket(for: saved))
        let fixture = SpeechFixture(frames: try await SpeechFixture.greeting())
        let voice = LiveVoice(permission: { fixture.permissionGranted }, makeAudio: { fixture })
        let connection = Task { try await link.run { _ in voice.attach(to: link) } }
        defer {
            voice.hangUp()
            voice.detach(from: link)
            connection.cancel()
            link.close()
        }
        try await wait(for: { voice.phase == .ready }, voice: voice, seconds: 40)
        voice.start()
        try await wait(for: { voice.phase == .microphoneDenied }, voice: voice, seconds: 2)
        XCTAssertFalse(fixture.started)
        fixture.permissionGranted = true
        voice.start()
        do {
            try await wait(for: { voice.phase == .live && fixture.receivedSpeech && voice.caption?.hasPrefix("GPT · ") == true },
                           voice: voice, seconds: 35)
        } catch {
            voice.hangUp()
            try? await wait(for: { voice.phase == .ready }, voice: voice, seconds: 5)
            throw error
        }
        XCTAssertTrue(fixture.receivedSpeech)
        voice.hangUp()
        XCTAssertTrue(fixture.stopped)
        XCTAssertNil(voice.caption)
        try await wait(for: { voice.phase == .ready }, voice: voice, seconds: 6)
    }

    @MainActor
    private func wait(for predicate: () -> Bool, voice: LiveVoice, seconds: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !predicate() {
            if case .failed(let message) = voice.phase { throw MindRPCError(message: message) }
            guard ContinuousClock.now < deadline else {
                throw MindRPCError(message: "No expected voice event before timeout. Last state: \(voice.phase).")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
private final class SpeechFixture: VoiceAudioIO {
    private let frames: [Data]
    private var source: Task<Void, Never>?
    var permissionGranted = false
    private(set) var receivedSpeech = false
    private(set) var started = false
    private(set) var stopped = false

    init(frames: [Data]) { self.frames = frames }

    func start(interrupted: @escaping @MainActor (String) -> Void) throws -> AsyncThrowingStream<Data, Error> {
        started = true
        let (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(40))
        source = Task {
            defer { sink.finish() }
            let silence = Data(count: CallAudio.frameBytes)
            var index = -20
            while !Task.isCancelled {
                sink.yield(frames.indices.contains(index) ? frames[index] : silence)
                index += 1
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        return stream
    }

    func play(_ pcm: Data, clear: Bool) {
        if pcm.contains(where: { $0 != 0 }) { receivedSpeech = true }
    }

    func stop() {
        stopped = true
        source?.cancel()
    }

    static func greeting() async throws -> [Data] {
        let url = try XCTUnwrap(Bundle(for: VoiceTests.self).url(forResource: "Greeting", withExtension: "m4a"))
        let file = try AVAudioFile(forReading: url)
        let (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream()
        let converter = try XCTUnwrap(MicConverter(input: file.processingFormat, output: sink))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            converter.process(buffer)
        }
        sink.finish()
        var frames: [Data] = []
        for try await frame in stream { frames.append(frame) }
        return frames
    }
}
