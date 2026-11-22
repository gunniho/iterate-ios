import Foundation

enum RunStatus: String, Codable, Sendable {
    case queued, running, needsInput, completed, failed, cancelled
}

struct IterateRun: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: String
    let title: String
    let prompt: String
    let status: RunStatus
    var response: String?
    let createdAt: Date
    let updatedAt: Date
    var responseLength: Int? = nil

    var isPending: Bool { status == .queued || status == .running }

    var hasFullResponse: Bool {
        let length = response?.utf16.count ?? 0
        if let responseLength { return length >= responseLength }
        // Older listings can end at 21,999 units if the cutoff would split an emoji.
        return length < 21_999
    }

    var answerText: String {
        if let response, !response.isEmpty, !isPending { return response }
        switch status {
        case .queued, .running: return "Iterate is working on your reply."
        case .needsInput: return "Iterate has a follow-up question."
        case .completed: return kind == "remember" ? "Saved in Iterate." : "Iterate finished without a written reply."
        case .failed: return "Iterate couldn’t finish this request."
        case .cancelled: return "The request was cancelled."
        }
    }

    var shortcutAnswer: String {
        isPending || status == .needsInput ? answerText + "\n" + url.absoluteString : answerText
    }

    var url: URL { Deployment.current.runURL(id) }
}

struct IterateAttachment: Sendable {
    static let maximumBytes = 2 * 1024 * 1024
    let name: String
    let contentType: String
    let data: Data
}

enum AssistantIssue: LocalizedError {
    case unpaired, changedSession, storage, invalidInput(String), remote(String), accessDenied(String), conflict(String), unavailable
    var errorDescription: String? {
        switch self {
        case .unpaired: "Open Iterate and connect your iPhone first."
        case .changedSession: "Your Iterate connection changed. Open the app and try again."
        case .storage: "Iterate’s shared storage is unavailable. Unlock your device and try again."
        case .invalidInput(let message), .remote(let message), .accessDenied(let message), .conflict(let message): message
        case .unavailable: "Iterate could not complete this request. Try again in a moment."
        }
    }
}

enum IterateAppGroup {
    static let identifier = Deployment.current.appGroup
    static let yourMoveWidgetKind = Deployment.current.bundleID + ".your-move"
    static let recentAgentsWidgetKind = Deployment.current.bundleID + ".recent-agents"

    static func container() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw AssistantIssue.storage
        }
        let workspace = url.appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(Deployment.current.workspaceKey, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }
}
