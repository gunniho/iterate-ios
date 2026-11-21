import Foundation
import SafariServices

final class SafariHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let response = SafariResponse(context)
        guard let rawID = message?["id"] as? String, let id = UUID(uuidString: rawID) else {
            Self.finish(response, ok: false, message: "Open the Safari extension again.")
            return
        }
        if message?["mode"] as? String == "check" {
            Task { @MainActor in
                do { Self.finish(response, run: try await AssistantCenter.shared.refresh(id: id)) }
                catch { Self.finish(response, ok: false, message: error.localizedDescription) }
            }
            return
        }
        guard let mode = message?["mode"] as? String, ["ask", "remember"].contains(mode),
              let page = message?["page"] as? [String: String],
              let address = page["url"], address.utf8.count <= 8192,
              let url = URLComponents(string: address), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil
        else {
            Self.finish(response, ok: false, message: "Iterate couldn't read this web address.")
            return
        }

        let question = String((message?["question"] as? String ?? "").prefix(2000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == "remember" || !question.isEmpty else {
            Self.finish(response, ok: false, message: "Enter a question first.")
            return
        }
        let title = String((page["title"] ?? host).prefix(240))
        let selection = String((page["selection"] ?? "").prefix(8000))
        let instruction = mode == "remember" ? "Remember this webpage." : question
        var text = "\(instruction)\n\nWebpage: \(title)\n\(address)"
        if !selection.isEmpty { text += "\n\nSelected passage:\n\(selection)" }

        Task { @MainActor in
            do {
                let run = try await AssistantCenter.shared.submit(text: text, remember: mode == "remember", requestID: id)
                Self.finish(response, run: run)
            } catch {
                Self.finish(response, ok: false, message: error.localizedDescription)
            }
        }
    }

    private static func finish(_ response: SafariResponse, run: IterateRun) {
        finish(response, ok: true, message: run.answerText, run: run)
    }

    private static func finish(_ response: SafariResponse, ok: Bool, message: String, run: IterateRun? = nil) {
        var payload: [String: Any] = ["ok": ok, "message": message]
        if let run {
            payload["id"] = run.id.uuidString.lowercased()
            payload["url"] = run.url.absoluteString
            payload["status"] = run.status.rawValue
        }
        let result = NSExtensionItem()
        result.userInfo = [SFExtensionMessageKey: payload]
        response.complete(result)
    }
}

// Each beginRequest creates one response. The async resolution owns the sole completion.
private final class SafariResponse: @unchecked Sendable {
    private let context: NSExtensionContext
    init(_ context: NSExtensionContext) { self.context = context }
    func complete(_ item: NSExtensionItem) { context.completeRequest(returningItems: [item]) }
}
