import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIImagePickerController handles Camera Control and volume-button shutter events.
struct IteratePhotoPicker: UIViewControllerRepresentable {
    let captured: (Data) -> Void
    let cancelled: () -> Void
    let failed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.mediaTypes = [UTType.image.identifier]
        camera.cameraCaptureMode = .photo
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ camera: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ camera: UIImagePickerController, coordinator: Coordinator) {
        coordinator.cancelPreparation()
    }

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: IteratePhotoPicker
        private var preparation: Task<Void, Never>?
        init(parent: IteratePhotoPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.failed()
                return
            }
            cancelPreparation()
            preparation = Task {
                let photo: UIImage?
                if max(image.size.width, image.size.height) * image.scale > 2200 {
                    photo = await image.byPreparingThumbnail(ofSize: CGSize(width: 2200, height: 2200))
                } else { photo = image }
                guard !Task.isCancelled else { return }
                guard let data = photo?.jpegData(compressionQuality: 0.86) else { parent.failed(); return }
                parent.captured(data)
            }
        }

        func cancelPreparation() { preparation?.cancel(); preparation = nil }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            cancelPreparation()
            parent.cancelled()
        }
    }
}
