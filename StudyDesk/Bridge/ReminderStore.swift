import Foundation
import UserNotifications

/// Local-notification scheduling for the bridge.
///
/// Mirrors the Android app's `studydesk_native/scheduled_jobs` pattern: every
/// scheduled job is persisted as JSON in UserDefaults under `sd_scheduled_jobs`
/// so the app can list/prune/cancel them. (On iOS, UNUserNotificationCenter
/// pending requests survive reboots, so no BOOT_COMPLETED-style restore is
/// needed — noted here so nobody "fixes" it later.)
///
/// Server key conventions (INFERRED from the Android v13.3.0 behavior the
/// task describes; the native side is generic and works with any key, but
/// these prefixes get parity-specific rules):
///  - `todo-lead-<id>`  — todo deadline reminders. 48-alarm cap, 14-day horizon.
///  - `planner-lead-<id>` / `planner-start-<id>` — planner block reminders:
///    one fires lead-minutes before the block, one at block start.
///  - `daily-comeback`  — the daily comeback nudge (repeating).
@MainActor
final class ReminderStore {

    static let shared = ReminderStore()

    // MARK: - Persisted job model

    struct Job: Codable {
        var key: String
        var title: String
        var body: String
        /// Epoch milliseconds of the fire time (-1 for the repeating comeback).
        var atMs: Double
        var route: String?
        var url: String?
        var type: String?
        var repeatsDaily: Bool
    }

    private let storeKey = "sd_scheduled_jobs"
    private let center = UNUserNotificationCenter.current()

    // Parity rules (INFERRED from Android behavior; see class doc).
    private let todoLeadPrefix = "todo-lead-"
    private let dailyComebackKey = "daily-comeback"
    private let maxTodoReminders = 48
    private let todoHorizon: TimeInterval = 14 * 24 * 3_600 // 14 days

    private init() {}

    // MARK: - Categories

    /// Category per notification type, chosen by substring on `type` so the
    /// server doesn't need to know iOS category identifiers.
    func categoryIdentifier(for type: String?) -> String {
        let t = (type ?? "").lowercased()
        if t.contains("planner") { return "PLANNER" }
        if t.contains("todo") || t.contains("task") { return "TASK" }
        if t.contains("chat") || t.contains("admin") { return "CHAT" }
        if t.contains("announce") || t.contains("critical") { return "ANNOUNCE" }
        if t.contains("focus") || t.contains("comeback") { return "FOCUS" }
        return "DEFAULT"
    }

    /// Register categories + actions. Called once at app launch.
    func registerCategories() {
        func action(_ id: String, _ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: [.foreground])
        }
        let categories: [UNNotificationCategory] = [
            UNNotificationCategory(identifier: "PLANNER", actions: [action("OPEN_PLAN", "Open Plan")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "TASK", actions: [action("OPEN_TASK", "Open Task")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "CHAT", actions: [action("REPLY", "Reply")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ANNOUNCE", actions: [action("VIEW", "View")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "FOCUS", actions: [action("START_FOCUS", "Start Focus")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "DEFAULT", actions: [], intentIdentifiers: []),
        ]
        center.setNotificationCategories(Set(categories))
    }

    // MARK: - Permission

    /// requestNotificationPermission bridge method.
    func requestPermission() async throws -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            throw BridgeError.rejected("Could not request notification permission: \(error.localizedDescription)")
        }
    }

    private func requirePermission() async throws {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .denied:
            throw BridgeError.permissionDenied("notifications are disabled for StudyDesk — enable them in Settings")
        case .notDetermined:
            let granted = (try? await requestPermission()) ?? false
            if !granted { throw BridgeError.permissionDenied("notification permission not granted") }
        @unknown default:
            throw BridgeError.permissionDenied("notifications")
        }
    }

    // MARK: - Scheduling

    /// schedule(title, body, atMs, key, route, url, type).
    /// `atMs` is epoch milliseconds (INFERRED from the Android contract).
    /// Returns the key. Rejects (never crashes) on permission denial,
    /// past fire times, todo horizon/cap violations.
    @discardableResult
    func schedule(
        title: String,
        body: String,
        atMs: Double,
        key: String,
        route: String?,
        url: String?,
        type: String?
    ) async throws -> String {
        try await requirePermission()

        let nowMs = Date().timeIntervalSince1970 * 1_000

        // Parity: todo deadline reminders — 14-day horizon, 48-alarm cap.
        if key.hasPrefix(todoLeadPrefix) {
            if atMs - nowMs > todoHorizon * 1_000 {
                throw BridgeError.rejected("todo reminder is beyond the 14-day horizon")
            }
            let existing = loadJobs().filter { $0.key.hasPrefix(todoLeadPrefix) && $0.key != key }
            if existing.count >= maxTodoReminders {
                throw BridgeError.rejected("todo reminder cap reached (\(maxTodoReminders) pending)")
            }
        }

        guard atMs > nowMs else {
            throw BridgeError.rejected("atMs is in the past; refusing to schedule '\(key)'")
        }
        guard !key.isEmpty else {
            throw BridgeError.rejected("schedule requires a non-empty key")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier(for: type)
        content.userInfo = [
            "key": key,
            "route": route ?? "",
            "url": url ?? "",
            "type": type ?? "",
        ]

        let fireDate = Date(timeIntervalSince1970: atMs / 1_000)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            throw BridgeError.rejected("could not schedule '\(key)': \(error.localizedDescription)")
        }

        saveJob(Job(key: key, title: title, body: body, atMs: atMs,
                    route: route, url: url, type: type, repeatsDaily: false))
        return key
    }

