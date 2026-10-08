import Foundation
import WebKit

// MARK: - Shared bridge context

/// The single WKWebView hosting the web app, shared weakly with every bridge
/// class. Set once by WebViewController; nothing here retains the view.
@MainActor
final class BridgeHost {
    static let shared = BridgeHost()
    weak var webView: WKWebView?
    private init() {}
}

// MARK: - Bridge errors

/// Rejection reasons sent back to JS via window.__sdReject(id, message).
/// Every bridge method parses arguments defensively: wrong types reject with
/// a clear message instead of crashing.
enum BridgeError: Error {
    case unknownMethod(String)
    case typeMismatch(method: String, detail: String)
    case rejected(String)
    case permissionDenied(String)

    var message: String {
        switch self {
        case .unknownMethod(let m): return "Unknown bridge method: \(m)"
        case .typeMismatch(let m, let d): return "StudyDeskNative.\(m): bad argument — \(d)"
        case .rejected(let r): return r
        case .permissionDenied(let p): return "Permission denied or not granted: \(p)"
        }
    }
}

// MARK: - Defensive argument parsing

/// Helpers that pull typed values out of the raw [Any] args array WKWebView
/// hands us. Anything unexpected throws BridgeError.typeMismatch.
enum BridgeArgs {
    static func string(_ args: [Any], _ index: Int, method: String, name: String) throws -> String {
        guard index < args.count, let value = args[index] as? String else {
            throw BridgeError.typeMismatch(method: method, detail: "arg '\(name)' must be a string")
        }
        return value
    }

    static func optString(_ args: [Any], _ index: Int) -> String? {
        guard index < args.count else { return nil }
        if args[index] is NSNull { return nil }
        return args[index] as? String
    }

    static func bool(_ args: [Any], _ index: Int, method: String, name: String) throws -> Bool {
        guard index < args.count else {
            throw BridgeError.typeMismatch(method: method, detail: "missing arg '\(name)'")
        }
        let raw = args[index]
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        throw BridgeError.typeMismatch(method: method, detail: "arg '\(name)' must be a boolean")
    }

    static func optBool(_ args: [Any], _ index: Int) -> Bool? {
        guard index < args.count else { return nil }
        if let value = args[index] as? Bool { return value }
        return (args[index] as? NSNumber)?.boolValue
    }

    static func double(_ args: [Any], _ index: Int, method: String, name: String) throws -> Double {
        guard index < args.count else {
            throw BridgeError.typeMismatch(method: method, detail: "missing arg '\(name)'")
        }
        let raw = args[index]
        if let value = raw as? Double { return value }
        if let number = raw as? NSNumber { return number.doubleValue }
        throw BridgeError.typeMismatch(method: method, detail: "arg '\(name)' must be a number")
    }

    static func optDouble(_ args: [Any], _ index: Int) -> Double? {
        guard index < args.count else { return nil }
        if let value = args[index] as? Double { return value }
        return (args[index] as? NSNumber)?.doubleValue
    }

    static func int(_ args: [Any], _ index: Int, method: String, name: String) throws -> Int {
        return Int(try double(args, index, method: method, name: name))
    }

    static func dict(_ args: [Any], _ index: Int, method: String, name: String) throws -> [String: Any] {
        guard index < args.count, let value = args[index] as? [String: Any] else {
            throw BridgeError.typeMismatch(method: method, detail: "arg '\(name)' must be an object")
        }
        return value
    }

    static func optDict(_ args: [Any], _ index: Int) -> [String: Any]? {
        guard index < args.count else { return nil }
        return args[index] as? [String: Any]
    }
}

// MARK: - The bridge

/// WKScriptMessageHandler for the "studydesk" message channel.
///
/// The JS side (BridgeScript.bridgeBootstrap) posts
/// `{ id, method, args }`; this router dispatches to the feature bridges and
/// replies by evaluating `window.__sdResolve(id, jsonValue)` or
/// `window.__sdReject(id, message)` in the page, which settles the JS Promise.
///
/// Threading: userContentController(_:didReceive:) is NOT MainActor-isolated,
/// so parsing happens inline (pure data, no UI) and dispatch hops to the
/// main actor via Task.
@MainActor
final class StudyDeskNativeBridge: NSObject {

