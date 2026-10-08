import Foundation
import UIKit
import UserNotifications

/// APNs push bridge.
///
/// registerPush() → asks for notification permission on first call (via the
/// same path as requestNotificationPermission), registers with APNs, and
/// resolves with the hex device-token string — or null when unavailable
/// (simulator, denied permission, no network to APNs).
///
/// HONEST SERVER NOTE: the StudyDesk server's push sender targets Android
/// (FCM). Reaching this iOS app requires a server-side change: fan out to
/// Apple's APNs using the token returned here, sending a payload like:
///
///     { "aps": { "alert": { "title": "...", "body": "..." },
///                "sound": "default" },
///       "type": "chat" | "admin" | "announcement" | ...,
///       "route": "planner",
///       "url": "https://studydesk.fun/dashboard.php" }
///
/// The `type`/`route`/`url` keys are INFERRED from the Android FCM data
/// schema, not verified against the live server. On tap, the app routes the
/// WebView to `url` (falling back to `route`, then home) via Router.
@MainActor
final class PushBridge {

    static let shared = PushBridge()

    private let tokenKey = "sd_apns_token"

    private init() {}

    // MARK: - Token

    var storedToken: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    /// registerPush bridge method.
    func registerPush() async -> String? {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        case .denied:
            return nil
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }
        // The actual token arrives asynchronously via AppDelegate →
        // didReceiveDeviceToken. If we already have one stored, return it
        // now; otherwise return whatever is stored (possibly null) — the
        // web app can call registerPush() again later.
        UIApplication.shared.registerForRemoteNotifications()
        return storedToken
    }

    /// Called by AppDelegate on successful APNs registration.
    func didReceiveDeviceToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: tokenKey)
    }

    /// Called by AppDelegate when APNs registration fails. We keep any
    /// previously stored token; registerPush() will return null until a
    /// fresh token arrives.
    func didFailToRegister(error: Error) {
        print("[StudyDesk] APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Push routing

    /// Pull url/route/type out of a remote-push payload defensively.
    /// Used by NotificationDelegate when a push is tapped.
    func routing(from userInfo: [AnyHashable: Any]) -> (url: String?, route: String?, type: String?) {
        let url = userInfo["url"] as? String
        let route = userInfo["route"] as? String
        let type = userInfo["type"] as? String
        return (url, route, type)
    }
}
