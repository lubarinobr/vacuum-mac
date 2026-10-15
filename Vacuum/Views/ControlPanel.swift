import SwiftUI

struct ControlPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StatusHeader()
                PrimaryActions()
                RoomsSection()
                CleaningSection()
            }
            .padding(20)
        }
        .scrollIndicators(.never)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

/// A titled group inside the glass panel. Plain tinted fill, not glass, to avoid glass-on-glass.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.06)))
    }
}

// MARK: - Status

private struct StatusHeader: View {
    @Environment(RobotController.self) private var robot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
        }
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: robot.statusSymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(robot.isConnected ? robot.statusTint : .secondary)
                .symbolEffect(.pulse, isActive: robot.isBusy)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .background(robot.statusTint.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusLED(color: robot.statusTint, isActive: robot.isBusy, size: 7)
                    Text(robot.isConnected ? "Online" : "Offline")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Text(robot.statusText)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                if robot.isBusy, let minutes = robot.int(Spec.cleaningTime), let area = robot.int(Spec.cleaningArea) {
                    Text("\(minutes) min · \(area) m²")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            Spacer()
            if let battery = robot.int(Spec.battery) {
                BatteryGauge(level: battery, isCharging: robot.int(Spec.status) == 6,
                             isDocked: [6, 13].contains(robot.int(Spec.status) ?? 0))
            }
        }
        .animation(.smooth(duration: 0.4), value: robot.statusText)
        .animation(.smooth, value: robot.int(Spec.battery))

        // Only what needs attention, plus when the next scheduled clean is.
        let alerts = robot.partAlerts
        if !alerts.isEmpty || robot.nextScheduleText != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(alerts, id: \.self) { alert in
                    Label(alert, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
                if let next = robot.nextScheduleText {
                    Label(next, systemImage: "calendar")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.top, 4)
        }
    }

}

/// A battery drawn as a small lit cell: green and glowing on the dock, red when low.
private struct BatteryGauge: View {
    let level: Int
    let isCharging: Bool
    let isDocked: Bool

    private var color: Color { level < 20 ? .red : isDocked ? .green : .primary }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(level)%")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(level < 20 ? .red : .secondary)
                .contentTransition(.numericText(value: Double(level)))
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2)
                    .frame(width: 28, height: 14)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.opacity(color == .primary ? 0.7 : 1))
                            .frame(width: max(2, 24 * CGFloat(level) / 100), height: 10)
                            .padding(.leading, 2)
                            .ledGlow(color, radius: 5, isOn: color != .primary)
                    }
                    .overlay {
                        if isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 1)
                        }
                    }
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 2, height: 5)
            }
        }
        .animation(.smooth(duration: 0.6), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue("\(level)%\(isCharging ? ", charging" : "")")
    }
}

/// One main button that adapts: whole house, selected rooms, or Stop while cleaning.
private struct PrimaryActions: View {
    @Environment(RobotController.self) private var robot

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if robot.isBusy {
                    Button { Task { await robot.stop() } } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button {
                        Task { robot.selectedRooms.isEmpty ? await robot.start() : await robot.cleanSelectedRooms() }
                    } label: {
                        Label(mainTitle, systemImage: robot.selectedRooms.isEmpty ? "play.fill" : "sparkles")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.glassProminent)
                }
                Button { Task { await robot.goHome() } } label: {
                    Label("Home", systemImage: "house.fill")
                }
                .buttonStyle(.glass)
                .help("Send the robot back to the dock")
                Menu {
                    Button("Empty bin", systemImage: "trash") { Task { await robot.emptyBin() } }
                    Button("Locate robot", systemImage: "speaker.wave.2.fill") { Task { await robot.locate() } }
                    if !robot.isBusy {
                        Divider()
                        Button("Stop", systemImage: "stop.fill") { Task { await robot.stop() } }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .help("More actions")
            }
            .controlSize(.large)
        }
        .animation(.smooth(duration: 0.3), value: robot.selectedRooms)
        .animation(.smooth(duration: 0.3), value: robot.isBusy)
    }

    private var mainTitle: String {
        let count = robot.selectedRooms.count
        return count == 0 ? "Clean whole house" : "Clean \(count) room\(count == 1 ? "" : "s")"
    }
}

