import AppIntents
import Observation
import SwiftUI

@MainActor
@Observable
final class IterateScreenShare {
    static let shared = IterateScreenShare()

    enum Phase: Equatable { case idle, choosing, sharing, failed(String) }
    private(set) var phase: Phase = .idle
    private(set) var hasFrame = false
    private(set) var asking = false
    private(set) var lastRun: IterateRun?
    private(set) var questionError: String?
    @ObservationIgnored private weak var voice: LiveVoice?
    @ObservationIgnored private var currentImage: (() async -> Data?)?
    @ObservationIgnored private var selectedFrame: Data?
    @ObservationIgnored private var selectedSubmission: (question: String, id: UUID)?
    @ObservationIgnored private var readAnswer: Task<Void, Never>?
    @ObservationIgnored private var stopCapture: (() -> Void)?
    private var sessionID: UUID?
    private var callID: String?
    private var pairedClientID: String?

    var available: Bool {
        #if canImport(ScreenCaptureKit) && !targetEnvironment(simulator)
        if #available(iOS 27, *) { return ScreenKitFeed.isAvailable }
        #endif
        return false
    }

    func start(voice: LiveVoice) {
        guard sessionID == nil, let call = voice.activeScreenCallID else { return }
        #if canImport(ScreenCaptureKit) && !targetEnvironment(simulator)
        if #available(iOS 27, *), ScreenKitFeed.isAvailable {
            guard let pairing = AssistantCenter.shared.foregroundSession, voice.isLive(on: pairing.link) else {
                phase = .failed("Reconnect this voice conversation to share its screen.")
                return
            }
            let id = UUID()
            self.voice = voice
            callID = call
            pairedClientID = pairing.id
            sessionID = id
            lastRun = nil
            questionError = nil
            phase = .choosing
            voice.screenDidHearUser = { [weak self] words, originatingCall in
                guard let self, callID == originatingCall, Self.isScreenQuestion(words), !asking else { return }
                Task { @MainActor in
                    do { _ = try await self.ask(words, session: id) }
                    catch { if self.sessionID == id { self.questionError = error.localizedDescription } }
                }
            }
            voice.screenCallEnded = { [weak self] endedCall in if self?.callID == endedCall { self?.stop() } }
            let feed = ScreenKitFeed(
                frameAvailability: { [weak self] available in
                    guard let self, sessionID == id, voice.activeScreenCallID == call else { return }
                    hasFrame = available
                    if !available { discardSelectedFrame() }
                },
                started: { [weak self] in if self?.sessionID == id { self?.phase = .sharing } },
                ended: { [weak self] error in
                    guard let self, sessionID == id else { return }
                    stop()
                    if let error { phase = .failed(error) }
                }
            )
            currentImage = { await feed.currentImage() }
            stopCapture = { feed.stop() }
            feed.present()
            return
        }
        #endif
        phase = .failed("Screen sharing requires a compatible iPhone running iOS 27 or later.")
    }

    func stop() {
        sessionID = nil
        callID = nil
        pairedClientID = nil
        voice?.screenDidHearUser = nil
        voice?.screenCallEnded = nil
        voice = nil
        currentImage = nil
        selectedFrame = nil
        selectedSubmission = nil
        hasFrame = false
        readAnswer?.cancel()
        readAnswer = nil
        asking = false
        lastRun = nil
        questionError = nil
        stopCapture?()
        stopCapture = nil
        phase = .idle
    }

    nonisolated static func isScreenQuestion(_ spoken: String) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words = spoken.lowercased().trimmingCharacters(in: separators)
        for name in ["hey iterate", "iterate"] where words.hasPrefix(name) {
            words = String(words.dropFirst(name.count)).trimmingCharacters(in: separators)
            break
        }
        return ["look at my screen", "read my screen", "what is on my screen", "what’s on my screen", "what's on my screen"]
            .contains { phrase in
                guard words.hasPrefix(phrase) else { return false }
                guard let next = words.dropFirst(phrase.count).unicodeScalars.first else { return true }
                return separators.contains(next)
            }
    }

    func ask(_ question: String) async throws -> IterateRun {
        guard let sessionID else { throw AssistantIssue.invalidInput("Start screen sharing during an Iterate call first.") }
        return try await ask(question, session: sessionID)
    }

    func selectCurrentFrame() async -> Data? {
        guard phase == .sharing, !asking, hasFrame, let sessionID, let currentImage else { return nil }
        let bytes = await currentImage()
        guard self.sessionID == sessionID, !asking, hasFrame else { return nil }
        selectedFrame = bytes
        selectedSubmission = nil
        return selectedFrame
    }

    func discardSelectedFrame() { selectedFrame = nil; selectedSubmission = nil }

    fileprivate func reportQuestionError(_ error: Error) { questionError = error.localizedDescription }

    func askAboutSelectedFrame(_ question: String) async throws -> IterateRun {
        guard let image = selectedFrame, let sessionID else {
            throw AssistantIssue.invalidInput("Select a new image from your active screen-sharing session.")
        }
        let requestID: UUID
        if let previous = selectedSubmission, previous.question == question {
            requestID = previous.id
        } else {
            requestID = UUID()
            selectedSubmission = (question, requestID)
        }
        let run = try await ask(question, session: sessionID, selection: image, requestID: requestID)
        if self.sessionID == sessionID { discardSelectedFrame() }
        return run
    }

    private func ask(_ question: String, session: UUID, selection: Data? = nil,
                     requestID: UUID = UUID()) async throws -> IterateRun {
        guard phase == .sharing, sessionID == session, let callID, let pairedClientID, let voice,
              voice.activeScreenCallID == callID, hasFrame, let currentImage else {
            throw AssistantIssue.invalidInput("Wait for the first image from your active screen-sharing session.")
        }
        guard !asking else { throw AssistantIssue.invalidInput("Your previous screen question is still in progress.") }
        asking = true
        questionError = nil
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = words.isEmpty ? "Describe what is on the attached screen." : words
        do {
            let frame: Data?
            if let selection { frame = selection } else { frame = await currentImage() }
            guard sessionID == session, voice.activeScreenCallID == callID, hasFrame, let frame else {
                throw AssistantIssue.invalidInput("The shared screen is no longer available.")
            }
            let attachment = IterateAttachment(name: "Shared screen.jpg", contentType: "image/jpeg", data: frame)
            let run = try await AssistantCenter.shared.submit(text: prompt, attachment: attachment,
                                                               requestID: requestID, requiredSession: pairedClientID)
            guard sessionID == session, voice.activeScreenCallID == callID else { return run }
            lastRun = run
            readAnswer = Task { [weak self, weak voice] in
                guard let self, let voice else { return }
                defer {
                    if self.sessionID == session { self.asking = false; self.readAnswer = nil }
                }
                do {
                    let answer = try await AssistantCenter.shared.awaitAnswer(for: run, until: .now.advanced(by: .seconds(45)))
                    try Task.checkCancellation()
                    guard self.sessionID == session, voice.activeScreenCallID == callID else { return }
                    self.lastRun = answer
                    let words = String(answer.answerText.prefix(600))
                    try await voice.speakScreenAnswer(words, for: callID, runID: answer.id)
                } catch {
                    if self.sessionID == session, !Task.isCancelled { self.questionError = error.localizedDescription }
                }
            }
            return run
        } catch {
            if sessionID == session { asking = false; questionError = error.localizedDescription }
            throw error
        }
    }
}

