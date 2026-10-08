import UIKit

/// Download finishing: present the iOS share sheet for the saved file so the
/// user can open it in Files, save to Photos, AirDrop it, etc.
///
/// (Android's DownloadManager + system notification has no direct equivalent
/// for a WKWebView shell; a share sheet over the Documents-saved file is the
/// honest iOS-native behavior.)
@MainActor
final class Downloads {

    static let shared = Downloads()

    private init() {}

    func presentShareSheet(for fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        guard let root = BridgeHost.shared.webView?.window?.rootViewController else { return }
        let presenter: UIViewController = root.presentedViewController ?? root
        if let popover = sheet.popoverPresentationController {
            // iPad: a share sheet without an anchor crashes.
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true, completion: nil)
    }
}
