import SwiftUI
import UIKit

/// App entry point. SwiftUI lifecycle (iOS 16.1+), no SceneDelegate needed.
///
/// Responsibilities at launch:
///  1. Register UNUserNotificationCenter delegate (foreground presentation + taps).
///  2. Register for APNs push (remote notifications) — token delivery is handled
///     in AppDelegate and forwarded to PushBridge.
///  3. Route deep links: `studydesk://` URL scheme and https://studydesk.fun/*
///     universal links both end up in Router.shared.
@main
struct StudyDeskApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var router = Router.shared
    @StateObject private var offline = OfflineMonitor.shared
    @StateObject private var timerState = TimerState.shared
    @StateObject private var immersive = ImmersiveState.shared

    init() {
        // Notification plumbing. Permission itself is only *requested* when
        // the web app calls requestNotificationPermission() or a schedule is
        // attempted — iOS best practice is to ask in context, and the Android
        // bridge defers it the same way.
        NotificationDelegate.register()
        // App init runs on the main thread; assumeIsolated keeps these
        // synchronous @MainActor calls hop-free.
        MainActor.assumeIsolated {
            ReminderStore.shared.registerCategories()
            ReminderStore.shared.pruneExpiredJobs()
        }
        // No boot-restore of scheduled jobs needed: UNUserNotificationCenter
        // pending requests survive device reboots on iOS. (Android needed a
        // BOOT_COMPLETED receiver for AlarmManager; we do not.)
    }

    var body: some Scene {
        WindowGroup {
            ImmersiveHostingView {
                ContentView()
                    .environmentObject(router)
                    .environmentObject(offline)
                    .environmentObject(timerState)
                    .environmentObject(immersive)
            }
            .onOpenURL { url in
                Router.shared.handleIncomingURL(url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                // Universal link https://studydesk.fun/*.
                // NOTE (honest): the server must also host
                // https://studydesk.fun/.well-known/apple-app-site-association
                // or iOS will open these in Safari instead of the app.
                if let url = activity.webpageURL {
                    Router.shared.handleIncomingURL(url)
                }
            }
        }
    }
}

/// UIApplicationDelegate shim for APNs token callbacks.
/// SwiftUI's @main App has no AppDelegate, so this adaptor carries the two
/// callbacks UIKit needs. Everything else lives in the bridge classes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register for remote (APNs) notifications at launch so the device
        // token is available early. APNs delivery itself is one-way: the token
        // is stored by PushBridge; the web app pulls it via registerPush().
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // UIKit delegate callbacks are main-thread; hop to the @MainActor
        // PushBridge asynchronously.
        Task { @MainActor in
            PushBridge.shared.didReceiveDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushBridge.shared.didFailToRegister(error: error)
        }
    }
}

/// UIHostingController subclass so the web app can hide the status bar and
/// home indicator via the enterImmersive/exitImmersive bridge calls.
final class ImmersiveHostingView<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool {
        // UIKit queries these on the main thread.
        MainActor.assumeIsolated { ImmersiveState.shared.isImmersive }
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        MainActor.assumeIsolated { ImmersiveState.shared.isImmersive }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Re-query the two overrides whenever the immersive flag changes.
        MainActor.assumeIsolated {
            ImmersiveState.shared.onImmersiveChanged = { [weak self] in
                self?.setNeedsStatusBarAppearanceUpdate()
                self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            }
        }
    }
}

/// Shared immersive-mode flag, toggled by the bridge.
@MainActor
final class ImmersiveState: ObservableObject {
    static let shared = ImmersiveState()

    @Published var isImmersive: Bool = false {
        didSet { onImmersiveChanged?() }
    }

    /// Called on the main actor by the hosting controller setup.
    var onImmersiveChanged: (() -> Void)?
}
