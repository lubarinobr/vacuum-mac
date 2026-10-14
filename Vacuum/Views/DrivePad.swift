import SwiftUI

/// Floating drive controls over the map, so the robot can be watched while driving.
struct DrivePad: View {
    @Environment(RobotController.self) private var robot
    @Bindable var drive: DriveController

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Drive", systemImage: "gamecontroller").font(.headline)
                Spacer()
                Button("Stop", systemImage: "stop.fill") { stopAndExit() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help("Stop and leave manual mode")
            }
            Joystick(value: $drive.stick)
            Picker("Speed", selection: $drive.speed) {
                ForEach(DriveController.Speed.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle("Flip turning", isOn: $drive.invertTurning)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("Turn this on if the robot turns the opposite way from the stick")
            Text("Arrow keys or WASD also work")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 220)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func stopAndExit() {
        drive.stop(robot: robot)
    }
}

/// A round stick that springs back to the centre when released.
struct Joystick: View {
    @Binding var value: CGSize
    private let size: CGFloat = 180
    private let knob: CGFloat = 64

    var body: some View {
        let travel = (size - knob) / 2
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.06))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            Image(systemName: "arrow.up").offset(y: -size / 2 + 16)
            Image(systemName: "arrow.down").offset(y: size / 2 - 16)
            Image(systemName: "arrow.left").offset(x: -size / 2 + 16)
            Image(systemName: "arrow.right").offset(x: size / 2 - 16)
            Circle()
                .fill(.tint)
                .frame(width: knob, height: knob)
                .shadow(radius: 6, y: 3)
                .offset(x: value.width * travel, y: -value.height * travel)
        }
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let dx = (drag.location.x - size / 2) / travel
                    let dy = -(drag.location.y - size / 2) / travel
                    let length = max(1, hypot(dx, dy))  // keep the knob inside the ring
                    value = CGSize(width: dx / length, height: dy / length)
                }
                .onEnded { _ in withAnimation(.spring(duration: 0.25)) { value = .zero } }
        )
        .accessibilityLabel("Joystick")
    }
}
