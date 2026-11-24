import AVFoundation
import CoreTransferable
import LockedCameraCapture
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum IterateCaptureMode { case library, camera, lockedPhoto }

struct IterateCaptureView: View {
    let initialMode: IterateCaptureMode
    let lockedPhotoID: UUID?
    private let menuAction: (() -> Void)?
    private let include: ((String) -> Void)?
    private let shareScreen: (() -> Void)?
    @State private var showingMenu = false
    @State private var choosingPlace = false
    @State private var chosen: MenuChoice?
    @State private var menuHeight: CGFloat = 520
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var edit: CaptureDraft?
    @State private var storedID: UUID?
    @State private var pendingCamera: CaptureDraft?
    @State private var library: [IterateCaptureInbox.Summary] = []
    @State private var choosingFile = false
    @State private var camera = false
    @State private var busy = false
    @State private var issue: String?
    @State private var launched = false
    @State private var reviewedLockedPhoto = false
    @ScaledMetric(relativeTo: .body) private var plusSymbol: CGFloat = 19

    private enum MenuChoice { case photo, file, camera, screen, place }

    /// With `menuAction` this is the composer's plus button and its sheet of actions. `include` adds the
    /// current place, whose words go to the composer, and `shareScreen` screen sharing, which needs a call.
    init(initialMode: IterateCaptureMode = .library, lockedPhotoID: UUID? = nil, menuAction: (() -> Void)? = nil,
         include: ((String) -> Void)? = nil, shareScreen: (() -> Void)? = nil) {
        self.menuAction = menuAction
        self.include = include
        self.shareScreen = shareScreen
        self.initialMode = initialMode
        self.lockedPhotoID = lockedPhotoID
    }

    var body: some View {
        Group {
            if menuAction != nil {
                Button { showingMenu.toggle() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: plusSymbol, weight: .medium))
                        .foregroundStyle(.secondary)
                        .tapTarget()
                }
                .buttonStyle(PressFeedback())
                // What was chosen opens once this sheet has gone: two sheets cannot change places at once,
                // and the field lets the keyboard go before a call's sheet comes up.
                .sheet(isPresented: $showingMenu, onDismiss: {
                    guard let choice = chosen else { return }
                    chosen = nil
                    perform(choice)
                }) { menu }
                .sheet(isPresented: $choosingPlace) { DevicePlaceView { include?($0) } }
                .accessibilityLabel("Capture actions")
                .accessibilityIdentifier("iterate.chat.capture")
                .alert("Capture", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                    Button("OK") { issue = nil }
                } message: { Text(issue ?? "") }
            } else {
                captureLibrary
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .disabled(busy)
        .task {
            guard menuAction == nil else { return }
            if !launched {
                launched = true
                if initialMode == .camera { await openCamera() }
                await reload()
                reviewLockedPhoto(from: [])
            }
            if #available(iOS 18, *) {
                for await update in LockedCameraCaptureManager.shared.sessionContentUpdates {
                    guard !Task.isCancelled else { return }
                    switch update {
                    case .initial(let urls): await importLockedPhotos(urls)
                    case .added(let url): await importLockedPhotos([url])
                    case .removed: await reload(); reviewLockedPhoto(from: [])
                    @unknown default: break
                    }
                }
            }
        }
        .task(id: photo) {
            guard let photo else { return }
            busy = true
            issue = nil
            defer { busy = false }
            do {
                guard let item = try await photo.loadTransferable(type: ChosenPhoto.self) else { throw CaptureIssue.image }
                try Task.checkCancellation()
                storedID = nil
                edit = CaptureDraft(attachment: item.attachment)
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
            self.photo = nil
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importFile(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
            }
        }
        .fullScreenCover(isPresented: $camera, onDismiss: {
            if let captured = pendingCamera { storedID = nil; edit = captured; pendingCamera = nil }
        }) {
            IteratePhotoPicker(captured: { bytes in
                Task {
                    do {
                        let file = try await Task.detached {
                            try CapturedFile.fromImageData(bytes, name: "Camera photo")
                        }.value
                        pendingCamera = CaptureDraft(attachment: file)
                    } catch { issue = error.localizedDescription }
                    camera = false
                }
            }, cancelled: { camera = false }, failed: {
                issue = CaptureIssue.image.localizedDescription
                camera = false
            }).ignoresSafeArea()
        }
        .sheet(item: $edit, onDismiss: { if menuAction == nil { Task { await reload() } } }) { draft in
            NavigationStack {
                CaptureReview(draft, savedInInbox: storedID == draft.id) { edit = nil }
            }
        }
    }

