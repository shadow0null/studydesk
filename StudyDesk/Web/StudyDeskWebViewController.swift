import SwiftUI
import WebKit

// MARK: - SwiftUI wrapper

/// The single screen of the app: a WKWebView hosting https://studydesk.fun.
/// Router-driven loads (deep links, notification taps) are consumed here so
/// each URL is loaded exactly once.
struct StudyDeskWebView: UIViewControllerRepresentable {
    var onFirstLoad: () -> Void

    func makeUIViewController(context: Context) -> WebViewController {
        let controller = WebViewController()
        controller.onFirstLoad = onFirstLoad
        return controller
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) {
        // Called on every SwiftUI state change; consumePendingLoad() nils the
        // request so a re-render never reloads the same URL twice.
        // SwiftUI calls this on the main thread.
        MainActor.assumeIsolated {
            if let url = Router.shared.consumePendingLoad() {
                controller.load(url: url)
            }
        }
    }
}

// MARK: - View controller

/// Owns the WKWebView and everything attached to it:
///  - persistent website data store (PHP session cookie survives restarts),
///  - `StudyDeskIOS/1.0` user-agent suffix,
///  - the StudyDeskNative bridge (document-start injection),
///  - the timer hook (document-end, on every finished navigation + 2s retry),
///  - target=_blank handling inside the same WebView,
///  - pull-to-refresh,
///  - file downloads → Documents → share sheet.
final class WebViewController: UIViewController {

    var onFirstLoad: (() -> Void)?

    private var webView: WKWebView!
    private let refreshControl = UIRefreshControl()
    private var firstLoadFinished = false
    private var timerHookRetry: DispatchWorkItem?

    /// Owns download handling. WKDownloadDelegate is (unlike
    /// WKNavigationDelegate/WKUIDelegate) NOT @MainActor-annotated in the
    /// iOS 18 SDK, so its witnesses must be nonisolated — a separate plain
    /// NSObject subclass keeps the @MainActor view controller out of the
    /// conformance entirely. (Swift 6 otherwise reports "does not conform
    /// to protocol 'WKDownloadDelegate'" on the extension.)
    private let downloadHandler = DownloadDelegate()

    private static var homeURL: URL {
        // Static literal; preconditionFailure (not a force-unwrap) if it ever
        // fails to parse, which would be a programming error.
        guard let url = URL(string: "https://studydesk.fun/dashboard.php") else {
            preconditionFailure("homeURL is a static literal and must parse")
        }
        return url
    }

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        layoutWebView()
        setupPullToRefresh()

        // Download finish → share sheet. The callback runs in a nonisolated
        // context, so it hops to the main actor for the @MainActor Downloads
        // helper. The closure itself captures no isolated state.
        downloadHandler.onFinished = { url in
            Task { @MainActor in
                Downloads.shared.presentShareSheet(for: url)
            }
        }

        // Hand the WebView to the bridge layer (all weak references).
        // viewDidLoad always runs on the main thread; assumeIsolated keeps
        // these synchronous @MainActor singleton calls hop-free.
        MainActor.assumeIsolated {
            StudyDeskNativeBridge.shared.attach(webView: webView)
            OfflineMonitor.shared.attach(webView: webView)
            TTSBridge.shared.attach(webView: webView)
        }

        webView.load(URLRequest(url: Self.homeURL))
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()

        // Default (persistent) data store: cookies — including the PHP
        // session cookie from studydesk.fun — survive app restarts.
        // (The Android app used the default WebView cookie store the same way.)
        configuration.websiteDataStore = .default()

        // Media: allow inline playback and autoplay without a user gesture,
        // matching a normal browser so tutor videos/voice notes just work.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // getUserMedia (camera/mic) works natively in WKWebView on iOS 14.3+;
        // no extra code needed beyond the Info.plist usage descriptions.

        // Appends " StudyDeskIOS/1.0" to the default Safari user agent.
        configuration.applicationNameForUserAgent = "StudyDeskIOS/1.0"

