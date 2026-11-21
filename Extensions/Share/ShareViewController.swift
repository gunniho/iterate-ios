import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var loading: Task<Void, Never>?
    private var hosted: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        show(ProgressView("Reading selected item…"))
        guard let context = extensionContext else { return }
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        loading = Task { [weak self] in
            do {
                let draft = try await ShareInput.draft(from: items)
                try Task.checkCancellation()
                self?.show(NavigationStack {
                    CaptureReview(draft, savedInInbox: false) { [weak self] in self?.finish() }
                        .environment(\.scenePhase, .active)
                })
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(VStack(spacing: 18) {
                    ContentUnavailableView("Could not open this item", systemImage: "paperclip",
                                           description: Text(error.localizedDescription))
                    Button("Close") { [weak self] in self?.finish() }.buttonStyle(.borderedProminent)
                }.padding())
            }
        }
    }

    private func finish() {
        loading?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func show<Content: View>(_ content: Content) {
        if let hosted {
            hosted.willMove(toParent: nil)
            hosted.view.removeFromSuperview()
            hosted.removeFromParent()
        }
        let controller = UIHostingController(rootView: content)
        hosted = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        controller.didMove(toParent: self)
    }
}

private enum ShareInput {
    @MainActor
    static func draft(from items: [NSExtensionItem]) async throws -> CaptureDraft {
        var message: [String] = []
        var file: CapturedFile?
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty, !message.contains(text) {
                message.append(text)
            }
            for provider in item.attachments ?? [] {
                try Task.checkCancellation()
                let draft = try await read(provider)
                if let attachment = draft.attachment {
                    guard file == nil else { throw CaptureIssue.multipleItems }
                    file = attachment
                }
                if !draft.text.isEmpty, !message.contains(draft.text) { message.append(draft.text) }
            }
        }
        let selection = CaptureDraft(text: message.joined(separator: "\n\n"), attachment: file)
        try selection.validate()
        return selection
    }

    @MainActor
    private static func read(_ provider: NSItemProvider) async throws -> CaptureDraft {
        let name = provider.suggestedName
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await loadURL(provider, type: .fileURL)
            guard url.isFileURL else { throw CaptureIssue.unsupported }
            return try await Task.detached {
                CaptureDraft(attachment: try CapturedFile.readSecurityScoped(url, suggestedName: name))
            }.value
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(provider, type: .url)
            guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
                throw CaptureIssue.unsupported
            }
            return CaptureDraft(text: url.absoluteString)
        }
        for preferred in [UTType.image, .pdf] where provider.hasItemConformingToTypeIdentifier(preferred.identifier) {
            return try await fileDraft(provider, name: name, conformingTo: preferred)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let text: String = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let text = item as? String {
                        continuation.resume(returning: text)
                    } else if let text = item as? NSAttributedString {
                        continuation.resume(returning: text.string)
                    } else if let data = item as? Data, data.count <= 100_000,
                              let text = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: text)
                    } else { continuation.resume(throwing: CaptureIssue.unsupported) }
                }
            }
            let draft = CaptureDraft(text: text)
            try draft.validate()
            return draft
        }
        return try await fileDraft(provider, name: name, conformingTo: .data)
    }

    @MainActor
    private static func loadURL(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = value as? URL { continuation.resume(returning: url) }
                else if let string = value as? String, let url = URL(string: string) { continuation.resume(returning: url) }
                else { continuation.resume(throwing: CaptureIssue.unsupported) }
            }
        }
    }

    @MainActor
    private static func fileDraft(_ provider: NSItemProvider, name: String?, conformingTo preferred: UTType) async throws -> CaptureDraft {
        guard let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: { $0.conforms(to: preferred) }) else {
            throw CaptureIssue.unsupported
        }
        let file: CapturedFile = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: CaptureIssue.unsupported); return }
                // The provider deletes its temporary file when this callback returns.
                do { continuation.resume(returning: try CapturedFile.read(url, suggestedName: name, type: type)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        return CaptureDraft(attachment: file)
    }
}