    static let shared = StudyDeskNativeBridge()

    private weak var webView: WKWebView?

    private override init() { super.init() }

    func attach(webView: WKWebView) {
        self.webView = webView
        BridgeHost.shared.webView = webView
    }
}

// MARK: WKScriptMessageHandler (nonisolated entry point)

extension StudyDeskNativeBridge: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "studydesk",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let method = body["method"] as? String else {
            // Malformed envelope: nothing to reply to. Log and drop.
            print("[StudyDesk] bridge: malformed message, dropping")
            return
        }
        let args = body["args"] as? [Any] ?? []
        Task { @MainActor in
            await StudyDeskNativeBridge.shared.handle(id: id, method: method, args: args)
        }
    }
}

// MARK: Dispatch

extension StudyDeskNativeBridge {

    @MainActor
    private func handle(id: String, method: String, args: [Any]) async {
        do {
            let value = try await dispatch(method: method, args: args)
            resolve(id: id, value: value)
        } catch let error as BridgeError {
            reject(id: id, message: error.message)
        } catch {
            reject(id: id, message: "StudyDeskNative.\(method) failed: \(error.localizedDescription)")
        }
    }

    /// The full contract. Every method the JS wrapper exposes is routed here.
    @MainActor
    private func dispatch(method: String, args: [Any]) async throws -> Any? {
        switch method {

        // -- availability -------------------------------------------------
        case "available", "localAvailable":
            return true

        case "isOnline":
            return OfflineMonitor.shared.isOnline

        // -- notifications ------------------------------------------------
        case "requestNotificationPermission":
            return try await ReminderStore.shared.requestPermission()

        case "notify": do {
            let title = try BridgeArgs.string(args, 0, method: method, name: "title")
            let body = try BridgeArgs.string(args, 1, method: method, name: "body")
            let opts = BridgeArgs.optDict(args, 2)
            return try await ReminderStore.shared.notify(title: title, body: body, opts: opts)
        }

        case "schedule": do {
            let title = try BridgeArgs.string(args, 0, method: method, name: "title")
            let body = try BridgeArgs.string(args, 1, method: method, name: "body")
            let atMs = try BridgeArgs.double(args, 2, method: method, name: "atMs")
            let key = try BridgeArgs.string(args, 3, method: method, name: "key")
            let route = BridgeArgs.optString(args, 4)
            let url = BridgeArgs.optString(args, 5)
            let type = BridgeArgs.optString(args, 6)
            return try await ReminderStore.shared.schedule(
                title: title, body: body, atMs: atMs, key: key, route: route, url: url, type: type
            )
        }

        case "cancel": do {
            let key = try BridgeArgs.string(args, 0, method: method, name: "key")
            ReminderStore.shared.cancel(key: key)
            return true
        }

        case "scheduleDailyComeback": do {
            let hour = try BridgeArgs.int(args, 0, method: method, name: "hour")
            let minute = try BridgeArgs.int(args, 1, method: method, name: "minute")
            return try await ReminderStore.shared.scheduleDailyComeback(hour: hour, minute: minute)
        }

        case "focusCycleNotify": do {
            let phase = try BridgeArgs.string(args, 0, method: method, name: "phase")
            let text = try BridgeArgs.string(args, 1, method: method, name: "text")
            // Spoken phase announcement (parity with Android) + an immediate
            // local notification on the focus category.
            _ = TTSBridge.shared.speak(text: text, rate: nil)
            ReminderStore.shared.postImmediateFocusNotification(phase: phase, text: text)
            return true
        }

        // -- TTS ----------------------------------------------------------
        case "ttsAvailable":
            return TTSBridge.shared.available

        case "ttsSpeak": do {
            let text = try BridgeArgs.string(args, 0, method: method, name: "text")
            let rate = BridgeArgs.optDouble(args, 1)
            return TTSBridge.shared.speak(text: text, rate: rate)
        }

        case "ttsStop":
            TTSBridge.shared.stop()
            return true

        // -- push ---------------------------------------------------------
        case "registerPush": do {
            // Returns the APNs hex token string, or null when unavailable.
            let token: String? = await PushBridge.shared.registerPush()
            return token as Any?
        }

        // -- misc ---------------------------------------------------------
        case "haptic": do {
            let style = try BridgeArgs.string(args, 0, method: method, name: "style")
            MiscBridge.shared.haptic(style: style)
            return true
        }

        case "share": do {
            let payload = try BridgeArgs.dict(args, 0, method: method, name: "payload")
            MiscBridge.shared.share(payload: payload)
            return true
        }

        case "open": do {
            let url = try BridgeArgs.string(args, 0, method: method, name: "url")
            guard MiscBridge.shared.open(urlString: url) else {
                throw BridgeError.typeMismatch(method: method, detail: "arg 'url' is not a valid URL")
            }
            return true
        }

        case "openExternal": do {
            let url = try BridgeArgs.string(args, 0, method: method, name: "url")
            guard MiscBridge.shared.openExternal(urlString: url) else {
                throw BridgeError.typeMismatch(method: method, detail: "arg 'url' is not a valid/openable URL")
            }
            return true
        }

        case "enterImmersive":
            MiscBridge.shared.setImmersive(true)
            return true

        case "exitImmersive":
            MiscBridge.shared.setImmersive(false)
            return true

        case "setKeepAwake": do {
            let on = try BridgeArgs.bool(args, 0, method: method, name: "on")
            MiscBridge.shared.setKeepAwake(on)
            return true
        }

        // -- focus timer mirror -------------------------------------------
        case "timerSync": do {
            // Exact 11-arg signature the server expects.
            let phase = try BridgeArgs.string(args, 0, method: method, name: "phase")
            let running = try BridgeArgs.bool(args, 1, method: method, name: "running")
            let sessionActive = try BridgeArgs.bool(args, 2, method: method, name: "sessionActive")
            let countUp = try BridgeArgs.bool(args, 3, method: method, name: "countUp")
            let elapsedSec = try BridgeArgs.double(args, 4, method: method, name: "elapsedSec")
            let targetSec = try BridgeArgs.double(args, 5, method: method, name: "targetSec")
            let subject = try BridgeArgs.string(args, 6, method: method, name: "subject")
            let mode = try BridgeArgs.string(args, 7, method: method, name: "mode")
            let round = try BridgeArgs.int(args, 8, method: method, name: "round")
            let maxRounds = try BridgeArgs.int(args, 9, method: method, name: "maxRounds")
            TimerMirror.shared.sync(
                phase: phase, running: running, sessionActive: sessionActive,
                countUp: countUp, elapsedSec: elapsedSec, targetSec: targetSec,
                subject: subject, mode: mode, round: round, maxRounds: maxRounds
            )
            return ["ok": true]
        }

        case "timerStop":
            TimerMirror.shared.stop()
            return ["ok": true]

        default:
            throw BridgeError.unknownMethod(method)
        }
    }

