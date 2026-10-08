import Network
import WebKit

/// Connectivity monitor (NWPathMonitor) backing the bridge isOnline() call,
/// the offline banner in ContentView, and window online/offline events
/// dispatched into the page so dashboard.php can react like it does in a
/// mobile browser.
@MainActor
final class OfflineMonitor: ObservableObject {

    static let shared = OfflineMonitor()

    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private weak var webView: WKWebView?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.update(online: online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "fun.studydesk.app.offline-monitor"))
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    private func update(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        // Mirror the web platform's online/offline events into the page.
        let eventName = online ? "online" : "offline"
        webView?.evaluateJavaScript(
            "window.dispatchEvent(new Event('\(eventName)'));",
            completionHandler: nil
        )
    }
}
