import AppKit
import SwiftUI
import WebKit

/// A floating whiteboard where Pointwise shows formulas (LaTeX), diagrams
/// (Mermaid), and short notes while it explains a concept out loud. The same
/// panel hosts live simulations that Pointwise can run experiments in.
@MainActor
final class WhiteboardPanelController: NSObject, WKNavigationDelegate {
    private(set) var panel: FloatingPanel?
    private(set) var webView: WKWebView?
    private var currentTitle = ""
    private var pendingRenderContinuation: CheckedContinuation<Void, Never>?

    static let panelSize = CGSize(width: 500, height: 400)
    static let simulationPanelSize = CGSize(width: 560, height: 500)
    private static let headerHeight: CGFloat = 38

    var isVisible: Bool { panel?.isVisible ?? false }
    /// The open simulation's kind and title, or nil when the panel shows a whiteboard.
    private(set) var openSimulation: (kind: String, title: String)?

    func show(title: String, markdown: String, near anchor: CGPoint, avoiding attentionRect: CGRect? = nil, screenFrames: [CGRect]) async {
        openSimulation = nil
        let panel = preparePanel(title: title, iconName: "pencil.and.scribble", size: Self.panelSize, near: anchor, avoiding: attentionRect, screenFrames: screenFrames)
        // Stay invisible until the math and diagrams have rendered, so the
        // learner never sees an empty board.
        panel.alphaValue = 0
        await render(markdown: markdown)
        fadeIn(panel)
    }

    /// Shows a live simulation: a built-in kind from the bundled lab page, or Claude's own HTML.
    func showSimulation(kind: String, title: String, parameters: [String: Double], expression: String?, customHTML: String?, near anchor: CGPoint, avoiding attentionRect: CGRect? = nil, screenFrames: [CGRect]) async -> Bool {
        let html: String
        if kind == "custom" {
            guard let customHTML, !customHTML.isEmpty else { return false }
            html = customHTML
        } else {
            guard let labURL = Bundle.main.url(forResource: "lab", withExtension: "html", subdirectory: "Simulations"),
                  let labTemplate = try? String(contentsOf: labURL, encoding: .utf8) else { return false }
            var configuration: [String: Any] = ["kind": kind, "params": parameters]
            if let expression { configuration["expression"] = expression }
            let configurationJSON = (try? String(data: JSONSerialization.data(withJSONObject: configuration), encoding: .utf8)) ?? "{}"
            html = labTemplate.replacingOccurrences(of: "__SIM_CONFIG__", with: configurationJSON)
        }
        openSimulation = (kind, title)
        let panel = preparePanel(title: title, iconName: "flask", size: Self.simulationPanelSize, near: anchor, avoiding: attentionRect, screenFrames: screenFrames)
        panel.alphaValue = 0
        await load(html: html, baseURL: nil)
        fadeIn(panel)
        return true
    }