    /// cancel(key): removes the pending request, any delivered copy, and the
    /// stored job. Cancelling an unknown key is a no-op (returns true).
    func cancel(key: String) {
        center.removePendingNotificationRequests(withIdentifiers: [key])
        center.removeDeliveredNotifications(withIdentifiers: [key])
        var jobs = loadJobs()
        jobs.removeAll { $0.key == key }
        persist(jobs)
    }

    /// scheduleDailyComeback(hour, minute): the daily comeback nudge.
    /// A single repeating calendar trigger (key `daily-comeback`); iOS
    /// re-fires it daily on its own, so no manual re-chaining is needed.
    @discardableResult
    func scheduleDailyComeback(hour: Int, minute: Int) async throws -> String {
        try await requirePermission()
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw BridgeError.rejected("scheduleDailyComeback: hour must be 0–23 and minute 0–59")
        }

        let content = UNMutableNotificationContent()
        content.title = "Come back to StudyDesk"
        content.body = "Your study plan is waiting — a few focused minutes go a long way."
        content.sound = .default
        content.categoryIdentifier = "FOCUS"
        content.userInfo = [
            "key": dailyComebackKey,
            "route": "",
            "url": "https://studydesk.fun/dashboard.php",
            "type": "comeback",
        ]

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: dailyComebackKey, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            throw BridgeError.rejected("could not schedule daily comeback: \(error.localizedDescription)")
        }

        // atMs -1 marks "repeating, no single fire time".
        saveJob(Job(key: dailyComebackKey, title: content.title, body: content.body,
                    atMs: -1, route: nil, url: "https://studydesk.fun/dashboard.php",
                    type: "comeback", repeatsDaily: true))
        return dailyComebackKey
    }

    /// notify(title, body, opts): immediate local notification.
    /// `opts` may carry route/url/type (INFERRED; all optional).
    @discardableResult
    func notify(title: String, body: String, opts: [String: Any]?) async throws -> String {
        try await requirePermission()
        let id = "notify-\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let type = opts?["type"] as? String
        content.categoryIdentifier = categoryIdentifier(for: type)
        content.userInfo = [
            "key": id,
            "route": (opts?["route"] as? String) ?? "",
            "url": (opts?["url"] as? String) ?? "",
            "type": type ?? "",
        ]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            throw BridgeError.rejected("could not post notification: \(error.localizedDescription)")
        }
        return id
    }

    /// Immediate notification used by focusCycleNotify (spoken announcement's
    /// visual twin, on the focus category so it carries "Start Focus").
    func postImmediateFocusNotification(phase: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Focus — \(phase)"
        content.body = text
        content.sound = .default
        content.categoryIdentifier = "FOCUS"
        content.userInfo = [
            "key": "focus-cycle-\(UUID().uuidString)",
            "route": "",
            "url": "https://studydesk.fun/dashboard.php",
            "type": "focus",
        ]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: content.userInfo["key"] as? String ?? UUID().uuidString,
                                            content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - Persistence

    /// Drop stored jobs whose fire time has passed (repeating comeback kept).
    /// Called at launch; pending UN requests for expired jobs are removed too.
    func pruneExpiredJobs() {
        let nowMs = Date().timeIntervalSince1970 * 1_000
        let jobs = loadJobs()
        let expired = jobs.filter { !$0.repeatsDaily && $0.atMs < nowMs }
        guard !expired.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: expired.map(\.key))
        persist(jobs.filter { !expired.map(\.key).contains($0.key) })
    }

    func loadJobs() -> [Job] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let jobs = try? JSONDecoder().decode([Job].self, from: data) else {
            return []
        }
        return jobs
    }

    private func saveJob(_ job: Job) {
        var jobs = loadJobs()
        jobs.removeAll { $0.key == job.key }
        jobs.append(job)
        persist(jobs)
    }

    private func persist(_ jobs: [Job]) {
        if let data = try? JSONEncoder().encode(jobs) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
