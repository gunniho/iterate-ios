import SwiftUI

@MainActor
struct AgentConversationView: View {
    private let initialTitle: String
    private let pair: (() -> Void)?
    private let startsCall: Bool
    let connection: MindConnection
    @State private var conversation: AgentConversation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colors
    @State private var retry = 0
    @State private var screen = UUID()
    @State private var atBottom = true
    @FocusState private var composerFocused: Bool
    @State private var dictation: AgentDictation?
    @State private var call: CallRequest?
    @State private var inputNotice: String?
    @State private var startedCall = false
    // Symbols drawn at a size of their own grow with the reader's text size.
    @ScaledMetric(relativeTo: .title2) private var backSymbol: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var sendSymbol: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var inputSymbol: CGFloat = 19
    private struct CallRequest: Identifiable { let id = UUID(); let member: String; let sharesScreen: Bool }

    init(agent: IterateAgent, connection: MindConnection) {
        initialTitle = agent.name
        pair = nil
        startsCall = false
        self.connection = connection
        _conversation = State(initialValue: connection.conversations.conversation(for: agent.path))
    }

    /// `startsCall` opens the call at once, for a new agent that was asked for by voice.
    init(draft: AgentConversation, connection: MindConnection, startsCall: Bool = false, pair: @escaping () -> Void) {
        initialTitle = "New Agent"
        self.pair = pair
        self.startsCall = startsCall
        self.connection = connection
        _conversation = State(initialValue: draft)
    }

    private var title: String { conversation.firstMessageTitle ?? initialTitle }
    private var member: String? {
        if case .paired(let id) = connection.pairing { return id }
        return nil
    }

