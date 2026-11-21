import SafariServices
import SwiftUI

struct ConnectionScreen: View {
    let phase: ConnectionPhase
    let hasSavedSession: Bool
    let connect: () -> Void
    let cancel: () -> Void
    let disconnect: () -> Void
    let voice: LiveVoice

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 52
    @State private var signInPage: SignInPage?

    private var paper: Color {
        colorScheme == .dark ? Color(red: 0.105, green: 0.111, blue: 0.102)
                             : Color(red: 0.965, green: 0.960, blue: 0.935)
    }
    private var ink: Color {
        colorScheme == .dark ? Color(red: 0.952, green: 0.947, blue: 0.91)
                             : Color(red: 0.133, green: 0.141, blue: 0.125)
    }
    private var secondaryInk: Color {
        colorScheme == .dark ? Color(red: 0.73, green: 0.74, blue: 0.69)
                             : Color(red: 0.37, green: 0.38, blue: 0.35)
    }
    private var statusColor: Color {
        switch phase {
        case .connected: colorScheme == .dark ? .mint : Color(red: 0.19, green: 0.40, blue: 0.27)
        case .preparing, .approval, .connecting, .disconnecting: .orange
        case .failed: colorScheme == .dark ? .orange : Color(red: 0.61, green: 0.27, blue: 0.17)
        case .disconnected: ink.opacity(0.48)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Iterate mind").font(.subheadline.weight(.semibold))
                        Spacer(minLength: 16)
                        HStack(spacing: 7) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(status).font(.footnote.monospaced())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Connection status")
                        .accessibilityValue(status)
                    }
                    .padding(.bottom, 17)
                    Divider()
                    Spacer(minLength: 28)
                    VStack(spacing: 12) {
                        MindMark(ink: ink, statusColor: statusColor)
                            .frame(width: verticalSize == .compact ? 84 : 154,
                                   height: verticalSize == .compact ? 84 : 154)
                            .padding(.bottom, 10)
                            .accessibilityHidden(true)
                        Text(Deployment.current.apexHost)
                            .font(.system(size: titleSize, weight: .medium, design: .serif))
                            .tracking(-2)
                            .accessibilityAddTraits(.isHeader)
                        if case .approval(let code, _) = phase {
                            Text(code).font(.title3.monospaced().weight(.semibold))
                                .tracking(1.4)
                                .accessibilityLabel("Approval code, \(code)")
                        }
                        Text(detail)
                            .lineLimit(voice.phase == .live ? 4 : nil)
                            .font(.subheadline)
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 315)
                    }
                    .multilineTextAlignment(.center)
                    Spacer(minLength: 34)
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "lock").accessibilityHidden(true)
                        Text(Deployment.current.controlHost)
                    }
                    .font(.footnote.monospaced())
                    .foregroundStyle(secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    actions
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(ink)
        .background(paper.ignoresSafeArea())
        .sheet(item: $signInPage) { page in
            IterateBrowser(url: page.url).ignoresSafeArea()
        }
        .onChange(of: phase) { _, next in
            if case .approval = next { return }
            signInPage = nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .disconnected:
            action("Connect", symbol: "arrow.right", perform: connect)
        case .preparing:
            action("Cancel", symbol: "xmark", perform: cancel)
        case .approval(_, let url):
            action("Open sign-in", symbol: "arrow.up.right") { signInPage = SignInPage(url: url) }
            secondary("Cancel", perform: cancel)
        case .connecting, .disconnecting:
            ProgressView().frame(maxWidth: .infinity, minHeight: 54)
                .accessibilityLabel(status)
        case .connected:
            if voice.phase.canHangUp {
                action("End call", symbol: "phone.down.fill", perform: voice.hangUp)
            } else if voice.phase == .ending || voice.phase == .preparing {
                ProgressView().frame(maxWidth: .infinity, minHeight: 54)
                    .accessibilityLabel(voice.phase == .ending ? "Ending call" : "Preparing voice")
                secondary("Disconnect", perform: disconnect)
            } else if voice.phase == .microphoneDenied {
                action("Open Settings", symbol: "mic.slash") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                secondary("Disconnect", perform: disconnect)
            } else {
                action("Talk live", symbol: "waveform", perform: voice.start)
                secondary("Disconnect", perform: disconnect)
            }
        case .failed:
            action("Try again", symbol: "arrow.clockwise", perform: connect)
            if hasSavedSession { secondary("Disconnect", perform: disconnect) }
        }
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: symbol).font(.body.weight(.medium)).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(minHeight: 54)
            .foregroundStyle(paper)
            .background(ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 3)
    }

    private var status: String {
        switch phase {
        case .disconnected, .failed: "Disconnected"
        case .preparing: "Requesting code"
        case .approval: "Awaiting approval"
        case .connecting: "Connecting"
        case .connected:
            switch voice.phase {
            case .dialing: "Calling GPT"
            case .live: "Live with GPT"
            case .ending: "Ending call"
            default: "Connected"
            }
        case .disconnecting: "Disconnecting"
        }
    }

    private var detail: String {
        switch phase {
        case .disconnected: "Connect this device to your Iterate mind."
        case .preparing: "Requesting a sign-in code from Iterate."
        case .approval: "Match this code on Iterate’s sign-in page."
        case .connecting: "Verifying your mind’s identity."
        case .connected(let email):
            switch voice.phase {
            case .preparing: "Preparing live voice."
            case .permission: "Waiting for microphone access."
            case .microphoneDenied: "Allow Iterate to use the microphone in Settings to talk live."
            case .dialing: "Opening your live conversation."
            case .live: voice.caption ?? "GPT is listening."
            case .ending: "Ending your live conversation."
            case .failed(let message): message
            case .ready: email.map { "Signed in as \($0)" } ?? "Your secure connection is active."
            }
        case .disconnecting: "Ending this device’s sign-in."
        case .failed(let message): message
        }
    }
}

private struct MindMark: View {
    let ink: Color
    let statusColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 3
                context.translateBy(x: center.x, y: center.y)
                for tick in 0..<60 {
                    let major = tick.isMultiple(of: 5)
                    var stroke = Path()
                    stroke.move(to: CGPoint(x: 0, y: -radius))
                    stroke.addLine(to: CGPoint(x: 0, y: -radius + (major ? 7 : 3)))
                    context.stroke(stroke, with: .color(major ? ink.opacity(0.35) : ink.opacity(0.16)),
                                   lineWidth: major ? 1.3 : 0.8)
                    context.rotate(by: .degrees(6))
                }
            }
            Group {
                if colorScheme == .dark {
                    Image("MindMark").resizable().colorInvert().blendMode(.screen)
                } else {
                    Image("MindMark").resizable().blendMode(.multiply)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(12)
            Circle().fill(statusColor).frame(width: 8, height: 8)
        }
    }
}

private struct SignInPage: Identifiable {
    let url: URL
    var id: URL { url }
}

struct IterateBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

#Preview("Disconnected") {
    ConnectionScreen(phase: .disconnected, hasSavedSession: false, connect: {}, cancel: {}, disconnect: {}, voice: LiveVoice())
}

#Preview("Approval") {
    ConnectionScreen(phase: .approval(code: "BCDF-GHJK", url: Deployment.current.verificationPage),
                     hasSavedSession: false, connect: {}, cancel: {}, disconnect: {}, voice: LiveVoice())
}
