import SwiftUI

/// The whole app is one screen: the StudyDesk web app in a WKWebView.
/// Overlaid UI is minimal on purpose (mirrors the thin Android shell):
///  - an offline banner while NWPathMonitor reports no connectivity,
///  - an in-app timer banner while a focus session is mirrored AND no Live
///    Activity is active (Live Activity is the preferred surface; this banner
///    is the fallback).
struct ContentView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var offline: OfflineMonitor
    @EnvironmentObject private var timerState: TimerState

    @State private var pageReady = false

    var body: some View {
        ZStack {
            StudyDeskWebView(onFirstLoad: { pageReady = true })
                .ignoresSafeArea()

            VStack {
                if !offline.isOnline {
                    offlineBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if timerState.sessionActive && !timerState.liveActivityActive {
                    timerBanner
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: offline.isOnline)
            .animation(.easeInOut(duration: 0.25), value: timerState.sessionActive)

            if !pageReady {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.3), value: pageReady)
    }

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text("You're offline — StudyDesk will resume when you reconnect.")
                .font(.footnote)
                .lineLimit(2)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.92))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var timerBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(timerState.phaseLabel)
                    .font(.subheadline.weight(.semibold))
                Text(timerState.elapsedLabel)
                    .font(.caption)
                    .monospacedDigit()
            }
            Spacer()
            if !timerState.subject.isEmpty {
                Text(timerState.subject)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .cornerRadius(14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .shadow(radius: 6)
    }
}
