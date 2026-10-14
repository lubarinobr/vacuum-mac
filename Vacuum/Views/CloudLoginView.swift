import SwiftUI

/// Sign in to Xiaomi's EU server by scanning a QR code with the Xiaomi Home app. Used only to download the map.
struct CloudLoginView: View {
    @Environment(RobotController.self) private var robot
    let onDone: () -> Void

    @State private var qrImage: NSImage?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Xiaomi").font(.title2.bold())
            Text("Sign in on Xiaomi's page that just opened in your browser; the app continues by itself. Or scan this code with the Xiaomi Home app (+ → Scan).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Group {
                if let qrImage {
                    Image(nsImage: qrImage).resizable().interpolation(.none).scaledToFit()
                } else if error == nil {
                    ProgressView()
                }
            }
            .frame(width: 260, height: 260)
            if let error { Text(error).foregroundStyle(.red) }
            Button("Cancel") {
                task?.cancel()
                onDone()
            }
        }
        .padding(28)
        .frame(width: 420)
        .onAppear { task = Task { await login() } }
        .onDisappear { task?.cancel() }
    }

    private func login() async {
        let login = XiaomiQRLogin()
        do {
            let start = try await login.start()
            if let url = start.webLoginURL { NSWorkspace.shared.open(url) }
            qrImage = NSImage(data: try await login.qrImage(start))
            let session = try await login.waitForConfirmation(start, server: robot.cloud?.server ?? "de")
            robot.configure(robot: nil, cloud: session)
            await robot.loadMap()
            onDone()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
