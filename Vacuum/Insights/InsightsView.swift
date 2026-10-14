import Charts
import SwiftUI

/// Toolbar → Insights: how much the robot cleans, which rooms, and where it has trouble.
struct InsightsView: View {
    @Environment(RobotController.self) private var robot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let summary = InsightsSummary(history: robot.history, rooms: robot.roomAreas.keys.sorted())

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Insights").font(.title2.bold())
                if robot.isLoadingHistory { ProgressView().controlSize(.small).padding(.leading, 6) }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await robot.loadHistory() } }
                    .labelStyle(.iconOnly)
                    .disabled(robot.isLoadingHistory)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = robot.historyError {
                        Label("Couldn't load the history from Xiaomi: \(error)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    weekCards(summary)
                    weeklyChart(summary)
                    lifetime
                    roomsTable(summary)
                    problemsSection
                    recentCleans(summary)
                }
                .padding([.horizontal, .bottom], 24)
            }
        }
        .frame(width: 640, height: 720)
        .task { await robot.loadHistory() }
    }

    // MARK: - This week

    private func weekCards(_ summary: InsightsSummary) -> some View {
        HStack(spacing: 12) {
            statCard("Cleans this week", value: summary.thisWeek?.cleans ?? 0, previous: summary.lastWeek?.cleans, unit: "")
            statCard("Area", value: summary.thisWeek?.area ?? 0, previous: summary.lastWeek?.area, unit: " m²")
            statCard("Time", value: summary.thisWeek?.minutes ?? 0, previous: summary.lastWeek?.minutes, unit: " min")
        }
    }

    private func statCard(_ title: String, value: Int, previous: Int?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)\(unit)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
            if let previous {
                let diff = value - previous
                Text(diff == 0 ? "Same as last week" : "\(diff > 0 ? "+" : "")\(diff)\(unit) vs last week")
                    .font(.caption)
                    .foregroundStyle(diff >= 0 ? Color.secondary : .orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 16))
    }

    private func weeklyChart(_ summary: InsightsSummary) -> some View {
        PanelSection(title: "Cleans per week") {
            Chart(summary.weeks) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Cleans", week.cleans))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        if week.cleans > 0 { Text("\(week.cleans)").font(.caption2).foregroundStyle(.secondary) }
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 140)
        }
    }

    private var lifetime: some View {
        PanelSection(title: "Since you got the robot") {
            HStack(spacing: 24) {
                if let cleans = robot.int(Spec.totalCleans) { lifetimeItem("\(cleans)", "cleans") }
                if let area = robot.int(Spec.totalArea) { lifetimeItem(area.formatted(), "m² cleaned") }
                if let minutes = robot.int(Spec.totalCleaningMinutes) { lifetimeItem("\(minutes / 60)", "hours") }
                Spacer()
            }
        }
    }

    private func lifetimeItem(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Rooms

    private func roomsTable(_ summary: InsightsSummary) -> some View {
        PanelSection(title: "Rooms · last 30 days") {
            let maxCleans = max(summary.rooms.map(\.cleans).max() ?? 1, 1)
            ForEach(summary.rooms.sorted { $0.cleans > $1.cleans }) { stat in
                HStack(spacing: 10) {
                    Circle().fill(Color(nsColor: MapRenderer.color(forRoom: stat.room))).frame(width: 9, height: 9)
                    Text(robot.name(ofRoom: stat.room)).frame(width: 110, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color(nsColor: MapRenderer.color(forRoom: stat.room)).opacity(0.8))
                            .frame(width: max(4, geometry.size.width * CGFloat(stat.cleans) / CGFloat(maxCleans)))
                    }
                    .frame(height: 8)
                    Text("\(stat.cleans)×").monospacedDigit().frame(width: 36, alignment: .trailing)
                    Text(lastCleanedText(stat.lastCleaned))
                        .font(.caption)
                        .foregroundStyle(isNeglected(stat.lastCleaned) ? .orange : .secondary)
                        .frame(width: 110, alignment: .trailing)
                }
            }
            Text("Room numbers come from the robot. Cleans from before a room was merged or divided may count under its old number.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func lastCleanedText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return "Last " + date.formatted(.relative(presentation: .named))
    }

    private func isNeglected(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > 7 * 86_400
    }

    // MARK: - Problems

    private var problemsSection: some View {
        PanelSection(title: "Problems") {
            if robot.problems.isEmpty {
                Text("No problems recorded yet. The robot doesn't keep a list of its errors, so the app records each one, with where it happened, while it's open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ProblemMap()
                        .frame(width: 220, height: 260)
                    VStack(alignment: .leading, spacing: 8) {
                        let stuckCount = robot.problems.filter(\.isStuck).count
                        Text("\(robot.problems.count) problem\(robot.problems.count == 1 ? "" : "s") · \(stuckCount) stuck")
                            .font(.headline)
                        ForEach(robot.problems.suffix(8).reversed()) { problem in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: problem.isStuck ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(problem.isStuck ? .red : .orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(problem.name)
                                    Text("\(problem.date.formatted(date: .abbreviated, time: .shortened))\(problem.room.map { " · " + robot.name(ofRoom: $0) } ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent cleans

    private func recentCleans(_ summary: InsightsSummary) -> some View {
        PanelSection(title: "Recent cleans") {
            if summary.recent.isEmpty {
                Text(robot.isLoadingHistory ? "Loading…" : "No cleans in the history yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(summary.recent) { record in
                HStack(spacing: 10) {
                    Image(systemName: record.completed ? "checkmark.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(record.completed ? .green : .orange)
                        .help(record.completed ? "Finished" : "Interrupted")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.start.formatted(date: .abbreviated, time: .shortened))
                        Text(!record.isRoomClean ? "Whole house"
                             : record.rooms.isEmpty ? "Selected rooms"
                             : record.rooms.map { robot.name(ofRoom: $0) }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(record.minutes) min · \(record.area) m²")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The map with a dot for every recorded problem; red = stuck, orange = other errors.
private struct ProblemMap: View {
    @Environment(RobotController.self) private var robot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            if let map = robot.displayMap, let image = MapRenderer.image(map, selected: [], style: colorScheme == .dark ? .dark : .light) {
                let scale = min(geometry.size.width / CGFloat(map.width), geometry.size.height / CGFloat(map.height))
                let transform = MapTransform(map: map, scale: scale)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
                        .opacity(0.55)
                    ForEach(robot.problems.filter { $0.position != nil }) { problem in
                        let point = transform.view(problem.position!)
                        Circle()
                            .fill((problem.isStuck ? Color.red : Color.orange).opacity(0.75))
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .frame(width: 12, height: 12)
                            .position(point)
                            .help("\(problem.name) · \(problem.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .frame(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Map not loaded").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 12))
    }
}
