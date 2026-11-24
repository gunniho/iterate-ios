import SwiftUI

/// Where this iPhone is, for a person to put into a message. Opened from the New Agent sheet.
struct DevicePlaceView: View {
    let include: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var place: DevicePlace?
    @State private var work: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Button("Find current place") {
                    message = nil
                    work = Task {
                        defer { work = nil }
                        do { place = try await DeviceLocation().currentPlace() }
                        catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }.disabled(work != nil)
                if work != nil { ProgressView() }
                if let message { Text(message).foregroundStyle(.secondary) }
                if let place {
                    Section("Current place") {
                        Text(place.label)
                        Button("Include in request") {
                            include(place.label)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Current place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onDisappear { work?.cancel() }
        }
    }
}
