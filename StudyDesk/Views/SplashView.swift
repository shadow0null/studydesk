import SwiftUI

/// Simple branded splash shown until the first page finishes loading.
/// The web app itself (dashboard.php) is the real UI; this is just a
/// launch cover so the user never stares at a blank white WebView.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.07) // brand blue-black #0A0D12
                .ignoresSafeArea()
            VStack(spacing: 16) {
                // Placeholder mark until the real AppIcon artwork is added.
                // NOTE: the AppIcon.appiconset Contents.json in this project
                // references AppIcon.png, which must be supplied (1024px).
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 72))
                    .foregroundColor(Color(red: 0.94, green: 0.65, blue: 0.0)) // brand amber #F0A500
                Text("StudyDesk")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                ProgressView()
                    .tint(.white)
            }
        }
    }
}
