import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureIssue: LocalizedError {
    case unavailable, unsupported, tooLarge, tooMuchText, multipleItems, image, noDraft

    var errorDescription: String? {
        switch self {
        case .unavailable: "The shared storage on this iPhone is unavailable. Unlock the device and try again."
        case .unsupported: "Choose a photo, document, webpage, or text."
        case .tooLarge: "Choose a smaller file. Iterate accepts attachments up to 2 MB."
        case .tooMuchText: "Shorten the selected text to 16,000 characters."
        case .multipleItems: "Choose one attachment per message to Iterate."
        case .image: "The photo could not be read."
        case .noDraft: "The capture is no longer available."
        }
    }
}

struct CapturedFile: Codable, Sendable {
    static let maximumBytes = IterateAttachment.maximumBytes
    let name: String
    let contentType: String
    let data: Data

    init(name: String, contentType: String, data: Data) throws {
        guard !data.isEmpty else { throw CaptureIssue.unsupported }
        guard data.count <= Self.maximumBytes else { throw CaptureIssue.tooLarge }
        let leaf = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let cleaned = leaf.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Attachment" :
            String(decoding: cleaned.utf16.prefix(160), as: UTF16.self)
        self.contentType = contentType
        self.data = data
    }

    static func read(_ url: URL, suggestedName: String? = nil, type: UTType? = nil) throws -> Self {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard attributes.isRegularFile == true else { throw CaptureIssue.unsupported }
        let name = suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        let kind = type ?? attributes.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if kind.conforms(to: .image) {
            guard (attributes.fileSize ?? 0) <= 64 * 1024 * 1024 else { throw CaptureIssue.tooLarge }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CaptureIssue.image }
            return try fromImage(source, name: name)
        }
        guard (attributes.fileSize ?? 0) <= maximumBytes else { throw CaptureIssue.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let contents = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try Self(name: name, contentType: kind.preferredMIMEType ?? "application/octet-stream", data: contents)
    }

    static func readSecurityScoped(_ url: URL, suggestedName: String? = nil) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var result: Result<CapturedFile, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { selected in
            result = Result { try read(selected, suggestedName: suggestedName) }
        }
        if let error { throw error }
        guard let result else { throw CaptureIssue.unsupported }
        return try result.get()
    }

    static func fromImageData(_ data: Data, name: String) throws -> Self {
        guard !data.isEmpty else { throw CaptureIssue.image }
        guard data.count <= 64 * 1024 * 1024 else { throw CaptureIssue.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CaptureIssue.image }
        return try fromImage(source, name: name)
    }

    private static func fromImage(_ source: CGImageSource, name: String) throws -> Self {
        for dimension in [2200, 1600, 1000] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CaptureIssue.image
            }
            let encoded = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CaptureIssue.image
            }
            CGImageDestinationAddImage(output, frame, [kCGImageDestinationLossyCompressionQuality: 0.83] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw CaptureIssue.image }
            if encoded.length <= maximumBytes {
                let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
                return try Self(name: (stem.isEmpty ? "Photo" : stem) + ".jpg", contentType: "image/jpeg", data: encoded as Data)
            }
        }
        throw CaptureIssue.tooLarge
    }
}

struct CaptureDraft: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var text: String
    let attachment: CapturedFile?
    var remember: Bool

    init(id: UUID = UUID(), text: String = "", attachment: CapturedFile? = nil, remember: Bool = false) {
        self.id = id
        self.createdAt = Date()
        self.text = text
        self.attachment = attachment
        self.remember = remember
    }

    var title: String { attachment?.name ?? String(text.prefix(65)) }

    /// Reusing a draft after an interrupted submission produces the same ID. Editing its message produces a new ID.
    var submissionID: UUID {
        var digest = SHA256()
        digest.update(data: Data(id.uuidString.utf8))
        digest.update(data: Data([remember ? 1 : 0]))
        digest.update(data: Data(SHA256.hash(data: Data(text.utf8))))
        if let attachment {
            digest.update(data: Data(SHA256.hash(data: Data(attachment.name.utf8))))
            digest.update(data: Data(SHA256.hash(data: Data(attachment.contentType.utf8))))
            digest.update(data: attachment.data)
        }
        var bytes = Array(digest.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    func validate() throws {
        guard text.utf16.count <= 16_000 else { throw CaptureIssue.tooMuchText }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil else {
            throw CaptureIssue.unsupported
        }
        if let attachment, attachment.data.count > CapturedFile.maximumBytes { throw CaptureIssue.tooLarge }
    }
}

enum IterateCaptureInbox {
    private static func directory() throws -> URL {
        let files = FileManager.default
        var directory = try IterateAppGroup.container().appendingPathComponent("CaptureDrafts", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.complete])
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        return directory
    }

    static func save(_ draft: CaptureDraft) throws {
        try draft.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(draft).write(to: file(for: draft.id), options: [.atomic, .completeFileProtection])
    }

    struct Summary: Identifiable {
        let id: UUID
        let title: String
        let date: Date
    }

    static func list() throws -> [Summary] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
        return try urls.filter { $0.pathExtension == "capture" }.map { url in
            let draft = try PropertyListDecoder().decode(CaptureDraft.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            return Summary(id: draft.id, title: draft.title, date: draft.createdAt)
        }.sorted { $0.date > $1.date }
    }

    static func draft(_ id: UUID) throws -> CaptureDraft {
        let url = try file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CaptureIssue.noDraft }
        return try PropertyListDecoder().decode(CaptureDraft.self, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func contains(_ id: UUID) throws -> Bool {
        try FileManager.default.fileExists(atPath: file(for: id).path)
    }

    static func remove(_ id: UUID) throws {
        let url = try file(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func clear() throws {
        let root = try directory()
        try FileManager.default.removeItem(at: root)
    }

    private static func file(for id: UUID) throws -> URL {
        try directory().appendingPathComponent(id.uuidString).appendingPathExtension("capture")
    }
}
