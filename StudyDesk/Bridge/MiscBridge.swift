import UIKit

/// Miscellaneous bridge methods: haptic, share, open, openExternal,
/// enterImmersive/exitImmersive, setKeepAwake, (isOnline lives in
/// OfflineMonitor and is routed through the bridge).
@MainActor
final class MiscBridge {

    static let shared = MiscBridge()

    /// Explicit keep-awake override from setKeepAwake(). OR'd with the
    /// focus-session keep-awake in TimerMirror.refreshKeepAwake().
    var keepAwakeOverride: Bool = false

    private init() {}

    // MARK: - Haptics

    /// haptic(style): "light" | "medium" | "heavy" | "selection" |
    /// "success" | "warning" | "error". Unknown styles fall back to medium.
    func haptic(style: String) {
        switch style.lowercased() {
        case "light":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "heavy":
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "selection":
            UISelectionFeedbackGenerator().selectionChanged()
        case "success":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error":
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "medium", _:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    // MARK: - Share

    /// share({title?, text?, url?}) → UIActivityViewController.
    func share(payload: [String: Any]) {
        var items: [Any] = []
        // Title has no dedicated slot on UIActivityViewController; prepend it
        // to the text so it isn't lost.
        var textParts: [String] = []
        if let title = payload["title"] as? String, !title.isEmpty {
            textParts.append(title)
        }
        if let text = payload["text"] as? String, !text.isEmpty {
            textParts.append(text)
        }
        if !textParts.isEmpty {
            items.append(textParts.joined(separator: "\n"))
        }
        if let urlString = payload["url"] as? String,
           let url = URL(string: urlString) {
            items.append(url)
        }
        guard !items.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        present(sheet)
    }

    // MARK: - Navigation

    /// open(url): load in the same WebView (single-tab shell, like Android).
    @discardableResult
    func open(urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        Router.shared.requestLoad(url)
        return true
    }

    /// openExternal(url): hand to the system (Safari / target app).
    /// Uses UIApplication.open — simpler and more honest than embedding
    /// SFSafariViewController, and matches "open in browser" semantics.
    @discardableResult
    func openExternal(urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
    }

    // MARK: - Immersive / keep-awake

    /// Toggles the flag that ImmersiveHostingView reads for
    /// prefersStatusBarHidden / prefersHomeIndicatorAutoHidden.
    func setImmersive(_ immersive: Bool) {
        ImmersiveState.shared.isImmersive = immersive
    }

    /// setKeepAwake(on) → UIApplication.isIdleTimerDisabled, OR'd with the
    /// automatic keep-awake while a focus session is mirrored.
    func setKeepAwake(_ on: Bool) {
        keepAwakeOverride = on
        TimerMirror.shared.refreshKeepAwake()
    }

    // MARK: - Presentation helper

    private func present(_ viewController: UIViewController) {
        guard let root = BridgeHost.shared.webView?.window?.rootViewController else {
            return
        }
        let presenter: UIViewController = root.presentedViewController ?? root
        if let popover = viewController.popoverPresentationController {
            // iPad: a share sheet without an anchor crashes.
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(viewController, animated: true, completion: nil)
    }
}
