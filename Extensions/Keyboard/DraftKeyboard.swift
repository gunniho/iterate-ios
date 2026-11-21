import SwiftUI
import UIKit

final class DraftKeyboardController: UIInputViewController {
    private let drafting = KeyboardDraft()
    private var document: UUID?

    override func viewDidLoad() {
        super.viewDidLoad()
        drafting.controller = self
        let host = UIHostingController(rootView: IterateKeyboard(draft: drafting))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 278)
        height.priority = .defaultHigh
        height.isActive = true
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        let current = textDocumentProxy.documentIdentifier
        if let document, document != current { drafting.close() }
        document = current
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        drafting.close()
    }
}

@MainActor @Observable
private final class KeyboardDraft {
    weak var controller: DraftKeyboardController?
    var isDrafting = false
    var prompt = ""
    var selection = ""
    var response: String?
    var feedback = ""
    var busy = false
    var pending: UUID?
    private var submittedText: String?
    private var requestID = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?

    func close() {
        work?.cancel()
        work = nil
        isDrafting = false
        prompt = ""
        selection = ""
        response = nil
        pending = nil
        busy = false
        feedback = ""
        submittedText = nil
        requestID = UUID()
    }

    func type(_ text: String) {
        if isDrafting {
            guard !busy, pending == nil else { return }
            if prompt.count + text.count <= 2000 { prompt.append(text) }
        } else {
            controller?.textDocumentProxy.insertText(text)
        }
    }

    func backspace() {
        if isDrafting {
            if !busy, pending == nil, !prompt.isEmpty { prompt.removeLast() }
        } else {
            controller?.textDocumentProxy.deleteBackward()
        }
    }

    func includeSelection() {
        selection = String((controller?.textDocumentProxy.selectedText ?? "").prefix(6000))
        if selection.isEmpty { feedback = "Select text in the app first." }
        else { feedback = "" }
    }

    func ask() {
        guard !busy else { return }
        guard controller?.hasFullAccess == true else {
            feedback = "Enable Allow Full Access for Iterate in Keyboard settings to send a request."
            return
        }
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending != nil || !instruction.isEmpty else {
            feedback = "Type what you’d like to draft."
            return
        }
        let request = "Draft text for me to insert in another app. Return just the draft.\n\n\(instruction)"
            + (selection.isEmpty ? "" : "\n\nSelected text:\n\(selection)")
        if submittedText != request {
            submittedText = request
            requestID = UUID()
        }
        busy = true
        feedback = "Waiting for Iterate…"
        work = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { busy = false } }
            do {
                let initial: IterateRun
                if let pending {
                    initial = try await AssistantCenter.shared.refresh(id: pending)
                } else {
                    initial = try await AssistantCenter.shared.submit(text: request, requestID: requestID)
                }
                try Task.checkCancellation()
                pending = initial.id
                let run = try await AssistantCenter.shared.awaitAnswer(for: initial, until: .now.advanced(by: .seconds(12)))
                try Task.checkCancellation()
                switch run.status {
                case .completed:
                    if let text = run.response, !text.isEmpty {
                        response = text
                        feedback = ""
                    } else { feedback = "Iterate finished without a draft." }
                case .needsInput:
                    pending = nil
                    submittedText = nil
                    feedback = run.answerText + " Edit your instructions and ask again."
                case .failed, .cancelled:
                    pending = nil
                    submittedText = nil
                    feedback = run.response ?? "The draft could not be completed."
                case .queued, .running:
                    feedback = "Still working. Tap Check reply in a moment."
                }
            } catch {
                if !Task.isCancelled { feedback = error.localizedDescription }
            }
        }
    }

    func insert() {
        guard let response, let controller else { return }
        controller.textDocumentProxy.insertText(response)
        close()
    }
}

private struct IterateKeyboard: View {
    let draft: KeyboardDraft
    @State private var shift = false
    @State private var symbols = false

    var body: some View {
        VStack(spacing: 4) {
            if draft.isDrafting { composer } else {
                HStack {
                    Button("Draft with Iterate") { draft.isDrafting = true }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 3) {
                    if index == 2 && !symbols {
                        key(shift ? "⬆" : "⇧", label: shift ? "Turn off shift" : "Shift") { shift.toggle() }
                    }
                    ForEach(rows[index], id: \.self) { character in
                        let text = shift && !symbols ? character.uppercased() : character
                        key(text) { draft.type(text); shift = false }
                    }
                    if index == 2 { key("⌫", label: "Delete") { draft.backspace() } }
                }
            }
            HStack(spacing: 4) {
                if let controller = draft.controller, controller.needsInputModeSwitchKey {
                    NextKeyboardButton(controller: controller).frame(width: 40)
                }
                key(symbols ? "ABC" : "123", label: "Change keyboard layout") { symbols.toggle(); shift = false }
                    .frame(width: 48)
                key("space", label: "Space") { draft.type(" ") }
                key("return", label: "Return") { draft.type("\n") }.frame(width: 68)
            }
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    @ViewBuilder private var composer: some View {
        HStack {
            Button("Close") { draft.close() }
            Spacer()
            if draft.response != nil {
                Button("Insert draft") { draft.insert() }.buttonStyle(.borderedProminent)
            } else {
                if draft.pending == nil {
                    Button(draft.selection.isEmpty ? "Use selection" : "Remove selection") {
                        if draft.selection.isEmpty { draft.includeSelection() } else { draft.selection = "" }
                    }.disabled(draft.busy)
                }
                Button(draft.pending == nil ? "Ask" : "Check reply") { draft.ask() }
                    .buttonStyle(.borderedProminent).disabled(draft.busy)
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !draft.selection.isEmpty, draft.response == nil {
                    Text(draft.selection).font(.caption).foregroundStyle(.secondary)
                }
                Text(draft.response ?? (draft.prompt.isEmpty ? "Type your drafting instructions…" : draft.prompt))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !draft.feedback.isEmpty { Text(draft.feedback).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxHeight: 62)
    }

    private var rows: [[String]] {
        if symbols { return ["1234567890", "-/:;()$&@", ".,?!‘’#"].map { $0.map(String.init) } }
        return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
    }

    private func key(_ value: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(value).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label ?? value)
    }
}

private struct NextKeyboardButton: UIViewRepresentable {
    let controller: UIInputViewController

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.accessibilityLabel = "Next keyboard"
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}
