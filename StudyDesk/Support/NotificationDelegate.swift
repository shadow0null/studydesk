import UserNotifications

/// UNUserNotificationCenterDelegate for the app.
///
///  - willPresent: show banner + sound + badge for notifications arriving
///    while the app is in the foreground (mirrors Android heads-up behavior
///    for focus/timer notifications).
///  - didReceiveResponse: any tap or action (Open Plan / Open Task / Reply /
///    View / Start Focus) routes the WebView to the payload's url/route via
///    Router. This covers local reminders AND remote pushes (admin messages,
///    announcements, chat) — the payload keys url/route/type are INFERRED
///    from the Android FCM data schema.
final class NotificationDelegate: NSObject {

    static let shared = NotificationDelegate()

    private override init() { super.init() }

    /// Call once at app launch.
    static func register() {
        UNUserNotificationCenter.current().delegate = shared
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Every action funnels to the same routing: open the payload's URL.
        // (A future enhancement could deep-link "REPLY" straight to a chat
        // composer; today it opens the chat route, which is honest.)
        let userInfo = response.notification.request.content.userInfo
        await Router.shared.routeNotification(userInfo: userInfo)
    }
}
