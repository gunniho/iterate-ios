import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 18.0, *)
struct IterateCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Deployment.current.bundleID + ".capture-camera") {
            ControlWidgetButton(action: IterateCameraIntent()) {
                Label("Iterate camera", systemImage: "camera")
            }
        }
        .displayName("Iterate Camera")
        .description("Take a photo to send to Iterate.")
    }
}