    var body: some View {
        ZStack {
            if conversation.isNewDraft, conversation.outgoingText == nil { Color.clear }
            else { transcript }
        }
        // The transcript runs on under the composer, as it does under the title above.
        .modifier(ComposerBar { composer })
        .defaultFocus($composerFocused, conversation.isNewDraft && !startsCall)
        .background(canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .background(AgentBackGesture().frame(width: 0, height: 0).accessibilityHidden(true))
        .toolbar {
            if #available(iOS 26, *) {
                ToolbarItem(placement: .topBarLeading) { backButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { callButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { backButton }
                ToolbarItem(placement: .topBarTrailing) { callButton }
            }
        }
        .sheet(item: $call, onDismiss: { composerFocused = true }) { request in
            AgentCallView(conversation: conversation, connection: connection, member: request.member,
                          sharesScreen: request.sharesScreen)
        }
        .onAppear {
            if conversation.isNewDraft, !startsCall { composerFocused = true }
        }
        // Who the phone is paired with decides between the call and the Connect screen, as the Call button does.
        .task(id: connection.pairing) {
            guard startsCall, !startedCall, connection.pairing != .checking else { return }
            startedCall = true
            startCall()
        }
        .task(id: observation) {
            if !conversation.isNewDraft { await conversation.open(on: activeLink, for: screen) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dictation?.cancel() }
        }
        .onDisappear {
            dictation?.cancel()
            conversation.leave(screen)
        }
        .sensoryFeedback(trigger: conversation.sendError) { _, failure in failure == nil ? nil : .error }
        .sensoryFeedback(.impact(weight: .light), trigger: (dictation?.phase ?? .idle) == .idle)
    }

    private var canvas: Color { colors == .dark ? Color(uiColor: .systemBackground) : Color(red: 0.992, green: 0.98, blue: 0.976) }
    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: backSymbol, weight: .medium))
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedback())
        .accessibilityLabel("Back")
        .accessibilityIdentifier("iterate.chat.back")
    }

    private var callButton: some View {
        Button { startCall() } label: {
            HStack(spacing: 7) {
                Image(systemName: "phone.fill")
                Text("Call")
            }
            .font(.headline)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(colors == .dark ? Color(uiColor: .label) : Color(white: 0.15), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedback())
        .disabled(conversation.sending || connection.pairing == .checking)
        .accessibilityLabel("Call agent")
        .accessibilityIdentifier("iterate.chat.call")
    }

    private func startCall(sharingScreen: Bool = false) {
        conversation.markInput()
        dictation?.cancel()
        if let member {
            composerFocused = false
            call = CallRequest(member: member, sharesScreen: sharingScreen)
        } else if let pair { pair() }
    }

    private struct ObservationKey: Equatable {
        let link: ObjectIdentifier?
        let retry: Int
    }

    private var observation: ObservationKey? {
        guard !conversation.isNewDraft else { return nil }
        return ObservationKey(link: activeLink.map(ObjectIdentifier.init), retry: retry)
    }

    // The connection decides when the link ends. A glance away keeps the conversation live.
    private var activeLink: MindSocket? { connection.agentLink }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let floor = conversation.floor, floor > 0 {
                        Button("Load earlier messages") { Task { await conversation.loadEarlier() } }
                            .font(.subheadline)
                            .disabled(conversation.loadingEarlier || !conversation.connected)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    ForEach(conversation.messages) { message in
                        ChatMessageRow(message: message, agentName: title, email: email)
                    }
                    if let text = conversation.outgoingText { outgoingRow(text) }
                    if conversation.showsTypingIndicator { AgentTypingBubble() }
                    Color.clear.frame(height: 1)
                        .id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if conversation.floor == nil {
                    if let issue {
                        ContentUnavailableView {
                            Label("Couldn’t load conversation", systemImage: "wifi.exclamationmark")
                        } description: { Text(issue) } actions: { Button("Try again", action: retryRead) }
                    } else { ProgressView("Loading conversation…") }
                } else if conversation.messages.isEmpty, !conversation.isNewDraft, conversation.outgoingText == nil,
                          !conversation.showsTypingIndicator {
                    ContentUnavailableView(conversation.floor == 0 ? "No messages yet" : "No recent messages",
                                           systemImage: "bubble.left.and.bubble.right")
                        .allowsHitTesting(false)
                }
            }
            // A kept conversation appears with its messages, so the first pass also starts at the end.
            .onChange(of: conversation.messages.last?.id, initial: true) { previous, latest in
                if latest != nil, previous == nil || previous == latest || atBottom { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.outgoingText, initial: true) { _, text in
                if text != nil { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.showsTypingIndicator) { _, typing in
                if typing && atBottom { scroll.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.lastSent) { _, id in
                if id != nil { scroll.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var email: String? {
        if case .connected(let email) = connection.phase { return email }
        return nil
    }

    private var issue: String? {
        if case .failed(let reason) = connection.phase { return reason }
        return conversation.readError
    }

    private func retryRead() {
        if connection.agentLink == nil { connection.connect() }
        else if conversation.connected { Task { await conversation.loadEarlier() } }
        else { retry += 1 }
    }

    private func outgoingRow(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(verbatim: text)
                .messageBubble(outgoing: true)
                .accessibilityLabel("You")
                .accessibilityValue(text)
                .accessibilityIdentifier("iterate.chat.pending")
            if let failure = conversation.sendError {
                Text("Couldn’t confirm delivery. \(failure)")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Try again") { Task { await conversation.retryFailedSend(using: connection) } }
                        .tapTarget()
                        .accessibilityIdentifier("iterate.chat.retrySend")
                    Button(conversation.draft.isEmpty ? "Edit message" : "Dismiss") {
                        conversation.dismissFailedSend()
                        composerFocused = true
                    }
                    .tapTarget()
                }
            } else {
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 32)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue = dictation?.issue {
                HStack {
                    Text(issue.message).font(.footnote)
                    Spacer()
                    if issue == .permissions {
                        Button("Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .tapTarget()
                    }
                    Button { dictation?.issue = nil } label: { Image(systemName: "xmark") }
                        .tapTarget()
                        .accessibilityLabel("Dismiss dictation message")
                }
                .padding(.leading, 8)
            } else if let inputNotice {
                Text(inputNotice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 8)
            } else if conversation.isNewDraft, !conversation.draft.isEmpty, connection.pairing == .unpaired, let pair {
                Button("Connect to send", action: pair).tapTarget().padding(.horizontal, 8)
            } else if conversation.floor != nil, !conversation.isNewDraft || !conversation.draft.isEmpty, let issue {
                HStack {
                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Try again", action: retryRead).tapTarget()
                }
                .padding(.horizontal, 8)
            } else if conversation.floor != nil, !conversation.draft.isEmpty,
                      conversation.isNewDraft ? activeLink == nil : !conversation.connected {
                Text("Connecting…").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            HStack(alignment: .bottom, spacing: 0) {
                if conversation.isNewDraft {
                    IterateCaptureView(menuAction: { dictation?.cancel() }, include: { words in
                        inputNotice = nil
                        conversation.include(words)
                        composerFocused = true
                    }, shareScreen: { startCall(sharingScreen: true) })
                }
                TextField(conversation.isNewDraft ? "Message a new agent" : "Message", text: Binding(
                    get: { conversation.draft },
                    set: { dictation?.cancel(); inputNotice = nil; conversation.draft = $0 }
                ), axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...5)
                    .padding(.leading, conversation.isNewDraft ? 0 : 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("iterate.chat.input")
                dictationButton
                if conversation.sending || conversation.draft.contains(where: { !$0.isWhitespace }) {
                    Button {
                        dictation?.cancel()
                        Task { await conversation.sendDraft(using: connection) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: sendSymbol))
                            .tapTarget()
                    }
                    .disabled(conversation.sending || conversation.sendError != nil ||
                              (conversation.isNewDraft ? member == nil : !conversation.connected))
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("iterate.chat.send")
                }
            }
            .modifier(ComposerField())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    private var dictationButton: some View {
        let phase = dictation?.phase ?? .idle
        return Button {
            conversation.markInput()
            if phase != .idle { dictation?.stop(); return }
            guard !connection.voice.isBusy else { inputNotice = "End your call to dictate a message."; return }
            inputNotice = nil
            let input = dictation ?? AgentDictation()
            dictation = input
            composerFocused = true
            input.start(after: conversation.draft) { conversation.draft = $0 }
        } label: {
            Group {
                if phase == .finishing { ProgressView().controlSize(.small) }
                else { Image(systemName: phase == .idle ? "mic" : "stop.circle.fill")
                    .font(.system(size: inputSymbol, weight: .medium))
                    .foregroundStyle(phase == .idle ? Color.secondary : .red)
                    .contentTransition(.symbolEffect(.replace)) }
            }.tapTarget()
        }
        .buttonStyle(PressFeedback())
        .disabled(phase == .finishing)
        .accessibilityLabel(phase == .idle ? "Dictate message" : "Stop dictation")
        .accessibilityHint("Turns spoken words into editable text.")
        .accessibilityIdentifier("iterate.chat.dictate")
    }
}

// SwiftUI disables the native edge swipe when a toolbar supplies its own Back button.
private struct AgentBackGesture: UIViewControllerRepresentable {
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var gesture: UIGestureRecognizer?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var wasEnabled = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let swipe = navigationController?.interactivePopGestureRecognizer, swipe.delegate !== self else { return }
            gesture = swipe
            previousDelegate = swipe.delegate
            wasEnabled = swipe.isEnabled
            swipe.delegate = self
            swipe.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            return navigationController.viewControllers.count > 1 && navigationController.transitionCoordinator == nil
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if let gesture, gesture.delegate === self {
                gesture.delegate = previousDelegate
                gesture.isEnabled = wasEnabled
            }
            gesture = nil
        }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
}

private struct ChatMessageRow: View {
    let message: AgentChatMessage
    let agentName: String
    let email: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .input { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 5) {
                if message.role == .input, let sender = message.sender, sender != email {
                    Text(sender).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if !message.text.isEmpty {
                    if message.role == .agent, let formatted = MessageMarkdown.formatted(message.text) {
                        Text(formatted)
                    } else { Text(verbatim: message.text) }
                }
                ForEach(Array(message.files.enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: "paperclip").font(.footnote)
                }
            }
            .textSelection(.enabled)
            .messageBubble(outgoing: message.role == .input)
            if message.role == .agent { Spacer(minLength: 32) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .agent ? agentName : (message.sender == email && email != nil ? "You" : (message.sender ?? "Message")))
        .accessibilityValue(([message.text] + message.files).filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityIdentifier("iterate.chat.message")
    }
}

/// An agent's reply with its inline Markdown read once, not on every pass of a scrolling list.
@MainActor
private enum MessageMarkdown {
    private final class Parsed { let text: AttributedString?; init(_ text: AttributedString?) { self.text = text } }
    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 400
        return cache
    }()

    static func formatted(_ source: String) -> AttributedString? {
        if let known = cache.object(forKey: source as NSString) { return known.text }
        let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        cache.setObject(Parsed(parsed), forKey: source as NSString)
        return parsed
    }
}

/// Holds the composer at the bottom as a floating layer, with the conversation scrolling beneath it.
private struct ComposerBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        // From iOS 26 the scroll view softens what passes under a bar. Before, the bar's material does.
        if #available(iOS 26, *) { content.safeAreaBar(edge: .bottom, spacing: 0) { bar() } }
        else { content.safeAreaInset(edge: .bottom, spacing: 0) { bar().background(.bar) } }
    }
}

/// The message field's surface: glass over the conversation, or a fill on the bar's material.
private struct ComposerField: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: .rect(cornerRadius: 22)) }
        else { content.background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 22)) }
    }
}

private struct AgentTypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if reduceMotion || scenePhase != .active {
                dots(highlight: nil)
            } else {
                PhaseAnimator([0, 1, 2, 3]) { phase in
                    dots(highlight: phase == 3 ? nil : phase)
                } animation: { _ in .easeInOut(duration: 0.22) }
            }
        }
        .messageBubble(outgoing: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent is typing")
        .accessibilityIdentifier("iterate.chat.typing")
    }

    private func dots(highlight: Int?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(highlight == nil || highlight == index ? 1 : 0.48)
            }
        }
        .frame(height: 16)
    }
}

private struct MessageBubble: ViewModifier {
    let outgoing: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17)
        content
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background {
                if outgoing { shape.fill(.tint.opacity(contrast == .increased ? 0.2 : 0.13)) }
                else { shape.fill(Color(uiColor: .secondarySystemFill)) }
            }
            // A pale fill alone is a faint edge. Increase Contrast gets one that is drawn.
            .overlay { if contrast == .increased { shape.strokeBorder(.primary.opacity(0.5), lineWidth: 1) } }
    }
}

private extension View {
    func messageBubble(outgoing: Bool) -> some View { modifier(MessageBubble(outgoing: outgoing)) }
}
