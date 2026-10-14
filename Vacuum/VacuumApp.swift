import SwiftUI

@main
struct VacuumApp: App {
    @State private var robot = RobotController()
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup("Vacuum") {
            ContentView()
                .environment(robot)
                .frame(minWidth: 920, minHeight: 640)
                // Set on the app, not with preferredColorScheme: going back to System then really follows the Mac,
                // and sheets, popovers and menus match.
                .onChange(of: appearance, initial: true) { NSApp.appearance = appearance.nsAppearance }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Label($0.name, systemImage: $0.systemImage).tag($0) }
                }
                Divider()
                Button("Zoom In") { robot.zoomIn() }
                    .keyboardShortcut("=")
                    .disabled(!robot.canZoomIn)
                Button("Zoom Out") { robot.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!robot.canZoomOut)
                Button("Zoom to Fit") { robot.zoomToFit() }
                    .keyboardShortcut("0")
                    .disabled(!robot.canZoomOut)
                Divider()
            }
            // The map's editing modes, also in the pencil menu on the map.
            CommandMenu("Map") {
                Button("Edit Walls and Zones") {
                    UserDefaults.standard.set(true, forKey: "showZones")
                    robot.beginEditingZones()
                }
                .disabled(robot.map == nil)
                Button("Merge or Divide Rooms") { robot.beginEditingRooms() }
                    .disabled(robot.map == nil)
                Button("Edit Furniture and Belongings") { robot.beginEditingFurniture() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(robot.map == nil)
                Menu("Add to Map") {
                    ForEach(Furniture.Kind.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.kinds) { kind in
                                Button(kind.name, systemImage: kind.systemImage) {
                                    if !robot.isEditingFurniture { robot.beginEditingFurniture() }
                                    robot.furnitureTool = kind
                                }
                            }
                        }
                    }
                }
                .disabled(robot.map == nil)
                Button("Make Item Larger") { robot.scaleSelectedFurniture(by: 1.25) }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                    .disabled(!robot.canScaleSelectedFurniture)
                Button("Make Item Smaller") { robot.scaleSelectedFurniture(by: 0.8) }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                    .disabled(!robot.canScaleSelectedFurniture)
                Divider()
                Button("Refresh Map") { Task { await robot.loadMap() } }
                    .keyboardShortcut("r")
                    .disabled(robot.config == nil || robot.isLoadingMap)
            }
        }
    }
}