struct IterateScreenShareControl: View {
    let voice: LiveVoice
    @State private var sharing = IterateScreenShare.shared
    @State private var question = ""
    @State private var selected: ScreenPreview?
    @State private var selecting = false

    private struct ScreenPreview: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch sharing.phase {
            case .choosing, .sharing:
                if sharing.phase == .sharing {
                    Button {
                        selecting = true
                        Task {
                            defer { selecting = false }
                            if let data = await sharing.selectCurrentFrame(), let image = UIImage(data: data) {
                                selected = ScreenPreview(image: image)
                            }
                        }
                    } label: { Label("Ask about this screen", systemImage: "text.bubble") }
                        .disabled(selecting || sharing.asking || !sharing.hasFrame)
                    Text("Say “look at my screen” followed by your question. Iterate receives one image and reads the reply on this call.")
                        .font(.footnote)
                    if sharing.asking { ProgressView("Waiting for Iterate…") }
                    if let item = sharing.lastRun, !sharing.asking {
                        Text(item.answerText).textSelection(.enabled)
                        if item.isPending || item.status == .needsInput {
                            Link("Continue in browser", destination: item.url)
                        }
                    }
                }
                Button(role: .destructive) { sharing.stop() } label: {
                    Label(sharing.phase == .sharing ? "Stop sharing screen" : "Cancel screen sharing",
                          systemImage: "stop.circle")
                }
            case .idle, .failed:
                Button { sharing.start(voice: voice) } label: {
                    Label("Share screen with Iterate", systemImage: "rectangle.on.rectangle")
                }
                .disabled(voice.activeScreenCallID == nil || !sharing.available)
                if !sharing.available {
                    Text("Screen sharing requires a compatible iPhone with iOS 27.").font(.footnote)
                } else if voice.activeScreenCallID == nil {
                    Text("Start a voice conversation to share your screen.").font(.footnote)
                }
                if case .failed(let message) = sharing.phase { Text(message).font(.footnote).foregroundStyle(.red) }
            }
            if let message = sharing.questionError { Text(message).font(.footnote).foregroundStyle(.red) }
        }
        .onChange(of: sharing.hasFrame) { _, available in if !available { selected = nil } }
        .sheet(item: $selected, onDismiss: { sharing.discardSelectedFrame(); question = "" }) { snapshot in
            NavigationStack {
                Form {
                    Image(uiImage: snapshot.image)
                        .resizable().scaledToFit().frame(maxHeight: 240)
                        .accessibilityLabel("Image selected for this question")
                    TextField("What should Iterate look for?", text: $question, axis: .vertical).lineLimit(2...6)
                    Button("Send this image to Iterate") {
                        let text = question
                        Task {
                            do {
                                _ = try await sharing.askAboutSelectedFrame(text)
                                selected = nil
                            } catch { sharing.reportQuestionError(error) }
                        }
                    }.disabled(sharing.asking)
                    if let message = sharing.questionError { Text(message).foregroundStyle(.red) }
                }
                .navigationTitle("Ask about this screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { selected = nil } }
                }
            }
        }
        .onChange(of: sharing.phase) { _, phase in if phase != .sharing { selected = nil } }
    }
}

@available(iOS 27.0, *)
struct AskAboutIterateScreen: AppIntent {
    static let title: LocalizedStringResource = "Ask About Shared Screen"
    static let description = IntentDescription("Send one image from your active Iterate screen-sharing call with your question.")
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Question", requestValueDialog: "What should Iterate look for on your screen?")
    var question: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        _ = try await IterateScreenShare.shared.ask(question)
        return .result(value: "Sent to your Iterate call.")
    }
}
