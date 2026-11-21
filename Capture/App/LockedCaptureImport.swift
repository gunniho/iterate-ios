import Foundation
import LockedCameraCapture

@available(iOS 18.0, *)
actor LockedCaptureImport {
    static let shared = LockedCaptureImport()
    private var importing = Set<URL>()

    func importPhotos(from sessionURLs: [URL]) async throws -> [UUID] {
        var imported: [(id: UUID, date: Date)] = []
        for url in sessionURLs {
            guard importing.insert(url).inserted else { continue }
            defer { importing.remove(url) }
            let items = try FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: .skipsHiddenFiles)
            var recognized = 0
            let scope = Deployment.current.workspaceKey + "-"
            for photo in items {
                let stem = photo.deletingPathExtension().lastPathComponent
                guard photo.pathExtension.lowercased() == "jpg", stem.hasPrefix(scope),
                      let id = UUID(uuidString: String(stem.dropFirst(scope.count))) else { continue }
                let properties = try photo.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard properties.isRegularFile == true else { continue }
                if try !IterateCaptureInbox.contains(id) {
                    let attachment = try CapturedFile.read(photo, suggestedName: "Camera photo.jpg", type: .jpeg)
                    try IterateCaptureInbox.save(CaptureDraft(id: id, attachment: attachment))
                }
                recognized += 1
                imported.append((id, properties.contentModificationDate ?? .distantPast))
            }
            if recognized > 0, recognized == items.count {
                try await LockedCameraCaptureManager.shared.invalidateSessionContent(at: url)
            }
        }
        return imported.sorted { $0.date > $1.date }.map(\.id)
    }
}
