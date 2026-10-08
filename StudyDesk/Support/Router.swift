import Foundation

/// Central routing for everything that needs to load a URL in the WebView:
/// deep links (studydesk:// scheme + https://studydesk.fun/* universal
/// links), notification taps (local + push), and the bridge open() call.
///
/// The SwiftUI wrapper consumes each request exactly once via
/// consumePendingLoad(), so re-renders never double-load.
@MainActor
final class Router: ObservableObject {

    static let shared = Router()

    private var pendingLoad: URL?

    private init() {}

    // MARK: - API

    /// Queue a URL for the WebView to load.
    func requestLoad(_ url: URL) {
        pendingLoad = url
    }

    /// Take the pending URL, clearing it so it loads exactly once.
    func consumePendingLoad() -> URL? {
        defer { pendingLoad = nil }
        return pendingLoad
    }

    // MARK: - Deep links

    /// Handles both `studydesk://...` URLs and `https://studydesk.fun/...`
    /// universal links.
    ///
    /// NOTE (honest): universal links only reach the app if the server hosts
    /// https://studydesk.fun/.well-known/apple-app-site-association
    /// associating applinks:studydesk.fun with team+fun.studydesk.app.
    func handleIncomingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        switch scheme {
        case "studydesk":
            // INFERRED mapping: studydesk://planner?x=1 →
            // https://studydesk.fun/planner?x=1 (host becomes first path
            // segment; explicit path appended).
            var components = URLComponents()
            components.scheme = "https"
            components.host = "studydesk.fun"
            var path = ""
            if let host = url.host, !host.isEmpty {
                path += "/\(host)"
            }
            path += url.path
            components.path = path.isEmpty ? "/" : path
            components.query = url.query
            if let mapped = components.url {
                requestLoad(mapped)
            }
        case "http", "https":
            requestLoad(url)
        default:
            break // tel:, mailto: etc. are handled by the WebView delegate.
        }
    }

    // MARK: - Notification taps

    /// Routes a tapped notification (local reminder or remote push) into the
    /// WebView. Prefers the explicit `url`, then the SPA `route` hint, then
    /// the dashboard home. `route` values like "planner" or "/planner" are
    /// INFERRED from the SPA convention; anything unparseable falls home.
    func routeNotification(userInfo: [AnyHashable: Any]) {
        if let urlString = userInfo["url"] as? String,
           !urlString.isEmpty,
           let url = URL(string: urlString) {
            requestLoad(url)
            return
        }
        if let route = userInfo["route"] as? String, !route.isEmpty {
            let path = route.hasPrefix("/") ? route : "/\(route)"
            var components = URLComponents()
            components.scheme = "https"
            components.host = "studydesk.fun"
            components.path = path
            if let url = components.url {
                requestLoad(url)
                return
            }
        }
        if let home = URL(string: "https://studydesk.fun/dashboard.php") {
            requestLoad(home)
        }
    }
}
