import SwiftUI

/// Toolbar → calendar: all scheduled cleans.
struct SchedulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Scheduled cleans").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            SchedulesSection()
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// Toolbar → gear: parts, quiet hours and connection settings.
struct RobotSheet: View {
    @Environment(RobotController.self) private var robot
    @Environment(\.dismiss) private var dismiss
    @State private var resetting: RobotController.Part?
    @State private var showingConnection = false
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Robot").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            PanelSection(title: "Parts") {
                ForEach(RobotController.parts) { part in
                    HStack(spacing: 12) {
                        PartRing(name: "", level: robot.int(part.level))
                            .frame(width: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(part.name)
                            Text(robot.int(part.level).map { "\($0)% left" } ?? "Unknown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset") { resetting = part }
                            .help("Use after replacing the \(part.name.lowercased())")
                    }
                }
            }

            PanelSection(title: "Do not disturb") {
                if robot.bool(Spec.dndEnabled) == true, let start = robot.string(Spec.dndStart), let end = robot.string(Spec.dndEnd) {
                    Label("Quiet from \(start) to \(end)", systemImage: "moon.fill")
                } else {
                    Label("Off", systemImage: "moon")
                        .foregroundStyle(.secondary)
                }
            }

            PanelSection(title: "Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Label($0.name, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            PanelSection(title: "About") {
                Text("Not affiliated with or endorsed by Xiaomi. Uses an unofficial connection to the robot and Xiaomi's servers, which may stop working after a Xiaomi update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Built on the work of [python-miio](https://github.com/rytilahti/python-miio), [Xiaomi Cloud Tokens Extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) and [dreame-vacuum](https://github.com/Tasshack/dreame-vacuum).")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelSection(title: "Connection") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(robot.config?.ip ?? "Not set up")
                        Text(robot.cloud == nil ? "Not signed in to Xiaomi" : "Signed in to Xiaomi · \(XiaomiRegion(rawValue: robot.cloud?.server ?? "")?.name ?? robot.cloud?.server ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change…") { showingConnection = true }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .confirmationDialog("Reset the \(resetting?.name.lowercased() ?? "") to 100%?",
                            isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } })) {
            Button("Reset") { if let part = resetting { Task { await robot.resetPart(part) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do this after replacing it, so the robot tracks the new part's wear.")
        }
        .sheet(isPresented: $showingConnection) {
            SetupView(onDone: { showingConnection = false })
                .frame(width: 480)
        }
    }
}

/// Glass buttons in the map's corner: layers and editing tools.
struct MapTools: View {
    @Environment(RobotController.self) private var robot
    @AppStorage("showZones") private var showZones = true
    @State private var showingLayers = false

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showingLayers.toggle()
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .help("Map layers")
                .accessibilityLabel("Map layers")
                .popover(isPresented: $showingLayers, arrowEdge: .bottom) { MapLayersMenu() }

                Menu {
                    Button("Walls and zones", systemImage: "pencil.and.outline") {
                        showZones = true
                        robot.beginEditingZones()
                    }
                    Button("Merge or divide rooms", systemImage: "square.split.2x1") { robot.beginEditingRooms() }
                    Divider()
                    Button("Furniture and belongings", systemImage: "sofa") { robot.beginEditingFurniture() }
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Edit the map")
                .accessibilityLabel("Edit the map")
            }
            .controlSize(.large)
        }
    }
}
