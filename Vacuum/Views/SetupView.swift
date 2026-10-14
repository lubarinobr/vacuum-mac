import SwiftUI

/// First launch (and Robot → Connection → Change…): sign in with Xiaomi by QR code, pick the robot,
/// and the app fills in its IP, token and ID. Manual entry stays available as a fallback.
struct SetupView: View {
    @Environment(RobotController.self) private var robot
    var onDone: (() -> Void)?

    private enum Step: Equatable {
        case start, signingIn, loadingDevices, choose, failed(String)
    }

    /// nil = "Not sure": check every region after signing in.
    @State private var region: XiaomiRegion? = .de
    @State private var step: Step = .start
    @State private var qrImage: NSImage?
    @State private var webLoginURL: URL?
    @State private var showQR = false
    @State private var session: CloudSession?
    @State private var devices: [CloudDevice] = []
    @State private var selected: CloudDevice?
    @State private var loginTask: Task<Void, Never>?

    @State private var showManual = false
    @State private var ip = ""
    @State private var token = ""
    @State private var did = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch step {
            case .start: startStep
            case .signingIn: signingInStep
            case .loadingDevices: ProgressView("Looking for your robot…").frame(maxWidth: .infinity, minHeight: 160)
            case .choose: chooseStep
            case .failed(let message): failedStep(message)
            }
            manualEntry
            footer
        }
        .padding(28)
        .frame(width: 480)
        .animation(.smooth(duration: 0.3), value: step)
        .onDisappear { loginTask?.cancel() }
        .onAppear {
            if let config = robot.config {
                ip = config.ip
                token = config.token
                did = config.did
            }
            if let server = robot.cloud?.server { region = XiaomiRegion(rawValue: server) }
        }
    }

    // MARK: - Steps

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Connect your robot", systemImage: "dot.radiowaves.left.and.right")
                .font(.title2.bold())
            Text("Works with the \(RobotModel.supportedName). Sign in once with your Xiaomi account (no Xiaomi app needed) to find it; after that, the app controls it directly over your home network.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Xiaomi account region", selection: $region) {
                ForEach(XiaomiRegion.allCases) { Text($0.name).tag(Optional($0)) }
                Divider()
                Text("Not sure (check all)").tag(XiaomiRegion?.none)
            }
            Text("The region you chose when creating your Xiaomi account. It's shown in the Xiaomi Home app under Profile → Settings → Region.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                startSignIn()
            } label: {
                Label("Sign in with Xiaomi", systemImage: "person.badge.key").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private var signingInStep: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Sign in on Xiaomi's page in your browser. The app continues by itself once you're signed in.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your password goes only to Xiaomi's website, never through this app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let webLoginURL {
                    Button("Open the sign-in page again") { NSWorkspace.shared.open(webLoginURL) }
                }
                Button("Cancel") {
                    loginTask?.cancel()
                    step = .start
                }
            }
            DisclosureGroup("Or scan a QR code with the Xiaomi Home app", isExpanded: $showQR) {
                Group {
                    if let qrImage {
                        Image(nsImage: qrImage).resizable().interpolation(.none).scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 180, height: 180)
                .frame(maxWidth: .infinity)
                Text("In the Xiaomi Home app: + (top right) → Scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            let vacuums = devices.filter(\.isVacuum)
            if vacuums.isEmpty {
                Label("No robot vacuums on this account in this region.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try another region") { step = .start }
            } else {
                Text("Choose your robot").font(.headline)
                ForEach(vacuums) { device in
                    deviceRow(device)
                }
                if let selected, selected.localIP.isEmpty {
                    Label("Xiaomi doesn't know this robot's address right now (is it switched on?). Enter its IP under \"Enter details manually\".",
                          systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func deviceRow(_ device: CloudDevice) -> some View {
        Button {
            if device.isSupported { selected = device }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == device ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(device.isSupported ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    Text(device.isSupported ? "\(device.localIP.isEmpty ? "address unknown" : device.localIP) · \(device.region.name)"
                         : "Not supported (\(device.model))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(selected == device ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.isSupported)
        .opacity(device.isSupported ? 1 : 0.55)
    }

    private func failedStep(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { step = .start }
        }
    }

    private var manualEntry: some View {
        DisclosureGroup("Enter details manually", isExpanded: $showManual) {
            VStack(spacing: 8) {
                TextField("IP address", text: $ip, prompt: Text("192.168.1.20"))
                SecureField("Token", text: $token, prompt: Text("32 hex characters"))
                TextField("Device ID", text: $did)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if let onDone { Button("Cancel", action: onDone) }
            Button("Connect", action: connect)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!canConnect)
        }
    }

    // MARK: - Actions

    private var manualIsValid: Bool { !ip.isEmpty && token.count == 32 && Data(hex: token) != nil }

    private var canConnect: Bool {
        if showManual { return manualIsValid }
        guard let selected else { return false }
        return !selected.localIP.isEmpty && selected.token.count == 32
    }

    private func connect() {
        if showManual {
            robot.configure(robot: RobotConfig(ip: ip, token: token.lowercased(), did: did), cloud: session)
        } else if let selected, var session {
            session.server = selected.region.rawValue  // the map lives on the robot's region server
            robot.configure(robot: RobotConfig(ip: selected.localIP, token: selected.token.lowercased(), did: selected.did),
                            cloud: session)
        }
        onDone?()
    }

    private func startSignIn() {
        step = .signingIn
        qrImage = nil
        loginTask = Task {
            let login = XiaomiQRLogin()
            do {
                let start = try await login.start()
                webLoginURL = start.webLoginURL
                if let url = start.webLoginURL { NSWorkspace.shared.open(url) }
                qrImage = NSImage(data: try await login.qrImage(start))
                let signedIn = try await login.waitForConfirmation(start, server: (region ?? .de).rawValue)
                session = signedIn
                step = .loadingDevices
                devices = try await findDevices(signedIn)
                LoginDiagnostics.log("devices found: \(devices.count) (\(devices.filter(\.isSupported).count) supported)")
                selected = devices.first(where: \.isSupported)
                if let selected, !selected.localIP.isEmpty { ip = selected.localIP; token = selected.token; did = selected.did }
                step = .choose
            } catch is CancellationError {
            } catch {
                LoginDiagnostics.log("failed: \(error)")
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// The chosen region, or every region when unsure. A failing region is skipped.
    private func findDevices(_ session: CloudSession) async throws -> [CloudDevice] {
        let regions = region.map { [$0] } ?? XiaomiRegion.allCases
        var found: [CloudDevice] = []
        for region in regions {
            var regional = session
            regional.server = region.rawValue
            do {
                found.append(contentsOf: try await XiaomiCloud(session: regional).devices(region: region))
            } catch {
                LoginDiagnostics.log("device list for \(region.rawValue) failed: \(error)")
            }
        }
        return found
    }
}
