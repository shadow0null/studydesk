import AVFoundation
import WebKit

/// Text-to-speech bridge (tutor read-aloud, spoken focus-phase announcements).
///
/// Parity notes:
///  - ttsSpeak(text, rate) returns a speech id immediately (matching the
///    Android bridge's promise-of-id shape; INFERRED).
///  - When an utterance finishes, the page gets
///    `window.dispatchEvent(new CustomEvent('studydesk:tts-end'))` so the web
///    app can chain read-aloud segments (INFERRED event name from the Android
///    contract's tts-end callback).
///  - `rate` is clamped to AVSpeechUtterance's valid range.
///  - ttsAvailable always returns true: AVSpeechSynthesizer is a system
///    service with no permission gate.
@MainActor
final class TTSBridge: NSObject {

    static let shared = TTSBridge()

    private let synthesizer = AVSpeechSynthesizer()
    private weak var webView: WKWebView?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    var available: Bool { true }

    /// Speaks `text`; returns an id for the utterance.
    @discardableResult
    func speak(text: String, rate: Double?) -> String {
        let id = UUID().uuidString
        let utterance = AVSpeechUtterance(string: text)
        if let rate = rate {
            let clamped = min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                              Double(AVSpeechUtteranceMaximumSpeechRate))
            utterance.rate = Float(clamped)
        }
        // System default voice/locale — matches the Android behavior of not
        // pinning a specific engine voice unless the server asks (it can't
        // through this contract).
        synthesizer.speak(utterance)
        return id
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSBridge: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        // Notify the page on the main actor; evaluateJavaScript must run there.
        Task { @MainActor in
            TTSBridge.shared.webView?.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('studydesk:tts-end'));",
                completionHandler: nil
            )
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // A cancelled utterance also ends the "speaking" state for the page.
        Task { @MainActor in
            TTSBridge.shared.webView?.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('studydesk:tts-end'));",
                completionHandler: nil
            )
        }
    }
}
