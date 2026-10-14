import SwiftUI

/// One piece of furniture on the map: its symbol on a solid rounded badge, sized like its real footprint
/// (never below `minimumSide`, so small things stay readable and clickable).
struct FurniturePin: View {
    static let minimumSide: CGFloat = 24

    let item: Furniture
    let isSelected: Bool
    /// Edge length in points.
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
        Image(systemName: item.kind.systemImage)
            // The symbol grows with the footprint only up to a point, so big items stay calm tiles.
            .font(.system(size: min(max(side * 0.42, 11), 24), weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : .primary)
            .frame(width: side, height: side)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.background), in: shape)
            .overlay(shape.strokeBorder(isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.25),
                                        lineWidth: isSelected ? 1.5 : 1))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
            .ledGlow(.accentColor, radius: 8, isOn: isSelected)
            .scaleEffect(isSelected ? 1 + 3 / side : 1)  // the same small "lift" at any size
            .accessibilityElement()
            .accessibilityLabel(item.displayName)
            .accessibilityValue(String(format: "%.1f m", item.size / 1000))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The corner grip on the selected item.
struct FurnitureResizeHandle: View {
    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

/// Glass toolbar shown over the map while placing furniture. Changes are saved on this Mac right away.
struct FurnitureEditToolbar: View {
    @Environment(RobotController.self) private var robot
    @State private var renaming: Furniture?
    @State private var newLabel = ""

    var body: some View {
        let selected = robot.furniture.first { $0.id == robot.selectedFurnitureID }
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Furniture.Kind.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.kinds) { kind in
                                Button(kind.name, systemImage: kind.systemImage) {
                                    robot.furnitureTool = kind
                                    robot.selectedFurnitureID = nil
                                }
                            }
                        }
                    }
                } label: {
                    Label(robot.furnitureTool?.name ?? "Add item", systemImage: robot.furnitureTool?.systemImage ?? "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Choose something to place on the map")

                if robot.furnitureTool != nil {
                    Button("Cancel placing", systemImage: "xmark") { robot.furnitureTool = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .help("Stop placing")
                }

                if let selected {
                    HStack(spacing: 2) {
                        Button("Smaller", systemImage: "minus") { robot.scaleSelectedFurniture(by: 0.8) }
                            .help("Make it smaller (⌥⌘−)")
                            .disabled(selected.size <= Furniture.sizeRange.lowerBound)
                        Text(String(format: "%.1f m", selected.size / 1000))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44)
                            .contentTransition(.numericText(value: selected.size))
                        Button("Larger", systemImage: "plus") { robot.scaleSelectedFurniture(by: 1.25) }
                            .help("Make it larger (⌥⌘=), or drag its corner")
                            .disabled(selected.size >= Furniture.sizeRange.upperBound)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .animation(.smooth(duration: 0.2), value: selected.size)

                    Button("Rename", systemImage: "pencil") {
                        newLabel = selected.label
                        renaming = selected
                    }
                    .buttonStyle(.glass)
                    .help("Give the \(selected.kind.name.lowercased()) your own name")
                    Button("Delete", systemImage: "trash") { robot.deleteSelectedFurniture() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .help("Remove \(selected.displayName) from the map")
                }

                Button("Done") { robot.endEditingFurniture() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .animation(.smooth(duration: 0.25), value: robot.furnitureTool)
        .animation(.smooth(duration: 0.25), value: robot.selectedFurnitureID)
        .alert("Rename \(renaming?.kind.name.lowercased() ?? "item")",
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming?.kind.name ?? "Name", text: $newLabel)
            Button("Save") { if let item = renaming { robot.rename(furniture: item.id, to: newLabel) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Furniture is saved only on this Mac.")
        }
    }
}