    /// Moves the open simulation's sliders to new values (from a [SIM:...] tag).
    func setSimulationValues(_ newValues: [String: Double]) {
        guard openSimulation != nil, let webView,
              let valuesJSON = try? String(data: JSONSerialization.data(withJSONObject: newValues), encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.pointwiseSim && window.pointwiseSim.set(\(valuesJSON))", completionHandler: nil)
    }

    /// The open simulation's current values, including any the learner dragged.
    func currentSimulationValues() async -> [String: Double] {
        guard openSimulation != nil, let webView else { return [:] }
        let result = try? await webView.evaluateJavaScript("JSON.stringify(window.pointwiseSim ? window.pointwiseSim.get() : {})")
        guard let json = result as? String, let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return decoded.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    private func preparePanel(title: String, iconName: String, size: CGSize, near anchor: CGPoint, avoiding attentionRect: CGRect?, screenFrames: [CGRect]) -> FloatingPanel {
        let panel = self.panel ?? makePanel()
        // A hide still fading out must not order the panel out after it is shown again.
        fadeTask?.cancel()
        currentTitle = title
        panel.contentView?.subviews.compactMap { $0 as? NSHostingView<WhiteboardHeader> }.first?.rootView = WhiteboardHeader(title: title, iconName: iconName, onClose: { [weak self] in self?.hide() })
        let screenFrame = screenFrames.first { $0.contains(anchor) } ?? screenFrames.first ?? .zero
        if !panel.isVisible {
            // Open on the side of the screen that covers the least of what the learner
            // is looking at (what they circled, Pointwise's marks); otherwise away from the pointer.
            let originY = min(max(anchor.y - size.height / 2, screenFrame.minY + 90), screenFrame.maxY - size.height - 60)
            let leftFrame = CGRect(x: screenFrame.minX + 50, y: originY, width: size.width, height: size.height)
            let rightFrame = CGRect(x: screenFrame.maxX - size.width - 50, y: originY, width: size.width, height: size.height)
            func coveredArea(_ frame: CGRect) -> CGFloat {
                guard let attentionRect else { return 0 }
                let overlap = frame.intersection(attentionRect.insetBy(dx: -30, dy: -30))
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            let leftCover = coveredArea(leftFrame)
            let rightCover = coveredArea(rightFrame)
            let chosenFrame = leftCover == rightCover ? (anchor.x > screenFrame.midX ? leftFrame : rightFrame) : (leftCover < rightCover ? leftFrame : rightFrame)
            panel.setFrame(chosenFrame, display: false)
            panel.orderFrontRegardless()
        } else if panel.frame.size != size {
            // Keep the top edge in place and stay on screen when switching between board and lab.
            var resizedFrame = CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
            resizedFrame.origin.x = min(max(resizedFrame.minX, screenFrame.minX + 20), screenFrame.maxX - size.width - 20)
            resizedFrame.origin.y = max(resizedFrame.minY, screenFrame.minY + 60)
            panel.setFrame(resizedFrame, display: true)
        }
        return panel
    }

    private func fadeIn(_ panel: FloatingPanel) {
        fade(panel, to: 1, duration: 0.25)
    }

    func hide() {
        openSimulation = nil
        guard let panel else { return }
        fade(panel, to: 0, duration: 0.2) { panel.orderOut(nil) }
    }

    private var fadeTask: Task<Void, Never>?

    /// Fades the panel by stepping its alpha. Window animators can stall while
    /// the main thread is busy.
    private func fade(_ panel: FloatingPanel, to targetAlpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeTask?.cancel()
        let startAlpha = panel.alphaValue
        let startedAt = Date()
        fadeTask = Task { @MainActor in
            while !Task.isCancelled {
                let progress = min(1, Date().timeIntervalSince(startedAt) / duration)
                panel.alphaValue = startAlpha + (targetAlpha - startAlpha) * CGFloat(progress)
                if progress >= 1 {
                    completion?()
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: Self.panelSize)
        let containerView = NSView(frame: CGRect(origin: .zero, size: Self.panelSize))
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = DS.CornerRadius.large
        containerView.layer?.masksToBounds = true
        containerView.layer?.backgroundColor = NSColor(red: 0.985, green: 0.98, blue: 0.965, alpha: 1).cgColor

        let header = NSHostingView(rootView: WhiteboardHeader(title: currentTitle, iconName: "pencil.and.scribble", onClose: { [weak self] in self?.hide() }))
        header.frame = CGRect(x: 0, y: Self.panelSize.height - Self.headerHeight, width: Self.panelSize.width, height: Self.headerHeight)
        header.autoresizingMask = [.width, .minYMargin]
        containerView.addSubview(header)

        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.panelSize.width, height: Self.panelSize.height - Self.headerHeight), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        containerView.addSubview(webView)

        panel.contentView = containerView
        self.panel = panel
        self.webView = webView
        return panel
    }

    private func render(markdown: String) async {
        let markdownJSON = (try? String(data: JSONSerialization.data(withJSONObject: [markdown]), encoding: .utf8)) ?? "[\"\"]"
        let html = Self.htmlTemplate.replacingOccurrences(of: "__MARKDOWN_JSON__", with: markdownJSON)
        await load(html: html, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    private func load(html: String, baseURL: URL?) async {
        guard let webView else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingRenderContinuation?.resume()
            pendingRenderContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
            // Never block the lesson on a slow CDN.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.pendingRenderContinuation?.resume()
                self?.pendingRenderContinuation = nil
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Give KaTeX and Mermaid a moment to lay out before reporting "shown".
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.pendingRenderContinuation?.resume()
            self.pendingRenderContinuation = nil
        }
    }

    private static let htmlTemplate = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
    <style>
      html, body { margin: 0; background: transparent; }
      body { font: 16px/1.5 "Noteworthy", "Chalkboard SE", -apple-system, sans-serif; color: #1d2a3a; padding: 10px 22px 22px; }
      h1, h2, h3 { font-family: "Noteworthy", "Chalkboard SE", sans-serif; color: #1e40af; margin: 6px 0; }
      h1 { font-size: 22px; } h2 { font-size: 19px; } h3 { font-size: 17px; }
      p, li { font-size: 16px; }
      code { font-family: "SF Mono", Menlo, monospace; font-size: 13.5px; background: #e9eef7; padding: 1px 5px; border-radius: 5px; }
      pre { background: #1f2937; color: #e5e7eb; padding: 12px 14px; border-radius: 10px; overflow-x: auto; }
      pre code { background: none; color: inherit; padding: 0; }
      .katex-display { margin: 10px 0; font-size: 1.15em; }
      .mermaid { display: flex; justify-content: center; margin: 8px 0; }
      strong { color: #b91c1c; }
      table { border-collapse: collapse; } td, th { border: 1px solid #c7d2e3; padding: 4px 8px; }
    </style></head>
    <body><div id="content"></div>
    <script>
      const markdown = __MARKDOWN_JSON__[0];
      const mermaidBlocks = [];
      const renderer = new marked.Renderer();
      const originalCode = renderer.code.bind(renderer);
      renderer.code = (code, language) => {
        const source = typeof code === "object" ? code.text : code;
        const lang = typeof code === "object" ? code.lang : language;
        if (lang === "mermaid") { mermaidBlocks.push(source); return '<div class="mermaid">' + source.replace(/</g, "&lt;") + '</div>'; }
        return originalCode(code, language);
      };
      // Protect LaTeX from Markdown so underscores and asterisks survive.
      const mathPieces = [];
      const protectedMarkdown = markdown.replace(/\\$\\$[\\s\\S]+?\\$\\$|\\$[^$\\n]+?\\$/g, (match) => { mathPieces.push(match); return "@@MATH" + (mathPieces.length - 1) + "@@"; });
      let html = marked.parse(protectedMarkdown, { renderer });
      html = html.replace(/@@MATH(\\d+)@@/g, (_, index) => mathPieces[Number(index)].replace(/</g, "&lt;"));
      document.getElementById("content").innerHTML = html;
      renderMathInElement(document.body, { delimiters: [ { left: "$$", right: "$$", display: true }, { left: "$", right: "$", display: false } ], throwOnError: false });
      mermaid.initialize({ startOnLoad: false, theme: "neutral", fontFamily: "Noteworthy, sans-serif" });
      mermaid.run({ querySelector: ".mermaid" });
    </script></body></html>
    """
}

struct WhiteboardHeader: View {
    let title: String
    var iconName = "pencil.and.scribble"
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(Color(hex: "#1E40AF"))
            Text(title)
                .font(.custom("Noteworthy-Bold", size: 17))
                .foregroundColor(Color(hex: "#1E40AF"))
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "#475569"))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(hex: "#E2E8F0")))
            }
            .buttonStyle(.plain)
            .pointerCursorOnHover()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "#F4F1E8"))
    }
}
