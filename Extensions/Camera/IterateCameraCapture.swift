import ExtensionKit
import LockedCameraCapture
import SwiftUI
import UIKit

@main
struct IterateCameraCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in LockedPhotoScene(session: session) }
    }
}

private struct LockedPhotoScene: View {
    let session: LockedCameraCaptureSession
    @Environment(\.dismiss) private var dismiss
    @State private var generation = 0
    @State private var savedPhotoID: UUID?
    @State private var opening = false
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .top) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                IteratePhotoPicker(captured: save, cancelled: { dismiss() },
                                  failed: { error = "Could not read the captured photo." })
                    .id(generation)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView("Camera unavailable", systemImage: "camera")
            }
            if let savedPhotoID {
                Button {
                    Task { await openReview(savedPhotoID) }
                } label: {
                    Label(opening ? "Opening Iterate…" : "Review photo in Iterate", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                .disabled(opening)
                .padding()
            }
        }
        .alert("Camera", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save(_ data: Data) {
        do {
            let id = UUID()
            let filename = Deployment.current.workspaceKey + "-" + id.uuidString
            let url = session.sessionContentURL.appendingPathComponent(filename).appendingPathExtension("jpg")
            try data.write(to: url, options: .atomic)
            savedPhotoID = id
            generation += 1
        } catch { self.error = error.localizedDescription }
    }

    private func openReview(_ id: UUID) async {
        opening = true
        defer { opening = false }
        do {
            let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
            activity.userInfo = ["iterateCaptureID": id.uuidString]
            try await session.openApplication(for: activity)
        } catch { self.error = error.localizedDescription }
    }
}