    // MARK: Replies

    /// Settles the JS promise: window.__sdResolve(id, <json>).
    private func resolve(id: String, value: Any?) {
        guard let webView = webView else { return }
        let idJSON = jsonLiteral(of: id) ?? "\"unknown\""
        let valueJSON = jsonLiteral(of: value ?? NSNull()) ?? "null"
        webView.evaluateJavaScript(
            "window.__sdResolve(\(idJSON), \(valueJSON));",
            completionHandler: nil
        )
    }

    /// Rejects the JS promise: window.__sdReject(id, "<message>").
    private func reject(id: String, message: String) {
        guard let webView = webView else { return }
        let idJSON = jsonLiteral(of: id) ?? "\"unknown\""
        let messageJSON = jsonLiteral(of: message) ?? "\"bridge error\""
        webView.evaluateJavaScript(
            "window.__sdReject(\(idJSON), \(messageJSON));",
            completionHandler: nil
        )
    }

    /// JSON-encode a value for embedding in the reply call. evaluateJavaScript
    /// (not a <script> tag) is used, so no </script> escaping concerns.
    private func jsonLiteral(of value: Any) -> String? {
        let candidate: Any = value
        if candidate is NSNull || candidate is String || candidate is NSNumber || candidate is Bool
            || candidate is [Any] || candidate is [String: Any] {
            guard let data = try? JSONSerialization.data(
                withJSONObject: candidate,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]
            ) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