        let contentController = configuration.userContentController
        contentController.addUserScript(WKUserScript(
            source: BridgeScript.bridgeBootstrap,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        contentController.add(StudyDeskNativeBridge.shared, name: "studydesk")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private func layoutWebView() {
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupPullToRefresh() {
        refreshControl.addTarget(self, action: #selector(didPullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
    }

    @objc private func didPullToRefresh() {
        webView.reload()
    }

    // MARK: Public API

    /// Load a URL in the WebView (deep links, notification taps, bridge open()).
    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    // MARK: Timer hook

    /// Re-inject the timer hook after every finished navigation: the
    /// dashboard is an SPA, but full navigations (and the delayed retry)
    /// cover the cases where window.Timer appears late.
    private func injectTimerHook() {
        webView.evaluateJavaScript(BridgeScript.timerHook, completionHandler: nil)
    }

    private func scheduleTimerHookRetry() {
        timerHookRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.injectTimerHook()
        }
        timerHookRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        injectTimerHook()
        scheduleTimerHookRetry()
        if !firstLoadFinished {
            firstLoadFinished = true
            onFirstLoad?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        // A failed provisional navigation (e.g. offline on first launch)
        // still dismisses the splash; the offline banner explains the state.
        if !firstLoadFinished {
            firstLoadFinished = true
            onFirstLoad?()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }

        switch scheme {
        case "http", "https":
            decisionHandler(.allow)
        case "studydesk":
            // In-page studydesk:// links route through the same Router as
            // external deep links. WebKit delegate callbacks are main-thread.
            MainActor.assumeIsolated {
                Router.shared.handleIncomingURL(url)
            }
            decisionHandler(.cancel)
        default:
            // tel:, mailto:, etc. — hand to the system, don't trap them.
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Let attachments / binary responses become downloads instead of
        // rendering as garbage in the page.
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloadHandler
    }
}

// MARK: - WKUIDelegate (target=_blank)

extension WebViewController: WKUIDelegate {

    /// Links with target=_blank (or window.open) open in the SAME WebView.
    /// The app is a single-tab shell like the Android app — there is no tab UI.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - Download handling (nonisolated delegate)

/// WKDownloadDelegate conformance, kept off the @MainActor view controller.
///
/// Why a separate class: this target builds in Swift 6 language mode, where
/// UIViewController (and therefore WebViewController and all of its
/// extensions) is @MainActor-isolated. WKNavigationDelegate and WKUIDelegate
/// are @MainActor-annotated in the iOS 18 SDK, so conforming to them in
/// extensions is fine — but WKDownloadDelegate is intentionally NOT
/// @MainActor-annotated, and a @MainActor-inherited witness cannot satisfy
/// its nonisolated requirements (the compiler reports "type does not conform
/// to protocol 'WKDownloadDelegate'"). A plain NSObject subclass is
/// nonisolated, so its witnesses match. Only the final share sheet hops to
/// the main actor, via the onFinished callback.
final class DownloadDelegate: NSObject, WKDownloadDelegate {

    /// Where each in-flight download should land, so downloadDidFinish can
    /// present the right file.
    private var destinations: [ObjectIdentifier: URL] = [:]

    /// Invoked with the saved file URL when a download finishes. Called from
    /// a nonisolated context — hop to @MainActor inside the closure before
    /// touching UI.
    var onFinished: ((URL) -> Void)?

    func webView(
        _ webView: WKWebView,
        download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Save into the app's Documents directory.
        let destination = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(suggestedFilename)
        if let destination {
            destinations[ObjectIdentifier(download)] = destination
        }
        completionHandler(destination)
    }

    func webView(_ webView: WKWebView, downloadDidFinish download: WKDownload) {
        defer { destinations.removeValue(forKey: ObjectIdentifier(download)) }
        guard let destination = destinations[ObjectIdentifier(download)] else { return }
        onFinished?(destination)
    }

    func webView(
        _ webView: WKWebView,
        download: WKDownload,
        didFailWithError error: any Error,
        resumeData: Data?
    ) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        // Honest: surface download failures where the user can see them.
        // A production polish step could toast this inside the page; for now
        // we log and stay silent rather than crash.
        print("[StudyDesk] download failed: \(error.localizedDescription)")
    }
}
