#if canImport(ScreenCaptureKit) && !targetEnvironment(simulator)
import CoreImage
import ImageIO
@preconcurrency import ScreenCaptureKit
import UIKit

@available(iOS 27.0, *)
@MainActor
final class ScreenKitFeed: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    static var isAvailable: Bool { SCContentSharingPicker.shared.isAvailable }
    private let picker = SCContentSharingPicker.shared
    private let frameAvailability: @MainActor @Sendable (Bool) -> Void
    private let started: @MainActor () -> Void
    private let ended: @MainActor (String?) -> Void
    private let frameQueue = DispatchQueue(label: Deployment.current.bundleID + ".screen-frames", qos: .utility)
    private var stream: SCStream?
    private var frameOutput: CurrentScreenFrame?
    private var observing = false
    private var selection = UUID()
    private var protectedDataObserver: NSObjectProtocol?

    init(frameAvailability: @escaping @MainActor @Sendable (Bool) -> Void,
         started: @escaping @MainActor () -> Void,
         ended: @escaping @MainActor (String?) -> Void) {
        self.frameAvailability = frameAvailability
        self.started = started
        self.ended = ended
    }

    func present() {
        observing = true
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.ended(nil) } }
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false
        config.showsCameraControl = false
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func stop() {
        selection = UUID()
        if let observer = protectedDataObserver { NotificationCenter.default.removeObserver(observer) }
        protectedDataObserver = nil
        if observing { picker.remove(self); picker.isActive = false; observing = false }
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
        discardFrames()
    }

    func currentImage() async -> Data? {
        guard observing, let source = frameOutput else { return nil }
        let chosen = selection
        let bytes = await withCheckedContinuation { continuation in
            frameQueue.async { continuation.resume(returning: source.jpeg()) }
        }
        return observing && chosen == selection ? bytes : nil
    }

    private func discardFrames() {
        if let source = frameOutput { frameQueue.async { source.invalidate() } }
        frameOutput = nil
        frameAvailability(false)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.ended(nil) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.start(filter: filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.ended(message) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let issue = error as NSError
        let endedNormally = issue.domain == SCStreamErrorDomain &&
            (issue.code == SCStreamError.Code.userStopped.rawValue || issue.code == SCStreamError.Code.systemStoppedStream.rawValue)
        let message = endedNormally ? nil : issue.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            ended(message)
        }
    }

    private func start(filter: SCContentFilter) async {
        guard observing else { return }
        let chosen = UUID()
        selection = chosen
        discardFrames()
        do {
            if let previous = stream {
                stream = nil
                try await previous.stopCapture()
            }
            guard observing, selection == chosen else { return }
            let capture = SCStream(filter: filter, configuration: SCStreamConfiguration(), delegate: self)
            stream = capture
            let output = CurrentScreenFrame { [weak self] available in
                guard let self, observing, selection == chosen else { return }
                frameAvailability(available)
            }
            frameOutput = output
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
            try await capture.startCapture()
            guard observing, stream === capture else { try? await capture.stopCapture(); return }
            started()
        } catch {
            if observing, selection == chosen { ended(error.localizedDescription) }
        }
    }
}

/// The stream callbacks, reads, and invalidation all run on frameQueue. Retain only the newest visible frame.
@available(iOS 27.0, *)
private final class CurrentScreenFrame: NSObject, SCStreamOutput, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let availability: @MainActor @Sendable (Bool) -> Void
    private var latest: CMSampleBuffer?
    private var orientation: CGImagePropertyOrientation = .up
    private var invalidated = false

    init(availability: @escaping @MainActor @Sendable (Bool) -> Void) { self.availability = availability }

    func invalidate() {
        invalidated = true
        latest = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard !invalidated, outputType == .screen, sampleBuffer.isValid else { return }
        let wasAvailable = latest != nil
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]])?.first
        if let raw = info?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) {
            switch status {
            case .idle: return
            case .blank, .suspended, .stopped:
                latest = nil
                if wasAvailable { Task { @MainActor [availability] in availability(false) } }
                return
            case .complete, .started: break
            @unknown default: return
            }
        }
        guard sampleBuffer.imageBuffer != nil else { return }
        latest = sampleBuffer
        let value = (info?[.videoOrientation] as? NSNumber)?.uint32Value
        orientation = value.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        if !wasAvailable { Task { @MainActor [availability] in availability(true) } }
    }

    func jpeg() -> Data? {
        guard !invalidated, let pixels = latest?.imageBuffer, let colorSpace else { return nil }
        let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        for dimension in [1600.0, 1080.0, 720.0] {
            let scale = min(1, dimension / max(image.extent.width, image.extent.height))
            let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let bytes = context.jpegRepresentation(of: resized, colorSpace: colorSpace, options: [quality: 0.78]),
               bytes.count <= IterateAttachment.maximumBytes { return bytes }
        }
        return nil
    }
}
#endif
