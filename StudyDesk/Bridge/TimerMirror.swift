import ActivityKit
import Foundation
import UIKit

// MARK: - Shared timer state

/// Observable mirror of the web app's focus timer, fed by timerSync().
/// Drives the in-app timer banner (ContentView) and the Live Activity.
@MainActor
final class TimerState: ObservableObject {

    static let shared = TimerState()

    @Published var phase: String = ""
    @Published var running: Bool = false
    @Published var sessionActive: Bool = false
    @Published var countUp: Bool = false
    @Published var elapsedSec: Double = 0
    @Published var targetSec: Double = 0
    @Published var subject: String = ""
    @Published var mode: String = ""
    @Published var round: Int = 0
    @Published var maxRounds: Int = 0

    /// True while a Live Activity is actually showing. The in-app banner is
    /// the fallback when this is false.
    @Published var liveActivityActive: Bool = false

    private init() {}

    var phaseLabel: String {
        phase.isEmpty ? "Focus session" : phase
    }

    var elapsedLabel: String {
        let total = Int(countUp ? elapsedSec : max(targetSec - elapsedSec, 0))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Live Activity attributes

/// Live Activity for the mirrored focus session.
/// Attributes (static for the session): subject, phase.
/// Content (updated live): running, elapsedSec, targetSec, countUp.
///
/// Honest note: iOS has no Android-style ongoing foreground-service
/// notification. A Live Activity on the Lock Screen / Dynamic Island is the
/// closest equivalent, and it is the recommended surface here.
struct StudyDeskTimerAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var running: Bool
        var elapsedSec: Double
        var targetSec: Double
        var countUp: Bool
    }

    var subject: String
    var phase: String
}

// MARK: - Timer mirror

/// Receives timerSync() from the page's hooked window.Timer and mirrors it
/// into TimerState + a Live Activity.
///
///  - While `sessionActive` is true: start (or update) the Live Activity.
///  - On timerStop() or `sessionActive == false`: end the Live Activity.
///  - While a session is active the screen is kept awake (parity with the
///    Android app's keep-awake during focus), OR'd with the explicit
///    setKeepAwake() bridge override.
///  - If Live Activities are unavailable (user disabled, or request fails),
///    only the in-app state updates — the ContentView banner covers it.
@MainActor
final class TimerMirror {

    static let shared = TimerMirror()

    private var activity: Activity<StudyDeskTimerAttributes>?

    private init() {}

    // MARK: Bridge entry points

    /// timerSync(phase, running, sessionActive, countUp, elapsedSec,
    /// targetSec, subject, mode, round, maxRounds)
    func sync(
        phase: String,
        running: Bool,
        sessionActive: Bool,
        countUp: Bool,
        elapsedSec: Double,
        targetSec: Double,
        subject: String,
        mode: String,
        round: Int,
        maxRounds: Int
    ) {
        let state = TimerState.shared
        state.phase = phase
        state.running = running
        state.sessionActive = sessionActive
        state.countUp = countUp
        state.elapsedSec = elapsedSec
        state.targetSec = targetSec
        state.subject = subject
        state.mode = mode
        state.round = round
        state.maxRounds = maxRounds

        refreshKeepAwake()

        if sessionActive {
            startOrUpdateLiveActivity()
        } else {
            endLiveActivity()
        }
    }

    /// timerStop()
    func stop() {
        let state = TimerState.shared
        state.sessionActive = false
        state.running = false
        endLiveActivity()
        refreshKeepAwake()
    }

    // MARK: Keep-awake

    /// Called by sync/stop and by MiscBridge.setKeepAwake().
    func refreshKeepAwake() {
        // Keep the screen on during an active focus session (parity), or when
        // the web app explicitly asked via setKeepAwake(true).
        UIApplication.shared.isIdleTimerDisabled =
            TimerState.shared.sessionActive || MiscBridge.shared.keepAwakeOverride
    }

    // MARK: Live Activity

    private func startOrUpdateLiveActivity() {
        if #available(iOS 16.1, *) {
            startOrUpdateLiveActivityImpl()
        } else {
            // Unreachable with the 16.1 deployment target; kept so the intent
            // is explicit if the target is ever lowered.
            TimerState.shared.liveActivityActive = false
        }
    }

    @available(iOS 16.1, *)
    private func startOrUpdateLiveActivityImpl() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            TimerState.shared.liveActivityActive = false
            return
        }

        let state = TimerState.shared
        let attributes = StudyDeskTimerAttributes(subject: state.subject, phase: state.phase)
        let contentState = StudyDeskTimerAttributes.ContentState(
            running: state.running,
            elapsedSec: state.elapsedSec,
            targetSec: state.targetSec,
            countUp: state.countUp
        )
        let content = ActivityContent(state: contentState, staleDate: nil)

        if let activity = activity {
            Task { await activity.update(content) }
            TimerState.shared.liveActivityActive = true
        } else {
            do {
                activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                TimerState.shared.liveActivityActive = true
            } catch {
                // Honest: Live Activity couldn't start (e.g. disabled in
                // Settings > Face ID & Passcode, or system limit). The in-app
                // banner remains the visible surface.
                TimerState.shared.liveActivityActive = false
            }
        }
    }

    private func endLiveActivity() {
        if #available(iOS 16.1, *) {
            endLiveActivityImpl()
        }
        TimerState.shared.liveActivityActive = false
    }

    @available(iOS 16.1, *)
    private func endLiveActivityImpl() {
        guard let activity = activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
