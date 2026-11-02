import AppKit
import Combine
import WebKit

/// Independent browser lifetime and state. Constructing the singleton does not create or load a tab.
@MainActor
public final class BrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    public static let shared = BrowserController()
    @Published public private(set) var tabs: [BrowserTab] = []
    @Published public private(set) var selectedTabID: UUID?
    @Published public private(set) var addressText = ""
    /// UI-level address submission errors; page load errors stay on the tab.
    @Published public var chromeError: String?

    private var webViews: [UUID: WKWebView] = [:]
    private var observations: [UUID: [NSKeyValueObservation]] = [:]
    private let websiteDataStore = WKWebsiteDataStore.default()
    private var agentWindow: NSWindow?

    public override init() { super.init() }
    public var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    public var selectedWebView: WKWebView? { selectedTabID.flatMap { webViews[$0] } }

    public func openPageIfNeeded() {
        if tabs.isEmpty { _ = createTab() }
    }

    @discardableResult
    public func createTab() -> UUID {
        createTab(urlString: nil, activate: true)
    }

    /// Creates a tab and optionally loads a URL directly. activate=false is a background tab;
    /// background tabs can load but need selection before click/type/screenshot.
    @discardableResult
    public func createTab(urlString: String?, activate: Bool = true,
                          agentControlled: Bool = false) -> UUID {
        let id = UUID()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        webViews[id] = view
        var tab = BrowserTab(id: id)
        tab.isAgentControlled = agentControlled
        tab.isBackground = agentControlled && !activate
        tabs.append(tab)
        if agentControlled && !activate { attachToAgentWindow(view) }
        observations[id] = [
            view.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh(id) } },
            view.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh(id) } },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh(id) } },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh(id) } },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh(id) } },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh(id) } }
        ]
        if activate || (selectedTabID == nil && !agentControlled) { selectTab(id) }
        // Explicitly blank unless a direct URL was supplied.
        if let urlString, let url = try? validatedURL(urlString) {
            view.load(URLRequest(url: url))
        } else {
            view.load(URLRequest(url: URL(string: "about:blank")!))
        }
        return id
    }

    @discardableResult
    public func createAgentTab(urlString: String? = nil, activate: Bool = false) -> UUID {
        createTab(urlString: urlString, activate: activate, agentControlled: true)
    }

    public func selectTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectedTabID = id
        tabs[index].isBackground = false
        addressText = tabs[index].url == "about:blank" ? "" : tabs[index].url
    }

    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let view = webViews.removeValue(forKey: id)
        view?.stopLoading()
        view?.navigationDelegate = nil
        view?.uiDelegate = nil
        observations.removeValue(forKey: id)
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = nil
            if !tabs.isEmpty { selectTab(tabs[min(index, tabs.count - 1)].id) }
            else { addressText = "" }
        }
    }

    /// Human address bar accepts hosts and search text; JSON navigate requires an absolute URL.
    public func submitAddress(_ text: String) async -> BrowserActionResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: String
        if value == "about:blank" || value.contains("://") { url = value }
        else if !value.contains(where: \.isWhitespace), value.contains(".") || value.hasPrefix("localhost") {
            url = "https://" + value
        } else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: value)]
            url = components.url!.absoluteString
        }
        return await execute(action: .navigate(url: url))
    }

    /// Agent -> Needle JSON -> this entry point. Navigation success means accepted, not load completion.
    public func execute(_ json: String, tabID: UUID? = nil) async -> String {
        do {
            let action = try JSONDecoder().decode(BrowserAction.self, from: Data(json.utf8))
            return encode(await execute(action: action, tabID: tabID))
        } catch {
            return encode(BrowserActionResult(ok: false, action: "invalid", tabID: selectedTabID,
                message: "Invalid browser action JSON.", error: BrowserFailure("invalid_action_json", error.localizedDescription),
                detailsJSON: nil, snapshot: nil))
        }
    }

    public func execute(json: String, tabID: UUID? = nil) async -> String { await execute(json, tabID: tabID) }

    public func execute(action: BrowserAction, tabID: UUID? = nil) async -> BrowserActionResult {
        let targetID = tabID ?? selectedTabID
        do {
            guard let id = targetID, let view = webViews[id] else {
                throw BrowserFailure("browser_not_open", "Open BrowserPage and select a tab before executing browser actions.")
            }
            var details: String?
            let message: String
            switch action {
            case .navigate(let value):
                let url = try validatedURL(value)
                clearError(id)
                guard view.load(URLRequest(url: url)) != nil else { throw BrowserFailure("navigation_rejected", "WKWebView rejected the navigation request.") }
                message = "Navigation requested. Inspect loading and load errors in a subsequent snapshot."
            case .back:
                guard view.canGoBack else { throw BrowserFailure("no_back_history", "This tab has no previous history entry.") }
                clearError(id); view.goBack(); message = "Back navigation requested."
            case .forward:
                guard view.canGoForward else { throw BrowserFailure("no_forward_history", "This tab has no forward history entry.") }
                clearError(id); view.goForward(); message = "Forward navigation requested."
            case .reload:
                clearError(id); view.reload(); message = "Reload requested."
            case .click, .scroll, .type, .key:
                guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                    throw BrowserFailure("viewport_not_visible", "The selected WKWebView must be attached to a window with a nonzero viewport for simulated input.")
                }
                if case .click(let x, let y) = action, !x.isFinite || !y.isFinite { throw BrowserFailure("invalid_coordinates", "Click coordinates must be finite CSS pixels.") }
                if case .scroll(let x, let y) = action, !x.isFinite || !y.isFinite { throw BrowserFailure("invalid_delta", "Scroll deltas must be finite CSS pixels.") }
                let script = try BrowserDOMScript.command(action)
                guard let response = try await view.evaluateJavaScript(script) as? String,
                      let data = response.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = object["ok"] as? Bool else { throw BrowserFailure("invalid_dom_response", "DOM command did not return a valid result.") }
                guard ok else {
                    let failure = object["error"] as? [String: String]
                    throw BrowserFailure(failure?["code"] ?? "dom_error", failure?["message"] ?? "DOM command failed.")
                }
                details = response
                message = "Simulated DOM command executed; events are untrusted. See details for actual effect and cancellation."
            }
            refresh(id)
            return BrowserActionResult(ok: true, action: action.name, tabID: id, message: message,
                error: nil, detailsJSON: details, snapshot: try? await snapshot(tabID: id))
        } catch {
            let failure = error as? BrowserFailure ?? BrowserFailure("webkit_error", error.localizedDescription)
            return BrowserActionResult(ok: false, action: action.name, tabID: targetID, message: failure.message,
                error: failure, detailsJSON: nil, snapshot: try? await snapshot(tabID: targetID))
        }
    }

    public func snapshot(tabID: UUID? = nil) async throws -> BrowserSnapshot {
        let targetID = tabID ?? selectedTabID
        guard let id = targetID, let view = webViews[id], let tab = tabs.first(where: { $0.id == id }) else {
            return BrowserSnapshot(selectedTabID: nil, url: nil, title: nil, loading: false, tabs: tabs, viewport: nil, inputEvents: "synthetic_dom_untrusted")
        }
        let raw = try await view.evaluateJavaScript("({width:innerWidth,height:innerHeight,scrollX:scrollX,scrollY:scrollY,devicePixelRatio:devicePixelRatio})")
        guard let metrics = raw as? [String: Any], let width = metrics["width"] as? Double, let height = metrics["height"] as? Double else {
            throw BrowserFailure("viewport_unavailable", "WKWebView did not return viewport dimensions.")
        }
        // Pin the captured tab across the JavaScript suspension; never label another tab's metrics.
        guard webViews[id] === view else { throw BrowserFailure("tab_changed", "Browser tab changed while taking the snapshot. Retry.") }
        refresh(id)
        let bounds = view.bounds
        let screen = view.window.map { $0.convertToScreen(view.convert(bounds, to: nil)) }
        let viewport = BrowserViewport(width: width, height: height, scrollX: metrics["scrollX"] as? Double ?? 0,
            scrollY: metrics["scrollY"] as? Double ?? 0, devicePixelRatio: metrics["devicePixelRatio"] as? Double ?? 1,
            coordinateSpace: "wkwebview_viewport_top_left_css_pixels", nativeBounds: rect(bounds), screenFrame: screen.map(rect), attachedToWindow: view.window != nil)
        return BrowserSnapshot(selectedTabID: id, url: tab.url, title: tab.title,
            loading: view.isLoading, tabs: tabs, viewport: viewport, inputEvents: "synthetic_dom_untrusted")
    }

    public func snapshotJSON(tabID: UUID? = nil) async -> String {
        do { return encode(try await snapshot(tabID: tabID)) }
        catch { return encode(error as? BrowserFailure ?? BrowserFailure("snapshot_failed", error.localizedDescription)) }
    }

    /// Captures only page content, to this app's Application Support/BrowserCaptures directory.
    public func captureScreenshot(tabID: UUID? = nil) async throws -> URL {
        let targetID = tabID ?? selectedTabID
        guard let id = targetID, let view = webViews[id] else { throw BrowserFailure("browser_not_open", "No selected browser tab.") }
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { throw BrowserFailure("viewport_not_visible", "Open BrowserPage before capturing its visible viewport.") }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw BrowserFailure("png_encoding_failed", "WebKit snapshot could not be encoded as PNG.") }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appDirectory = Bundle.main.bundleIdentifier ?? "Project-Auto"
        let directory = root.appendingPathComponent(appDirectory, isDirectory: true).appendingPathComponent("BrowserCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).png")
        try png.write(to: destination, options: .atomic)
        return destination
    }

    private func ensureAgentWindow() -> NSWindow {
        if let agentWindow { return agentWindow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        // Keep a real window attached for WebKit input/snapshot, but offscreen and behind everything.
        window.orderBack(nil)
        agentWindow = window
        return window
    }

    private func attachToAgentWindow(_ view: WKWebView) {
        let window = ensureAgentWindow()
        view.removeFromSuperview()
        view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView?.addSubview(view)
    }

    /// Called when SwiftUI starts/stops displaying a WKWebView.
    public func prepareForDisplay(_ view: WKWebView) {
        view.removeFromSuperview()
    }

    public func rehomeIfAgent(_ view: WKWebView) {
        guard let id = webViews.first(where: { $0.value === view })?.key,
              let tab = tabs.first(where: { $0.id == id }), tab.isAgentControlled,
              selectedTabID != id else { return }
        attachToAgentWindow(view)
    }

    private func validatedURL(_ value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "about:blank" { return URL(string: value)! }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw BrowserFailure("unsupported_url", "Use an absolute HTTPS or HTTP URL, or about:blank. Custom schemes, file URLs, and JavaScript URLs cannot leave this browser.") }
        guard url.user == nil, url.password == nil else { throw BrowserFailure("url_credentials_unsupported", "Credentials embedded in browser URLs are not supported.") }
        return url
    }

    private func refresh(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), let view = webViews[id] else { return }
        tabs[index].url = view.url?.absoluteString ?? "about:blank"
        tabs[index].title = view.title.flatMap { $0.isEmpty ? nil : $0 } ?? (tabs[index].url == "about:blank" ? "New Tab" : view.url?.host ?? "Untitled")
        tabs[index].loading = view.isLoading
        tabs[index].estimatedProgress = view.estimatedProgress
        tabs[index].canGoBack = view.canGoBack
        tabs[index].canGoForward = view.canGoForward
        if id == selectedTabID { addressText = tabs[index].url == "about:blank" ? "" : tabs[index].url }
    }

    private func clearError(_ id: UUID) { if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index].error = nil } }
    private func record(_ failure: BrowserFailure, in view: WKWebView) {
        guard let id = webViews.first(where: { $0.value === view })?.key, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].error = failure
        refresh(id)
    }
    private func rect(_ value: NSRect) -> BrowserRect { BrowserRect(x: value.minX, y: value.minY, width: value.width, height: value.height) }
    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) }
        catch { return "{\"ok\":false,\"error\":{\"code\":\"encoding_failed\",\"message\":\"Failed to encode browser response.\"}}" }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let id = webViews.first(where: { $0.value === webView })?.key { clearError(id); refresh(id) }
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = webViews.first(where: { $0.value === webView })?.key { refresh(id) }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ view: WKWebView, _ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        record(BrowserFailure("navigation_failed", "\(nsError.domain) (\(nsError.code)): \(error.localizedDescription)"), in: view)
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { record(BrowserFailure("web_content_terminated", "WebKit page process terminated. Reload this tab to recover."), in: webView) }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Sandboxed embedded documents are common in normal HTTPS pages. Permit their
        // local document schemes only in subframes; no URL is handed to another app.
        let embeddedDocument = navigationAction.targetFrame?.isMainFrame == false &&
            (["data", "blob"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:srcdoc")
        if !embeddedDocument {
            do { _ = try validatedURL(url.absoluteString) }
            catch { record(error as? BrowserFailure ?? BrowserFailure("unsupported_url", error.localizedDescription), in: webView); decisionHandler(.cancel); return }
        }
        if navigationAction.shouldPerformDownload {
            record(BrowserFailure("download_unsupported", "Embedded browser downloads are not implemented."), in: webView)
            decisionHandler(.cancel)
        } else if navigationAction.targetFrame == nil {
            // Keep target=_blank links inside this browser; never use NSWorkspace/openURL.
            let id = createTab()
            webViews[id]?.load(navigationAction.request)
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.canShowMIMEType else { record(BrowserFailure("unsupported_content", "This response cannot be displayed by WKWebView; downloads are not implemented."), in: webView); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank is handled in navigation policy; do not create an external window.
        nil
    }
}