    /// Every action at once, in a sheet as tall as its rows. It scrolls only where the screen is too short.
    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                captureActions
                if shareScreen != nil, IterateScreenShare.shared.available {
                    Button { choose(.screen) } label: { Label("Share screen", systemImage: "rectangle.on.rectangle") }
                }
                if include != nil {
                    Button { choose(.place) } label: { Label("Current place", systemImage: "location") }
                }
            }
            .labelStyle(CaptureMenuLabel())
            .buttonStyle(CaptureMenuRow())
            .padding(.horizontal, 10)
            .padding(.top, 26)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(menuHeight)])
        .presentationDragIndicator(.visible)
    }

    private func choose(_ choice: MenuChoice) {
        menuAction?()
        if showingMenu {
            chosen = choice
            showingMenu = false
        } else { perform(choice) }
    }

    private func perform(_ choice: MenuChoice) {
        switch choice {
        case .photo: choosingPhoto = true
        case .file: choosingFile = true
        case .camera: Task { await openCamera() }
        case .screen: shareScreen?()
        case .place: choosingPlace = true
        }
    }

    @ViewBuilder private var captureActions: some View {
        Button { choose(.photo) } label: { Label("Choose a photo", systemImage: "photo") }
        Button { choose(.file) } label: { Label("Choose a file", systemImage: "doc") }
        Button { choose(.camera) } label: { Label("Take a photo", systemImage: "camera") }
    }

    private var captureLibrary: some View {
        List {
            Section { captureActions }
            if busy { ProgressView("Preparing the capture…") }
            if let issue { Text(issue).foregroundStyle(.red) }
            if !library.isEmpty {
                Section("Saved on this iPhone") {
                    ForEach(library) { draft in
                        Button {
                            do { edit = try IterateCaptureInbox.draft(draft.id); storedID = draft.id }
                            catch { issue = error.localizedDescription }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(draft.title).lineLimit(2)
                                Text(draft.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                do { try IterateCaptureInbox.remove(draft.id); library.removeAll { $0.id == draft.id } }
                                catch { issue = error.localizedDescription }
                            }
                        }
                    }
                }
            }
        }
    }

    private func reload() async {
        do {
            library = try await Task.detached(priority: .utility) { try IterateCaptureInbox.list() }.value
        } catch { issue = error.localizedDescription }
    }

    @available(iOS 18, *)
    private func importLockedPhotos(_ urls: [URL]) async {
        do {
            let imported = try await LockedCaptureImport.shared.importPhotos(from: urls)
            await reload()
            reviewLockedPhoto(from: imported)
        } catch { issue = error.localizedDescription }
    }

    private func reviewLockedPhoto(from imported: [UUID]) {
        guard initialMode == .lockedPhoto, !reviewedLockedPhoto, edit == nil,
              let id = lockedPhotoID ?? imported.first, library.contains(where: { $0.id == id }) else { return }
        do {
            edit = try IterateCaptureInbox.draft(id)
            storedID = id
            reviewedLockedPhoto = true
        } catch { issue = error.localizedDescription }
    }

    private func openCamera() async {
        issue = nil
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            issue = "This device has no available camera."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            issue = "Allow camera access in Settings to take a photo with Iterate."
            return
        }
        camera = true
    }

    private func importFile(_ url: URL) async {
        busy = true
        issue = nil
        defer { busy = false }
        do {
            let file = try await Task.detached(priority: .utility) {
                try CapturedFile.readSecurityScoped(url)
            }.value
            storedID = nil
            edit = CaptureDraft(attachment: file)
        } catch { issue = error.localizedDescription }
    }
}

/// Symbols differ in width. One column for them keeps the titles in line.
private struct CaptureMenuLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon.frame(width: 28)
            configuration.title
        }
    }
}

private struct CaptureMenuRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.secondary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ChosenPhoto: Transferable {
    let attachment: CapturedFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            ChosenPhoto(attachment: try CapturedFile.read(received.file, suggestedName: "Shared photo", type: .image))
        }
    }
}
