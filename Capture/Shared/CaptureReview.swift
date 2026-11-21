import SwiftUI
import UIKit

struct CaptureReview: View {
    let draft: CaptureDraft
    let savedInInbox: Bool
    let finished: () -> Void
    @State private var text: String
    @State private var remember: Bool
    @State private var busy = false
    @State private var answer: IterateRun?
    @State private var issue: String?
    @FocusState private var editingMessage: Bool
    private var hasContent: Bool { draft.attachment != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(_ draft: CaptureDraft, savedInInbox: Bool, finished: @escaping () -> Void) {
        self.draft = draft
        self.savedInInbox = savedInInbox
        self.finished = finished
        _text = State(initialValue: draft.text)
        _remember = State(initialValue: draft.remember)
    }

    var body: some View {
        Form {
            if let reply = Binding($answer) {
                Section("Iterate’s reply") { IterateAnswerView(run: reply) }
            } else {
                editor
            }
            if let issue { Text(issue).foregroundStyle(.red).accessibilityLabel("Capture error. " + issue) }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .navigationTitle(answer == nil ? "Review capture" : "Capture")
        .navigationBarTitleDisplayMode(.inline)
        .task { if draft.attachment == nil && draft.text.isEmpty { editingMessage = true } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close", action: finished).disabled(busy) }
        }
    }

    @ViewBuilder private var editor: some View {
        if let file = draft.attachment {
            Section("Attachment") {
                if file.contentType == "image/jpeg", let image = UIImage(data: file.data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                        .accessibilityLabel(file.name)
                }
                Label(file.name, systemImage: "paperclip")
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section("Message") {
            TextField("What should Iterate do with this?", text: $text, axis: .vertical)
                .lineLimit(3...9)
                .focused($editingMessage)
                .accessibilityLabel("Capture message")
            Toggle("Remember this", isOn: $remember)
        }
        Section {
            Button {
                Task { await send() }
            } label: {
                if busy { ProgressView("Sending…") }
                else { Label(remember ? "Send and remember" : "Send to Iterate", systemImage: "arrow.up.circle.fill") }
            }
            .disabled(!hasContent)
            Button {
                save()
            } label: { Label(savedInInbox ? "Save changes for later" : "Save on iPhone for later", systemImage: "tray.and.arrow.down") }
            .disabled(!hasContent)
        }
    }

    private var edited: CaptureDraft {
        var edited = draft
        edited.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.remember = remember
        return edited
    }

    private func save() {
        do { try IterateCaptureInbox.save(edited); finished() }
        catch { issue = error.localizedDescription }
    }

    private func send() async {
        guard !busy else { return }
        busy = true
        issue = nil
        defer { busy = false }
        do {
            let capture = edited
            try capture.validate()
            try IterateCaptureInbox.save(capture)
            let prompt = capture.text.isEmpty
                ? (remember ? "Remember the attached item." : "Describe the attached item.")
                : capture.text
            let file = capture.attachment.map { IterateAttachment(name: $0.name, contentType: $0.contentType, data: $0.data) }
            let run = try await AssistantCenter.shared.submit(text: prompt, attachment: file, remember: remember, requestID: capture.submissionID)
            editingMessage = false
            answer = run
            try IterateCaptureInbox.remove(capture.id)
        } catch { issue = error.localizedDescription }
    }
}
