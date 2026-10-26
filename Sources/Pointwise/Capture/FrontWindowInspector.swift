import AppKit
import ApplicationServices

/// Reads the front app's window title, open document, and (in browsers) the
/// page URL through Accessibility, so Claude can read the whole page or
/// document instead of only the part that is visible.
enum FrontWindowInspector {
    struct FrontWindowDetails {
        var applicationName: String
        var windowTitle: String?
        var documentPath: String?
        var pageURL: String?

        var contextDescription: String {
            var description = applicationName
            if let windowTitle, !windowTitle.isEmpty { description += " — window \"\(windowTitle)\"" }
            if let pageURL { description += " — page URL: \(pageURL)" }
            if let documentPath { description += " — document: \(documentPath)" }
            return description
        }
    }

    /// Runs off the main thread because Accessibility calls are synchronous IPC.
    static func currentDetails() async -> FrontWindowDetails {
        guard let frontApplication = NSWorkspace.shared.frontmostApplication else {
            return FrontWindowDetails(applicationName: "unknown")
        }
        let applicationName = frontApplication.localizedName ?? "unknown"
        let processIdentifier = frontApplication.processIdentifier
        guard AXIsProcessTrusted() else { return FrontWindowDetails(applicationName: applicationName) }
        return await Task.detached(priority: .userInitiated) {
            inspect(processIdentifier: processIdentifier, applicationName: applicationName)
        }.value
    }

    private static func inspect(processIdentifier: pid_t, applicationName: String) -> FrontWindowDetails {
        var details = FrontWindowDetails(applicationName: applicationName)
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.3)
        guard let focusedWindow: AXUIElement = attribute(kAXFocusedWindowAttribute, of: applicationElement) else { return details }
        details.windowTitle = attribute(kAXTitleAttribute, of: focusedWindow)
        if let documentURLText: String = attribute(kAXDocumentAttribute, of: focusedWindow),
           let documentURL = URL(string: documentURLText), documentURL.isFileURL {
            details.documentPath = documentURL.path
        }
        details.pageURL = findWebAreaURL(in: focusedWindow)
        return details
    }

    /// Breadth-first search for the browser's web area, with a node budget so big apps stay fast.
    private static func findWebAreaURL(in rootElement: AXUIElement) -> String? {
        var queue: [(element: AXUIElement, depth: Int)] = [(rootElement, 0)]
        var visitedCount = 0
        while !queue.isEmpty, visitedCount < 400 {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1
            let role: String? = attribute(kAXRoleAttribute, of: element)
            if role == "AXWebArea" {
                if let url: URL = attribute("AXURL", of: element) { return url.absoluteString }
                if let urlText: String = attribute("AXURL", of: element) { return urlText }
            }
            guard depth < 12, let children: [AXUIElement] = attribute(kAXChildrenAttribute, of: element) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    private static func attribute<Value>(_ name: String, of element: AXUIElement) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if Value.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement) as? Value
        }
        return value as? Value
    }
}
