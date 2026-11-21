import AppIntents
import SwiftUI
import UniformTypeIdentifiers

#if ITERATE_SIRI_PREVIEW
@AppIntent(.tool)
#endif
struct AskIterate: AppIntent {
    static let title: LocalizedStringResource = "Ask Iterate"
    static let description = IntentDescription("Send a question to your paired assistant. Returns the answer or a link to continue in your browser.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Question", description: "The question to send to the user's paired assistant.", requestValueDialog: "What would you like to ask Iterate?") var question: String
    static var parameterSummary: some ParameterSummary { Summary("Ask Iterate \(\.$question)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let deadline = ContinuousClock.now.advanced(by: .seconds(18))
        let run = try await AssistantCenter.shared.submit(text: question)
        let result = try await AssistantCenter.shared.awaitAnswer(for: run, until: deadline)
        let text = result.shortcutAnswer
        return .result(value: text, dialog: "\(text)")
    }
}

#if ITERATE_SIRI_PREVIEW
@AppIntent(.tool)
#endif
struct RememberInIterate: AppIntent {
    static let title: LocalizedStringResource = "Remember in Iterate"
    static let description = IntentDescription("Save text or a link as a memory with your paired assistant.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Text or URL", description: "The exact text or link the person wants Iterate to remember.") var text: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let run = try await AssistantCenter.shared.submit(text: text, remember: true)
        let confirmation = run.isPending ? "Sent to Iterate." : run.answerText
        return .result(value: confirmation, dialog: "\(confirmation)")
    }
}

#if ITERATE_SIRI_PREVIEW
@AppIntent(.tool)
#endif
struct SendFileToIterate: AppIntent {
    static let title: LocalizedStringResource = "Send File to Iterate"
    static let description = IntentDescription("Send a selected image or document to Iterate with a question.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "File", description: "An image or document selected by the person, up to 2 MB.") var file: IntentFile
    @Parameter(title: "Question", description: "What to remember or investigate about the file.", default: "Remember this file.") var question: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let url = file.fileURL, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > IterateAttachment.maximumBytes { throw AssistantIssue.invalidInput("Choose a file of 2 MB or less.") }
        let attachment = IterateAttachment(name: file.filename, contentType: file.type?.preferredMIMEType ?? "application/octet-stream",
                                         data: file.data)
        let deadline = ContinuousClock.now.advanced(by: .seconds(18))
        let run = try await AssistantCenter.shared.submit(text: question, attachment: attachment, remember: true)
        let result = try await AssistantCenter.shared.awaitAnswer(for: run, until: deadline)
        return .result(value: result.shortcutAnswer)
    }
}

#if ITERATE_SIRI_PREVIEW
@AppIntent(.tool)
#endif
struct BriefMeWithIterate: AppIntent {
    static let title: LocalizedStringResource = "Get Iterate Briefing"
    static let description = IntentDescription("Prepare a personal briefing. Optional context can come from another Shortcuts action.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Context", description: "Optional information the person chose to include in this briefing.") var context: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let deadline = ContinuousClock.now.advanced(by: .seconds(18))
        let run = try await AssistantCenter.shared.briefing(context: context)
        let result = try await AssistantCenter.shared.awaitAnswer(for: run, until: deadline)
        let text = result.shortcutAnswer
        return .result(value: text, dialog: "\(text)")
    }
}

struct IterateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartNewIterateAgent(), phrases: ["Start a new agent in \(.applicationName)"],
                    shortTitle: "New Agent", systemImageName: "square.and.pencil")
        AppShortcut(intent: TalkToIterate(), phrases: ["Talk to \(.applicationName)", "Start a conversation with \(.applicationName)"],
                    shortTitle: "Talk to Iterate", systemImageName: "waveform")
        AppShortcut(intent: AskIterate(), phrases: ["Ask \(.applicationName)"], shortTitle: "Ask Iterate", systemImageName: "text.bubble")
        AppShortcut(intent: RememberInIterate(), phrases: ["Remember this in \(.applicationName)"], shortTitle: "Remember this", systemImageName: "bookmark")
        AppShortcut(intent: CaptureWithIterate(), phrases: ["Capture with \(.applicationName)"], shortTitle: "Capture", systemImageName: "viewfinder")
        AppShortcut(intent: BriefMeWithIterate(), phrases: ["Brief me with \(.applicationName)"], shortTitle: "Brief me", systemImageName: "sunrise")
    }
}

enum IterateContext: String, AppEnum {
    case all, work, personal
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Assistant context"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.all: "Everything", .work: "Work", .personal: "Personal"]
}

struct IterateFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Iterate Context"
    @Parameter(title: "Context", default: .all) var context: IterateContext
    var displayRepresentation: DisplayRepresentation { .init(title: "\(context.rawValue.capitalized)") }
    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: IterateAppGroup.identifier)?.set(context == .all ? nil : context.rawValue, forKey: FocusContext.key)
        return .result()
    }
}

@available(iOS 26.2, *)
@AppIntent(schema: .assistant.activate)
struct ActivateIterateConversation {
    static let supportedModes: IntentModes = .foreground
    @MainActor func perform() async throws -> some IntentResult {
        NativeRouteBus.shared.open(.talk)
        return .result()
    }
}
