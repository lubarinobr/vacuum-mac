import AppKit
import Foundation

/// Makes sure the vacuumd server is running, asking before anything is installed.
@MainActor
final class ServerManager {
    static let shared = ServerManager()

    private let defaultsKey = "serverMode"
    private var child: Process?
    private var terminationObserver: NSObjectProtocol?

    enum Mode: String {
        case atLogin, whileOpen
    }

    /// vacuumd inside the app, else the copy installed in the data folder.
    static func binaryURL() -> URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("vacuumd"),
                          AppStore.directory.appendingPathComponent("bin/vacuumd")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Nil when the server is up; otherwise a message to show.
    func ensureRunning(server: RobotServer = .shared) async -> String? {
        if await server.isRunning() { return nil }
        guard let binary = Self.binaryURL() else {
            return "The Vacuum background service isn't installed. Build it with “cargo build --release” in the rust folder, then reopen the app."
        }
        let mode = UserDefaults.standard.string(forKey: defaultsKey).flatMap(Mode.init) ?? askForMode()
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
        switch mode {
        case .atLogin: _ = run(binary, ["install"])
        case .whileOpen: startChild(binary)
        }
        for _ in 0..<30 {
            if await server.isRunning() { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return "The Vacuum background service didn't start. Look at ~/Library/Application Support/Vacuum/vacuumd.log."
    }

    private func askForMode() -> Mode {
        let alert = NSAlert()
        alert.messageText = "Let AI agents and this app share your robot?"
        alert.informativeText = "Vacuum talks to your robot through a small background program (vacuumd). "
            + "Install it to start at login, and AI agents (MCP) can also control the robot when this app is closed. "
            + "Or run it only while Vacuum is open."
        alert.addButton(withTitle: "Install at Login")
        alert.addButton(withTitle: "Only While Vacuum Is Open")
        return alert.runModal() == .alertFirstButtonReturn ? .atLogin : .whileOpen
    }

    private func run(_ binary: URL, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func startChild(_ binary: URL) {
        guard child?.isRunning != true else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        child = process
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.child?.terminate() }
        }
    }
}
