import SwiftUI

struct ContentView: View {
    @Environment(RobotController.self) private var robot
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSchedules = false
    @State private var showingInsights = false
    @State private var showingRobot = false
    @State private var drive = DriveController()
    @State private var showingLogin = false

    var body: some View {
        Group {
            if robot.config == nil {
                SetupView()
            } else {
                HStack(spacing: 0) {
                    MapPanel(showingLogin: $showingLogin, drive: drive)
                    ControlPanel()
                        .frame(width: 360)
                        .padding([.vertical, .trailing], 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground(tint: robot.config == nil ? .blue : robot.statusTint) }
        .onChange(of: colorScheme, initial: true) { robot.mapStyle = colorScheme == .dark ? .dark : .light }
        .toolbar {
            if robot.config != nil {
                ToolbarItem {
                    Toggle("Drive", systemImage: "gamecontroller", isOn: Binding(
                        get: { drive.isActive },
                        set: { $0 ? drive.start(robot: robot) : drive.stop(robot: robot) }
                    ))
                        .labelStyle(.titleAndIcon)
                        .help("Drive the robot by hand: joystick, arrow keys or WASD")
                }
                ToolbarItem {
                    Button("Insights", systemImage: "chart.bar.xaxis") { showingInsights = true }
                        .labelStyle(.titleAndIcon)
                        .help("Cleaning history, rooms and problems")
                }
                ToolbarItem {
                    Button("Schedules", systemImage: "calendar") { showingSchedules = true }
                        .labelStyle(.titleAndIcon)
                        .help("Scheduled cleans")
                }
                ToolbarItem {
                    Button("Robot", systemImage: "gearshape") { showingRobot = true }
                        .help("Parts, quiet hours and connection")
                }
            }
        }
        .sheet(isPresented: $showingSchedules) { SchedulesSheet() }
        .sheet(isPresented: $showingInsights) { InsightsView() }
        .sheet(isPresented: $showingRobot) { RobotSheet() }
        .sheet(isPresented: $showingLogin) {
            CloudLoginView(onDone: { showingLogin = false })
        }
    }
}
