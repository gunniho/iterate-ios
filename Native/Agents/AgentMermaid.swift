import Compression
import SwiftUI
import WebKit

/// A conservative Markdown fence scanner. Non-Mermaid fences are consumed as a unit so examples
/// of Mermaid syntax inside them are not rendered. All other text stays with the existing parser.
enum AgentReplyPart: Equatable {
    case markdown(String)
    case literal(String)
    case diagram(source: String, fallback: String)

    static func parse(_ message: String) -> [Self] {
        guard message.range(of: "mermaid", options: .caseInsensitive) != nil else { return [.markdown(message)] }
        let lines = message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var parts: [Self] = []
        var cursor = 0
        var textStart = 0
        func text(_ range: Range<Int>) -> String { lines[range].joined(separator: "\n") }
        while cursor < lines.count {
            guard let open = fence(lines[cursor]) else { cursor += 1; continue }
            let start = cursor
            cursor += 1
            while cursor < lines.count {
                if let close = fence(lines[cursor]), close.marker == open.marker, close.count >= open.count,
                   close.info.isEmpty { break }
                cursor += 1
            }
            let isMermaid = open.info.split(whereSeparator: \.isWhitespace).first?.lowercased() == "mermaid"
            guard cursor < lines.count else {
                if isMermaid {
                    if start > textStart { parts.append(.markdown(text(textStart..<start))) }
                    parts.append(.literal(text(start..<lines.count)))
                    textStart = lines.count
                }
                break
            }
            if isMermaid, cursor > start + 1 {
                if start > textStart { parts.append(.markdown(text(textStart..<start))) }
                parts.append(.diagram(source: text((start + 1)..<cursor), fallback: text(start..<(cursor + 1))))
                textStart = cursor + 1
            }
            cursor += 1
        }
        guard !parts.isEmpty else { return [.markdown(message)] }
        if textStart < lines.count { parts.append(.markdown(text(textStart..<lines.count))) }
        return parts
    }

    private static func fence(_ line: Substring) -> (marker: Character, count: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "\u{60}" || marker == "~" else { return nil }
        let count = rest.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if marker == "\u{60}", info.contains(marker) { return nil }
        return (marker, count, info)
    }
}

struct AgentMermaidDiagram: View {
    let source: String
    let fallback: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: UIImage?

    var body: some View {
        Group {
            if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: rendered.size.width / 2)
                    .accessibilityHidden(true) // The native message exposes its full text, including the source.
            } else {
                Text(verbatim: fallback)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .task(id: colorScheme) {
            let result = await AgentMermaidRenderer.shared.render(source, dark: colorScheme == .dark)
            if !Task.isCancelled { rendered = result }
        }
    }
}

/// WebKit is a private, offscreen rendering process, not the conversation UI. Its document is
/// constant, has no native bridge, permits no chart scripts/network, and never navigates.
/// The only value that reaches SwiftUI is a bounded bitmap; SVG never enters the transcript.
@MainActor
final class AgentMermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = AgentMermaidRenderer()
    private static let world = WKContentWorld.world(name: "IterateMermaid")
    private static let uncompressedSize = 5_537_838
    private var engine: Task<WKWebView, Error>?
    private var loading: CheckedContinuation<Void, Error>?
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func render(_ source: String, dark: Bool) async -> UIImage? {
        guard !Task.isCancelled, source.utf8.count <= 12_000,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.range(of: #"^\s*---(?:\s|$)|%%\s*\{"#, options: .regularExpression) == nil else { return nil }
        let key = ((dark ? "dark:" : "light:") + source) as NSString
        if let image = images.object(forKey: key) { return image }
        do {
            let web = try await getEngine()
            guard !Task.isCancelled else { return nil }
            let result = try await web.callAsyncJavaScript(
                "return await globalThis.renderIterateDiagram(source, dark);",
                arguments: ["source": source, "dark": dark], in: nil, contentWorld: Self.world
            )
            guard !Task.isCancelled, let png = result as? String, png.utf8.count < 12_000_000,
                  let data = Data(base64Encoded: png), let image = UIImage(data: data),
                  let cgImage = image.cgImage else { return nil }
            images.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
            return image
        } catch {
            return nil
        }
    }

    private func getEngine() async throws -> WKWebView {
        if let engine { return try await engine.value }
        let task = Task { try await prepare() }
        engine = task
        do { return try await task.value }
        catch { engine = nil; throw error }
    }

    private func prepare() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        guard let rule = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "IterateMermaidOffline", encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) else { throw RenderError.contentRule }
        configuration.userContentController.add(rule)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            web.loadHTMLString(Self.page, baseURL: nil)
        }
        let library = try Self.library()
        _ = try await web.evaluateJavaScript(library, in: nil, contentWorld: Self.world)
        _ = try await web.evaluateJavaScript(Self.bootstrap, in: nil, contentWorld: Self.world)
        return web
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        loading != nil && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loaded(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded(.failure(RenderError.webProcess))
        engine = nil
    }

    private func loaded(_ result: Result<Void, Error>) {
        let continuation = loading
        loading = nil
        continuation?.resume(with: result)
    }

    private enum RenderError: Error { case invalidBundle, contentRule, webProcess }
    private static func library() throws -> String {
        guard let url = Bundle.main.url(forResource: "mermaid-12.3.0", withExtension: "b64", subdirectory: "MermaidVendor") else {
            throw RenderError.invalidBundle
        }
        let encoded = try Data(contentsOf: url)
        guard let archive = Data(base64Encoded: encoded) else { throw RenderError.invalidBundle }
        var output = Data(count: uncompressedSize)
        let size = output.withUnsafeMutableBytes { target in
            archive.withUnsafeBytes { source -> Int in
                guard let dst = target.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, target.count, src, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size == uncompressedSize, let script = String(data: output, encoding: .utf8) else { throw RenderError.invalidBundle }
        return script
    }

    private static let page = """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <body></body>
        """

    private static let bootstrap = #"""
        (() => {
          let queue = Promise.resolve();
          globalThis.renderIterateDiagram = (source, dark) => {
            const job = queue.then(async () => {
              try {
                mermaid.initialize({ startOnLoad: false, securityLevel: "strict", htmlLabels: false,
                  suppressErrorRendering: true, maxTextSize: 12000, maxEdges: 250,
                  theme: dark ? "dark" : "default", fontFamily: "system-ui, sans-serif" });
                // Do not bind interactive Mermaid handlers. Decode SVG only in inert image mode.
                const {svg} = await mermaid.render("iterate-diagram", source);
                if (svg.length > 1_000_000) return null;
                const root = new DOMParser().parseFromString(svg, "image/svg+xml").documentElement;
                if (root.localName !== "svg" || root.namespaceURI !== "http://www.w3.org/2000/svg") return null;
                const {width, height} = root.viewBox.baseVal;
                if (!(width > 0 && height > 0 && width <= 12000 && height <= 12000)) return null;
                root.setAttribute("width", String(width));
                root.setAttribute("height", String(height));
                root.removeAttribute("style");
                const image = new Image();
                image.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(new XMLSerializer().serializeToString(root));
                await image.decode();
                const scale = Math.min(2, 4096 / Math.max(width, height), Math.sqrt(8_000_000 / (width * height)));
                const canvas = document.createElement("canvas");
                canvas.width = Math.ceil(width * scale);
                canvas.height = Math.ceil(height * scale);
                canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
                return canvas.toDataURL("image/png").split(",")[1] ?? null;
              } catch { return null; }
              finally { document.body.replaceChildren(); }
            });
            queue = job;
            return job;
          };
        })();
        """#
}