// MARK: - Rooms

private struct RoomsSection: View {
    @Environment(RobotController.self) private var robot
    @State private var renamingRoom: Int?
    @State private var newName = ""

    var body: some View {
        PanelSection(title: robot.selectedRooms.isEmpty ? "Rooms" : "Rooms · \(robot.selectedRooms.count) selected") {
            if robot.map == nil {
                Text("Rooms appear when the map loads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(robot.roomAreas.keys.sorted(), id: \.self) { id in
                        RoomRow(id: id, area: robot.roomAreas[id] ?? 0) {
                            newName = robot.roomNames[id] ?? ""
                            renamingRoom = id
                        }
                    }
                }
                if !robot.hiddenRoomsOnMap.isEmpty {
                    DisclosureGroup("Hidden rooms (\(robot.hiddenRoomsOnMap.count))") {
                        ForEach(robot.hiddenRoomsOnMap, id: \.self) { id in
                            HStack {
                                Text(robot.name(ofRoom: id)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Show") { robot.setHidden(false, room: id) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: robot.selectedRooms)
        .animation(.smooth(duration: 0.3), value: robot.isEditingRooms)
        .alert("Rename room", isPresented: Binding(get: { renamingRoom != nil }, set: { if !$0 { renamingRoom = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let id = renamingRoom { robot.rename(room: id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Names are saved only on this Mac.")
        }
    }
}

private struct RoomRow: View {
    @Environment(RobotController.self) private var robot
    let id: Int
    let area: Double
    let onRename: () -> Void
    @State private var hovering = false
    @State private var showingSettings = false

    private var isSelected: Bool { robot.selectedRooms.contains(id) }
    private var preference: RoomPreference { robot.preference(forRoom: id) }

    private var preferenceSummary: String? {
        guard !preference.isDefault else { return nil }
        var parts: [String] = []
        if preference.repeats > 1 { parts.append("\(preference.repeats)×") }
        if let mode = preference.mode.flatMap(CleaningMode.init(rawValue:)) { parts.append(mode.name) }
        if let suction = preference.suction { parts.append(SuctionLevel(rawValue: suction)?.name ?? "") }
        if let water = preference.water { parts.append("Water " + (MopLevel(rawValue: water)?.name.lowercased() ?? "")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color(nsColor: MapRenderer.color(forRoom: id)) : .secondary)
                .font(.body)
                .contentTransition(.symbolEffect(.replace))
            Circle()
                .fill(Color(nsColor: MapRenderer.color(forRoom: id)))
                .frame(width: 8, height: 8)
                .ledGlow(Color(nsColor: MapRenderer.color(forRoom: id)), radius: 6, isOn: isSelected)
            VStack(alignment: .leading, spacing: 1) {
                Text(robot.name(ofRoom: id))
                if let summary = preferenceSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hovering || isSelected || showingSettings {
                Button("Cleaning settings", systemImage: "slider.horizontal.3") { showingSettings = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Suction, water and repeats for this room")
                    .transition(.opacity)
                    .popover(isPresented: $showingSettings, arrowEdge: .leading) {
                        RoomSettingsPopover(id: id)
                    }
            }
            if hovering {
                Button("Rename", systemImage: "pencil", action: onRename)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .transition(.opacity)
                Button("Hide", systemImage: "eye.slash") { robot.setHidden(true, room: id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide this room in this app (the robot still knows it)")
                    .transition(.opacity)
            }
            Text(String(format: "%.1f m²", area))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.05) : .clear,
                    in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { robot.toggle(room: id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { robot.toggle(room: id) }
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
        .animation(.smooth(duration: 0.25), value: isSelected)
    }
}

struct RoomSettingsPopover: View {
    @Environment(RobotController.self) private var robot
    let id: Int

    private func binding<T>(_ keyPath: WritableKeyPath<RoomPreference, T>) -> Binding<T> {
        Binding(get: { robot.preference(forRoom: id)[keyPath: keyPath] },
                set: { value in
                    var preference = robot.preference(forRoom: id)
                    preference[keyPath: keyPath] = value
                    robot.set(preference, forRoom: id)
                })
    }

    private static let off = -1

    /// A level picker with an Off entry. Off switches the room to the mode that leaves this part out;
    /// picking a level while it is off switches to vacuuming and mopping.
    private func levelBinding(_ level: WritableKeyPath<RoomPreference, Int?>, offMode: CleaningMode) -> Binding<Int?> {
        Binding(
            get: {
                let preference = robot.preference(forRoom: id)
                return preference.mode == offMode.rawValue ? Self.off : preference[keyPath: level]
            },
            set: { value in
                var preference = robot.preference(forRoom: id)
                if value == Self.off {
                    preference.mode = offMode.rawValue
                } else {
                    preference[keyPath: level] = value
                    if preference.mode == offMode.rawValue { preference.mode = CleaningMode.vacuumAndMop.rawValue }
                }
                robot.set(preference, forRoom: id)
            })
    }

    var body: some View {
        let preference = robot.preference(forRoom: id)
        VStack(alignment: .leading, spacing: 14) {
            Text(robot.name(ofRoom: id)).font(.headline)
            Picker("Mode", selection: binding(\.mode)) {
                Text("Current setting").tag(Int?.none)
                ForEach(CleaningMode.allCases) { Text($0.name).tag(Int?.some($0.rawValue)) }
            }
            // "Off" is a shortcut for the mode: suction off means mopping only, water off means vacuuming only.
            Picker("Suction", selection: levelBinding(\.suction, offMode: .mop)) {
                Text("Current setting").tag(Int?.none)
                Text("Off").tag(Int?.some(Self.off))
                ForEach(SuctionLevel.allCases) { Text($0.name).tag(Int?.some($0.rawValue)) }
            }
            Picker("Mop water", selection: levelBinding(\.water, offMode: .vacuum)) {
                Text("Current setting").tag(Int?.none)
                Text("Off").tag(Int?.some(Self.off))
                ForEach(MopLevel.allCases) { Text($0.name).tag(Int?.some($0.rawValue)) }
            }
            Stepper("Repeats: \(preference.repeats)", value: binding(\.repeats), in: 1...RoomPreference.maxRepeats)
            Text("Used when you clean this room from here. The robot has one mode per job, so rooms with different modes are cleaned separately. Saved on this Mac only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !preference.isDefault {
                Button("Reset") { robot.set(RoomPreference(), forRoom: id) }
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

// MARK: - Map layers

/// Shown from the Layers button on the map.
struct MapLayersMenu: View {
    @Environment(RobotController.self) private var robot
    @AppStorage("showRoomNames") private var showRoomNames = false
    @AppStorage("showZones") private var showZones = true
    @AppStorage("showCarpets") private var showCarpets = false
    @AppStorage("showPath") private var showPath = true
    @AppStorage("showFurniture") private var showFurniture = true
    @AppStorage("roomLabelScale") private var roomLabelScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Map layers").font(.headline)
            Toggle("Room names", isOn: $showRoomNames)
            HStack(spacing: 8) {
                Text("Label size")
                Slider(value: $roomLabelScale, in: 0.7...1.8)
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
            }
            Toggle("Cleaning path", isOn: $showPath)
            Toggle(isOn: $showZones) {
                HStack(spacing: 6) {
                    Text("Restricted zones")
                    if let zones = robot.map?.zones { Text(zoneSummary(zones)).foregroundStyle(.secondary) }
                }
            }
            Toggle(isOn: $showFurniture) {
                HStack(spacing: 6) {
                    Text("Furniture")
                    if !robot.furniture.isEmpty { Text("\(robot.furniture.count)").foregroundStyle(.secondary) }
                }
            }
            Toggle(isOn: $showCarpets) {
                HStack(spacing: 6) {
                    Text("Carpets")
                    if let count = robot.map?.zones.carpets.count, count > 0 { Text("\(count)").foregroundStyle(.secondary) }
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }

    private func zoneSummary(_ zones: VacuumMap.Zones) -> String {
        var parts: [String] = []
        if !zones.virtualWalls.isEmpty { parts.append("\(zones.virtualWalls.count) wall\(zones.virtualWalls.count == 1 ? "" : "s")") }
        if !zones.noGo.isEmpty { parts.append("\(zones.noGo.count) no-go") }
        if !zones.noMop.isEmpty { parts.append("\(zones.noMop.count) no-mop") }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }
}

// MARK: - Cleaning settings

private struct CleaningSection: View {
    @Environment(RobotController.self) private var robot

    var body: some View {
        PanelSection(title: "Cleaning") {
            if let mode = robot.cleaningMode {
                ModeSelector(selection: mode) { newMode in Task { await robot.setCleaningMode(newMode) } }
            }
            LevelSelector(title: "Suction",
                          labels: SuctionLevel.allCases.map(\.name),
                          selected: robot.int(Spec.suction) ?? 0) { index in
                Task { await robot.setSuction(SuctionLevel(rawValue: index) ?? .basic) }
            }
            LevelSelector(title: "Mop water",
                          labels: MopLevel.allCases.map(\.name),
                          selected: (robot.int(Spec.mopLevel) ?? 2) - 1) { index in
                Task { await robot.setMop(MopLevel(rawValue: index + 1) ?? .medium) }
            }
        }
    }
}

private struct ModeSelector: View {
    let selection: CleaningMode
    let onSelect: (CleaningMode) -> Void
    @Namespace private var namespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(CleaningMode.allCases) { mode in
                    Button { onSelect(mode) } label: {
                        ModeIcon(mode: mode)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(selection == mode ? Color.primary : .secondary)
                            .background {
                                if selection == mode {
                                    Capsule()
                                        .fill(colorScheme == .dark ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(.background))
                                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 3, y: 1)
                                        .matchedGeometryEffect(id: "selection", in: namespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(mode.name)
                    .accessibilityLabel(mode.name)
                    .accessibilityAddTraits(selection == mode ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.07), in: Capsule())
            Text(selection.name)
                .font(.callout)
                .id(selection)
                .transition(.opacity.combined(with: .offset(y: 3)))
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: selection)
    }
}

private struct ModeIcon: View {
    let mode: CleaningMode

    var body: some View {
        HStack(spacing: 2) {
            switch mode {
            case .vacuum:
                Image(systemName: "wind")
            case .vacuumAndMop:
                Image(systemName: "wind")
                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                Image(systemName: "drop.fill")
            case .mop:
                Image(systemName: "drop.fill")
            case .mopAfterVacuum:
                Image(systemName: "wind")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                Image(systemName: "drop.fill")
            }
        }
        .font(.system(size: 13, weight: .medium))
    }
}

private struct LevelSelector: View {
    let title: String
    let labels: [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(labels[min(max(selected, 0), labels.count - 1)])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            // Like a row of indicator lights: the lit segments glow softly.
            HStack(spacing: 4) {
                ForEach(labels.indices, id: \.self) { index in
                    let lit = index <= selected
                    Capsule()
                        .fill(lit ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)))
                        .frame(height: 8)
                        .ledGlow(.accentColor, radius: 5, isOn: lit)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(index) }
                        .help(labels[index])
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(labels[min(max(selected, 0), labels.count - 1)])
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if selected < labels.count - 1 { onSelect(selected + 1) }
            case .decrement: if selected > 0 { onSelect(selected - 1) }
            @unknown default: break
            }
        }
    }
}

// MARK: - Schedules

struct SchedulesSection: View {
    @Environment(RobotController.self) private var robot
    @State private var editing: CleaningSchedule?
    @State private var deleting: CleaningSchedule?

    var body: some View {
        PanelSection(title: "Schedules") {
            let schedules = robot.schedules
            if schedules.isEmpty {
                Text("No scheduled cleans.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(schedules) { schedule in
                ScheduleRow(schedule: schedule,
                            onEdit: { editing = schedule },
                            onDelete: { deleting = schedule })
            }
            Button {
                editing = robot.newSchedule()
            } label: {
                Label("Add schedule", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .animation(.smooth(duration: 0.3), value: robot.schedules)
        .sheet(item: $editing) { schedule in
            ScheduleEditor(schedule: schedule, isNew: !robot.schedules.contains { $0.id == schedule.id }) { saved in
                Task { await robot.save(schedule: saved) }
            }
        }
        .confirmationDialog("Delete the \(deleting?.timeText ?? "") schedule?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let schedule = deleting { Task { await robot.delete(schedule: schedule) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ScheduleRow: View {
    @Environment(RobotController.self) private var robot
    let schedule: CleaningSchedule
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.timeText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(schedule.isEnabled ? .primary : .secondary)
                Text("\(schedule.daysText) · \(roomsText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if hovering {
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                Button("Delete", systemImage: "trash", action: onDelete)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            Toggle("On", isOn: Binding(get: { schedule.isEnabled },
                                       set: { on in Task { await robot.setEnabled(on, schedule: schedule) } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
    }

    private var roomsText: String {
        schedule.rooms.isEmpty ? "Whole house" : schedule.rooms.map { robot.name(ofRoom: $0) }.joined(separator: ", ")
    }
}

struct ScheduleEditor: View {
    @Environment(RobotController.self) private var robot
    @Environment(\.dismiss) private var dismiss
    @State var schedule: CleaningSchedule
    let isNew: Bool
    let onSave: (CleaningSchedule) -> Void

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule.hour = parts.hour ?? 0
                schedule.minute = parts.minute ?? 0
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New schedule" : "Edit schedule").font(.title2.bold())

            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)

            VStack(alignment: .leading, spacing: 8) {
                Text("Repeat").font(.headline)
                HStack(spacing: 6) {
                    ForEach(CleaningSchedule.displayDayOrder, id: \.self) { day in
                        Button {
                            schedule.days[day].toggle()
                        } label: {
                            Text(CleaningSchedule.dayLetters[day])
                                .font(.callout.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(schedule.days[day] ? Color.white : .primary)
                                .background(schedule.days[day] ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(CleaningSchedule.dayNames[day])
                        .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                        .accessibilityAddTraits(schedule.days[day] ? .isSelected : [])
                    }
                }
                Text(schedule.repeats ? schedule.daysText : "No days selected: runs once")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Clean").font(.headline)
                Picker("Area", selection: Binding(get: { schedule.rooms.isEmpty }, set: { whole in
                    schedule.rooms = whole ? [] : Array(robot.roomAreas.keys.sorted().prefix(1))
                })) {
                    Text("Whole house").tag(true)
                    Text("Selected rooms").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !schedule.rooms.isEmpty {
                    ForEach(robot.roomAreas.keys.sorted(), id: \.self) { id in
                        Toggle(robot.name(ofRoom: id), isOn: Binding(
                            get: { schedule.rooms.contains(id) },
                            set: { on in
                                if on { schedule.rooms.append(id) } else if schedule.rooms.count > 1 { schedule.rooms.removeAll { $0 == id } }
                            }))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Picker("Suction", selection: $schedule.suction) {
                ForEach(SuctionLevel.allCases) { Text($0.name).tag($0.rawValue) }
            }

            Toggle("Enabled", isOn: $schedule.isEnabled)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(schedule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Parts

struct PartsSection: View {
    @Environment(RobotController.self) private var robot

    var body: some View {
        PanelSection(title: "Parts") {
            HStack {
                PartRing(name: "Main brush", level: robot.int(Spec.mainBrush))
                PartRing(name: "Side brush", level: robot.int(Spec.sideBrush))
                PartRing(name: "Filter", level: robot.int(Spec.filter))
                PartRing(name: "Mop pads", level: robot.int(Spec.mopPad))
            }
        }
    }
}

struct PartRing: View {
    let name: String
    let level: Int?

    var body: some View {
        let value = Double(level ?? 0) / 100
        let color: Color = (level ?? 100) < 20 ? .red : (level ?? 100) < 40 ? .orange : .accentColor
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .ledGlow(color, radius: 4)
                Text(level.map { "\($0)" } ?? "–")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color == .red ? .red : .primary)
                    .contentTransition(.numericText())
            }
            .frame(width: 44, height: 44)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .help(level.map { "\(name): \($0)% left" } ?? name)
        .animation(.smooth(duration: 0.6), value: level)
    }
}
