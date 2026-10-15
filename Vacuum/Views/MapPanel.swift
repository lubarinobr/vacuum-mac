import SwiftUI

struct MapPanel: View {
    @Environment(RobotController.self) private var robot
    @Binding var showingLogin: Bool
    var drive: DriveController

    var body: some View {
        ZStack {
            if robot.map != nil {
                // Margins keep the whole house clear of the floating buttons; zoomed in, the map scrolls under them.
                MapCanvas(margins: EdgeInsets(top: robot.isEditingZones || robot.isEditingRooms || robot.isEditingFurniture ? 64 : 20,
                                              leading: 28, bottom: 70, trailing: 28))
                    .clipped()  // zoomed in, the map stays inside its own area
                    .transition(.opacity)
            } else if robot.isLoadingMap {
                ProgressView("Loading map…")
            } else {
                ContentUnavailableView {
                    Label("No map yet", systemImage: "map")
                } description: {
                    Text(robot.mapError ?? "")
                } actions: {
                    if robot.cloud == nil || robot.mapError == CloudError.loginExpired.localizedDescription {
                        Button("Sign in to Xiaomi") { showingLogin = true }
                            .buttonStyle(.glassProminent)
                    } else {
                        Button("Try again") { Task { await robot.loadMap() } }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            VStack(spacing: 10) {
                if robot.isEditingZones {
                    ZoneEditToolbar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if robot.isEditingRooms {
                    RoomEditToolbar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if robot.isEditingFurniture {
                    FurnitureEditToolbar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let error = robot.lastError {
                    HStack(spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                        if robot.actionError != nil {
                            Button("Dismiss", systemImage: "xmark") { robot.dismissError() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
        }
        .overlay(alignment: .topTrailing) {
            if robot.map != nil && !robot.isEditingZones && !robot.isEditingRooms && !robot.isEditingFurniture {
                MapTools()
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { bottomBar }
        .overlay(alignment: .bottomLeading) {
            if drive.isActive {
                DrivePad(drive: drive)
                    .padding(16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: drive.isActive)
        .overlay(alignment: .bottomTrailing) {
            if robot.map != nil {
                MapZoomControls()
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: robot.lastError)
        .animation(.smooth(duration: 0.35), value: robot.isEditingZones)
        .animation(.smooth(duration: 0.35), value: robot.isEditingRooms)
        .animation(.smooth(duration: 0.35), value: robot.isEditingFurniture)
        .animation(.smooth(duration: 0.4), value: robot.map == nil)
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if robot.map != nil {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(in: .capsule)
                }
                Button {
                    Task { await robot.loadMap() }
                } label: {
                    Label("Refresh map", systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: robot.isLoadingMap)
                }
                .buttonStyle(.glass)
                .disabled(robot.isLoadingMap)
            }
        }
        .padding(.bottom, 16)
        .animation(.smooth, value: robot.selectedRooms.count)
    }

    private var hint: String {
        if robot.isEditingFurniture {
            if let tool = robot.furnitureTool { return "Click the map to place the \(tool.name.lowercased())" }
            if robot.furniture.isEmpty { return "Choose Add item, then click the map" }
            return robot.selectedFurnitureID == nil
                ? "Click an item to select it, or drag it to move"
                : "Drag to move · drag the corner to resize · Delete key to remove"
        }
        if robot.isEditingRooms {
            switch robot.roomEditTool {
            case .merge:
                if robot.selectedRooms.count == 2 && !robot.canMerge { return "These rooms don't touch, so they can't be merged" }
                return robot.selectedRooms.count == 2 ? "Ready to merge" : "Click two neighboring rooms to merge"
            case .divide:
                if robot.selectedRooms.isEmpty { return "Click the room you want to divide" }
                return robot.divideLine == nil ? "Drag a line across the room where it should be divided" : "Ready to divide · drag again to redraw"
            }
        }
        if robot.isEditingZones {
            if let tool = robot.zoneTool {
                return tool == .wall ? "Drag on the map to draw a wall" : "Drag on the map to draw a \(tool.name.lowercased()) zone"
            }
            return robot.selectedZoneID == nil
                ? "Click a zone to select it, or pick a tool above"
                : "Drag to move · drag a handle to resize · trash or Delete key to remove"
        }
        return robot.selectedRooms.isEmpty
            ? "Click rooms to select them"
            : "\(robot.selectedRooms.count) room\(robot.selectedRooms.count == 1 ? "" : "s") selected"
    }
}

struct MapCanvas: View {
    var margins = EdgeInsets()
    @Environment(RobotController.self) private var robot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("showRoomNames") private var showRoomNames = false
    @AppStorage("showZones") private var showZones = true
    @AppStorage("showCarpets") private var showCarpets = false
    @AppStorage("showPath") private var showPath = true
    @AppStorage("showFurniture") private var showFurniture = true
    @State private var hoveredRoom: Int?
    @State private var hoveredFurniture: UUID?
    @State private var dragMode: ZoneDragMode?
    @State private var furnitureDrag: FurnitureDragMode?
    // Zoom: where the scroll view is, and the point a pinch keeps under your fingers.
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollGeometry: ScrollGeometry?
    /// The offset the zoom last asked for. The scroll view reports its position a frame late, so during a
    /// zoom animation this, not the report, is where the map really is.
    @State private var requestedOffset: CGPoint?
    @State private var pinch: (startZoom: CGFloat, anchor: CGPoint)?

    private enum FurnitureDragMode {
        case idle
        /// Where it was grabbed, relative to its center.
        case move(UUID, grab: CGSize)
        case resize(UUID, center: CGPoint)
    }

    private enum ZoneDragMode {
        case idle
        case create(UUID)
        case move(UUID, a: CGPoint, b: CGPoint, start: CGPoint)
        case resize(UUID, fixed: CGPoint, wallEnd: Int?)
    }

    private func zoneDrag(_ transform: MapTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == nil { dragMode = startDrag(at: value.startLocation, transform) }
                let point = transform.mm(value.location)
                guard let mode = dragMode else { return }
                switch mode {
                case .idle:
                    break
                case .create(let id):
                    update(id) { $0.b = point }
                case .move(let id, let a, let b, let start):
                    let dx = point.x - start.x, dy = point.y - start.y
                    update(id) {
                        $0.a = CGPoint(x: a.x + dx, y: a.y + dy)
                        $0.b = CGPoint(x: b.x + dx, y: b.y + dy)
                    }
                case .resize(let id, let fixed, let wallEnd):
                    update(id) {
                        if wallEnd == 0 { $0.a = point } else if wallEnd == 1 { $0.b = point } else {
                            $0.a = fixed
                            $0.b = point
                        }
                    }
                }
            }
            .onEnded { _ in
                if case .create(let id) = dragMode {
                    if robot.draftZones.first(where: { $0.id == id })?.isUsable != true {
                        robot.draftZones.removeAll { $0.id == id }
                        robot.selectedZoneID = nil
                    }
                    robot.zoneTool = nil
                }
                dragMode = nil
            }
    }

    private func startDrag(at location: CGPoint, _ transform: MapTransform) -> ZoneDragMode {
        // 1. A handle of the selected zone → resize.
        if let selected = robot.draftZones.first(where: { $0.id == robot.selectedZoneID }) {
            let handles = transform.handles(selected)
            if let index = handles.firstIndex(where: { hypot($0.x - location.x, $0.y - location.y) <= 9 }) {
                if selected.kind == .wall { return .resize(selected.id, fixed: .zero, wallEnd: index) }
                return .resize(selected.id, fixed: transform.mm(handles[(index + 2) % 4]), wallEnd: nil)
            }
        }
        // 2. A drawing tool → new zone.
        if let tool = robot.zoneTool {
            let start = transform.mm(location)
            let zone = EditableZone(kind: tool, a: start, b: start)
            robot.draftZones.append(zone)
            robot.selectedZoneID = zone.id
            return .create(zone.id)
        }
        // 3. An existing zone → select and move.
        if let hit = robot.draftZones.last(where: { transform.contains($0, location) }) {
            robot.selectedZoneID = hit.id
            return .move(hit.id, a: hit.a, b: hit.b, start: transform.mm(location))
        }
        robot.selectedZoneID = nil
        return .idle
    }

    /// Room editing: a click selects rooms; in Divide mode, a drag draws the dividing line.
    private func roomEditDrag(map: VacuumMap, scale: CGFloat) -> some Gesture {
        let transform = MapTransform(map: map, scale: scale)
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height) > 4
                if moved, robot.roomEditTool == .divide, !robot.selectedRooms.isEmpty {
                    robot.divideLine = (transform.mm(value.startLocation), transform.mm(value.location))
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 4
                if !moved, let id = room(at: value.location, map: map, scale: scale) {
                    robot.toggle(room: id)
                }
            }
    }

    /// Just outside the zone's top-right corner, or beside the middle of a wall; kept inside the map.
    private func deleteButtonPosition(_ zone: EditableZone, _ transform: MapTransform, in size: CGSize) -> CGPoint {
        let point: CGPoint
        if zone.kind == .wall {
            let a = transform.view(zone.a), b = transform.view(zone.b)
            let length = max(hypot(b.x - a.x, b.y - a.y), 1)
            // Perpendicular offset, flipped so it points up/right of the line.
            var nx = -(b.y - a.y) / length, ny = (b.x - a.x) / length
            if ny > 0 || (ny == 0 && nx < 0) { nx = -nx; ny = -ny }
            point = CGPoint(x: (a.x + b.x) / 2 + nx * 22, y: (a.y + b.y) / 2 + ny * 22)
        } else {
            let r = transform.viewRect(zone)
            point = CGPoint(x: r.maxX + 16, y: r.minY - 16)
        }
        return CGPoint(x: min(max(point.x, 14), size.width - 14), y: min(max(point.y, 14), size.height - 14))
    }

    /// Furniture editing: drag the selected item's corner to resize it, click an item to select it and drag it,
    /// or with a kind chosen, click empty map to place one.
    private func furnitureGesture(_ transform: MapTransform, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if furnitureDrag == nil { furnitureDrag = startFurnitureDrag(at: value.startLocation, transform) }
                switch furnitureDrag {
                case .move(let id, let grab):
                    let point = CGPoint(x: min(max(value.location.x + grab.width, 0), size.width),
                                        y: min(max(value.location.y + grab.height, 0), size.height))
                    robot.moveFurniture(id, to: transform.mm(point))
                case .resize(let id, let center):
                    // The corner follows the pointer; the item stays centered where it is.
                    let side = 2 * max(abs(value.location.x - center.x), abs(value.location.y - center.y))
                    robot.resizeFurniture(id, to: Double(side / transform.points(1)))
                case .idle, nil:
                    break
                }
            }
            .onEnded { _ in
                if case .idle = furnitureDrag {} else if furnitureDrag != nil { robot.saveFurniture() }
                furnitureDrag = nil
            }
    }

    private func startFurnitureDrag(at location: CGPoint, _ transform: MapTransform) -> FurnitureDragMode {
        if let selected = robot.furniture.first(where: { $0.id == robot.selectedFurnitureID }) {
            let handle = resizeHandlePosition(selected, transform)
            if hypot(handle.x - location.x, handle.y - location.y) <= 10 {
                return .resize(selected.id, center: transform.view(selected.point))
            }
        }
        if let hit = furniture(at: location, transform) {
            let center = transform.view(hit.point)
            robot.selectedFurnitureID = hit.id
            return .move(hit.id, grab: CGSize(width: center.x - location.x, height: center.y - location.y))
        }
        if let tool = robot.furnitureTool {
            let item = robot.placeFurniture(tool, at: transform.mm(location))
            robot.furnitureTool = nil
            return .move(item.id, grab: .zero)  // keep dragging to fine-tune where it lands
        }
        robot.selectedFurnitureID = nil
        return .idle
    }

    /// Edge length on screen: its real size, but never too small to read or click.
    private func side(_ item: Furniture, _ transform: MapTransform) -> CGFloat {
        max(FurniturePin.minimumSide, transform.points(item.size))
    }

    private func resizeHandlePosition(_ item: Furniture, _ transform: MapTransform) -> CGPoint {
        let center = transform.view(item.point), half = side(item, transform) / 2
        return CGPoint(x: center.x + half, y: center.y + half)
    }

    /// The topmost item under a point in view coordinates (its footprint, plus a little slack).
    private func furniture(at location: CGPoint, _ transform: MapTransform) -> Furniture? {
        robot.furniture.last { item in
            let center = transform.view(item.point), reach = side(item, transform) / 2 + 3
            return abs(center.x - location.x) <= reach && abs(center.y - location.y) <= reach
        }
    }

    private func update(_ id: UUID, _ change: (inout EditableZone) -> Void) {
        guard let index = robot.draftZones.firstIndex(where: { $0.id == id }) else { return }
        change(&robot.draftZones[index])
    }

    var body: some View {
        if let map = robot.displayMap, let image = robot.mapImage {
            GeometryReader { geometry in
                let area = available(in: geometry.size)
                let fit = min(area.width / CGFloat(map.width), area.height / CGFloat(map.height))
                let scale = fit * robot.mapZoom
                let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)

                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: size.width, height: size.height)
                            .id(robot.selectedRooms)
                            .transition(.opacity)

                        // Selected rooms lift slightly above the map.
                        ForEach(robot.selectedRooms.sorted(), id: \.self) { id in
                            if let roomImage = robot.roomImages[id], let center = robot.roomCenters[id] {
                                let anchor = UnitPoint(x: center.x / CGFloat(map.width), y: center.y / CGFloat(map.height))
                                let glow = colorScheme == .dark ? Color(nsColor: MapRenderer.color(forRoom: id)) : nil
                                Image(decorative: roomImage, scale: 1)
                                    .resizable()
                                    .interpolation(.none)
                                    .frame(width: size.width, height: size.height)
                                    .transition(.modifier(active: RoomLift(lifted: false, anchor: anchor, glow: glow),
                                                          identity: RoomLift(lifted: true, anchor: anchor, glow: glow)))
                                    .allowsHitTesting(false)
                            }
                        }

                        if robot.isEditingZones {
                            let transform = MapTransform(map: map, scale: scale)
                            ZoneEditorOverlay(transform: transform, zones: robot.draftZones, selectedID: robot.selectedZoneID)
                                .frame(width: size.width, height: size.height)
                                .allowsHitTesting(false)
                            if let selected = robot.draftZones.first(where: { $0.id == robot.selectedZoneID }), dragMode == nil {
                                Button {
                                    robot.deleteSelectedZone()
                                } label: {
                                    Image(systemName: "trash.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                                }
                                .buttonStyle(.plain)
                                .help("Delete this \(selected.kind == .wall ? "wall" : "zone")")
                                .accessibilityLabel("Delete \(selected.kind.name)")
                                .position(deleteButtonPosition(selected, transform, in: size))
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                                .id(selected.id)
                            }
                        } else {
                            ZonesOverlay(map: map, scale: scale, showZones: showZones, showCarpets: showCarpets)
                                .frame(width: size.width, height: size.height)
                                .allowsHitTesting(false)
                        }

                        ForEach(visibleLabels, id: \.self) { id in
                            if let center = robot.roomCenters[id] {
                                RoomMapLabel(id: id)
                                    .position(x: center.x * scale, y: center.y * scale)
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                        }

                        if robot.isEditingRooms, let line = robot.divideLine {
                            DivideLineOverlay(transform: MapTransform(map: map, scale: scale), line: line)
                                .frame(width: size.width, height: size.height)
                                .allowsHitTesting(false)
                        }

                        if showPath {
                            PathOverlay(transform: MapTransform(map: map, scale: scale), path: robot.robotPath)
                                .frame(width: size.width, height: size.height)
                                .allowsHitTesting(false)
                        }

                        // Above the path, so the route never covers an icon.
                        if showFurniture || robot.isEditingFurniture {
                            let transform = MapTransform(map: map, scale: scale)
                            ForEach(robot.furniture) { item in
                                let selected = robot.isEditingFurniture && item.id == robot.selectedFurnitureID
                                let itemSide = side(item, transform)
                                FurniturePin(item: item, isSelected: selected, side: itemSide)
                                    .overlay(alignment: .top) {
                                        if hoveredFurniture == item.id && !selected {
                                            Text(item.displayName)
                                                .font(.caption.weight(.medium))
                                                .fixedSize()
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .glassEffect(in: .capsule)
                                                .offset(y: -(itemSide / 2 + 16))
                                                .transition(.opacity.combined(with: .offset(y: 4)))
                                        }
                                    }
                                    .position(transform.view(item.point))
                                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                                    .allowsHitTesting(false)
                            }
                            if robot.isEditingFurniture, let selected = robot.furniture.first(where: { $0.id == robot.selectedFurnitureID }) {
                                FurnitureResizeHandle()
                                    .position(resizeHandlePosition(selected, transform))
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                                    .allowsHitTesting(false)
                                    .id(selected.id)
                            }
                        }

                        marker(map, at: map.header.charger, color: .green, systemImage: "bolt.fill", scale: scale, pulsing: false,
                               lit: [6, 13].contains(robot.int(Spec.status) ?? 0))
                        robotMarker(map, scale: scale)
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    // Only one gesture is active at a time, so a quick click is never swallowed by the other.
                    .gesture(SpatialTapGesture().onEnded { value in
                        if let id = room(at: value.location, map: map, scale: scale) { robot.toggle(room: id) }
                    }, isEnabled: !robot.isEditingZones && !robot.isEditingRooms && !robot.isEditingFurniture)
                    .gesture(roomEditDrag(map: map, scale: scale), isEnabled: robot.isEditingRooms)
                    .gesture(zoneDrag(MapTransform(map: map, scale: scale)), isEnabled: robot.isEditingZones)
                    .gesture(furnitureGesture(MapTransform(map: map, scale: scale), in: size), isEnabled: robot.isEditingFurniture)
                    .focusable(robot.isEditingZones || robot.isEditingFurniture)
                    .focusEffectDisabled()
                    .onDeleteCommand {
                        if robot.isEditingZones { robot.deleteSelectedZone() }
                        if robot.isEditingFurniture { robot.deleteSelectedFurniture() }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let item = (showFurniture || robot.isEditingFurniture)
                                ? furniture(at: location, MapTransform(map: map, scale: scale)) : nil
                            hoveredFurniture = item?.id
                            hoveredRoom = item == nil ? room(at: location, map: map, scale: scale) : nil
                        case .ended:
                            hoveredRoom = nil
                            hoveredFurniture = nil
                        }
                    }
                    // Centered while it fits; scrollable once zoomed in.
                    .frame(width: max(size.width, area.width), height: max(size.height, area.height))
                    .padding(margins)
                    .contentShape(Rectangle())
                    .simultaneousGesture(pinchToZoom)
                    .animation(reduceMotion ? .smooth(duration: 0.2) : .spring(duration: 0.45, bounce: 0.3), value: robot.selectedRooms)
                    .animation(.smooth(duration: 0.2), value: hoveredRoom)
                    .animation(.smooth(duration: 0.2), value: hoveredFurniture)
                    .animation(.spring(duration: 0.3, bounce: 0.35), value: robot.selectedFurnitureID)
                    .animation(.smooth(duration: 0.3), value: robot.furniture.count)
                    .animation(.smooth(duration: 0.3), value: showFurniture)
                    .animation(.smooth(duration: 0.3), value: showRoomNames)
                    .animation(.smooth(duration: 0.3), value: showZones)
                    .animation(.smooth(duration: 0.3), value: showCarpets)
                    .animation(.spring(duration: 0.3, bounce: 0.3), value: robot.selectedZoneID)
                }
                .scrollPosition($scrollPosition)
                .scrollDisabled(robot.mapZoom <= 1)
                .scrollIndicators(.never)  // like Maps; Zoom to Fit is always one click away
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                    scrollGeometry = geometry
                    // Caught up with the zoom, or scrolled far by hand: trust the scroll view again.
                    if let requested = requestedOffset {
                        let distance = hypot(geometry.contentOffset.x - requested.x, geometry.contentOffset.y - requested.y)
                        if distance < 0.5 || distance > 200 { requestedOffset = nil }
                    }
                }
                .onChange(of: robot.mapZoom) { old, new in
                    keepAnchorInPlace(from: old, to: new, map: map, viewport: geometry.size)
                }
            }
        }
    }

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch == nil { pinch = (robot.mapZoom, value.startLocation) }
                if let pinch { robot.setMapZoom(pinch.startZoom * value.magnification) }
            }
            .onEnded { _ in pinch = nil }
    }

    /// The part of the view the whole map should fit in.
    private func available(in size: CGSize) -> CGSize {
        CGSize(width: max(size.width - margins.leading - margins.trailing, 1),
               height: max(size.height - margins.top - margins.bottom, 1))
    }

    /// After a zoom, scrolls so the anchor (the pinch point, or the middle of the map area) stays where it was
    /// on screen. The margins are padding inside the scroll content, so content coordinates include them.
    private func keepAnchorInPlace(from old: CGFloat, to new: CGFloat, map: VacuumMap, viewport: CGSize) {
        guard old != new, old > 0, let geometry = scrollGeometry else { return }
        let area = available(in: viewport)
        let fit = min(area.width / CGFloat(map.width), area.height / CGFloat(map.height))
        func content(_ zoom: CGFloat) -> CGSize {
            let c = CGSize(width: CGFloat(map.width) * fit * zoom, height: CGFloat(map.height) * fit * zoom)
            return CGSize(width: max(c.width, area.width), height: max(c.height, area.height))
        }
        // Where the map starts inside the scroll content: after the margins, centered while smaller than the area.
        func origin(_ zoom: CGFloat) -> CGPoint {
            let c = CGSize(width: CGFloat(map.width) * fit * zoom, height: CGFloat(map.height) * fit * zoom)
            return CGPoint(x: margins.leading + max(0, (area.width - c.width) / 2),
                           y: margins.top + max(0, (area.height - c.height) / 2))
        }
        let offset = requestedOffset ?? geometry.contentOffset
        let insets = geometry.contentInsets, container = geometry.containerSize
        // The middle of the area the map is shown in, in content coordinates. At rest the offset is minus the
        // insets (the title bar), so the insets come back in here.
        let middle = CGPoint(x: offset.x + insets.leading + margins.leading + area.width / 2,
                             y: offset.y + insets.top + margins.top + area.height / 2)
        let anchor = pinch?.anchor ?? middle
        let o = origin(old), n = origin(new), k = new / old
        let moved = CGPoint(x: n.x + (anchor.x - o.x) * k, y: n.y + (anchor.y - o.y) * k)
        let c = content(new)
        let total = CGSize(width: c.width + margins.leading + margins.trailing, height: c.height + margins.top + margins.bottom)
        let target = CGPoint(
            x: min(max(moved.x - (anchor.x - offset.x), -insets.leading), max(total.width + insets.trailing - container.width, -insets.leading)),
            y: min(max(moved.y - (anchor.y - offset.y), -insets.top), max(total.height + insets.bottom - container.height, -insets.top)))
        // scrollTo(point:) counts from the content's edge, without the insets the offset includes.
        let point = CGPoint(x: target.x + insets.leading, y: target.y + insets.top)
        // In the same update as the new size, so each frame of the zoom lands in place without a jump.
        scrollPosition.scrollTo(point: point)
        requestedOffset = target
        if let pinch { self.pinch = (pinch.startZoom, moved) }  // the next pinch step continues from here
    }

    /// Names on request or hover; rooms that are selected or have their own settings always show theirs.
    private var visibleLabels: [Int] {
        var ids = showRoomNames ? Set(robot.roomCenters.keys) : Set(hoveredRoom.map { [$0] } ?? [])
        ids.formUnion(robot.selectedRooms)
        ids.formUnion(robot.roomPreferences.keys)
        return ids.filter { robot.roomCenters[$0] != nil }.sorted()
    }

    private func room(at location: CGPoint, map: VacuumMap, scale: CGFloat) -> Int? {
        let x = Int(location.x / scale)
        let y = map.height - 1 - Int(location.y / scale)
        if case .room(let id) = map.cell(x: x, y: y) { return id }
        return nil
    }

    /// The robot: glides to each live position, with an arrow for its heading.
    private func robotMarker(_ map: VacuumMap, scale: CGFloat) -> some View {
        let position = robot.robotPosition ?? map.header.robot
        let pixel = map.pixel(for: position)
        // Robot angle is counter-clockwise from the map's +x axis; the arrow symbol points up.
        let rotation = Angle.degrees(90 - Double(robot.robotAngle ?? 90))
        return ZStack {
            if robot.isBusy && !reduceMotion {
                Circle()
                    .fill(Color.red.opacity(0.35))
                    .phaseAnimator([false, true]) { circle, expanded in
                        circle.scaleEffect(expanded ? 2.4 : 1).opacity(expanded ? 0 : 1)
                    } animation: { _ in .easeOut(duration: 1.4) }
            }
            Circle()
                .fill(Color.red.gradient)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .ledGlow(.red, radius: 10, isOn: robot.isBusy || colorScheme == .dark)
            Image(systemName: robot.livePosition != nil ? "location.north.fill" : "circle.fill")
                .font(.system(size: robot.livePosition != nil ? 9 : 6, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(robot.livePosition != nil ? rotation : .zero)
        }
        .frame(width: 20, height: 20)
        .position(x: pixel.x * scale, y: (CGFloat(map.height - 1) - pixel.y) * scale)
        .animation(reduceMotion ? nil : .linear(duration: robot.liveFrameInterval), value: position)
        .animation(.smooth(duration: 0.5), value: robot.robotAngle)
        .allowsHitTesting(false)
    }

    private func marker(_ map: VacuumMap, at position: CGPoint, color: Color, systemImage: String,
                        scale: CGFloat, pulsing: Bool, lit: Bool = false) -> some View {
        let pixel = map.pixel(for: position)
        return ZStack {
            if pulsing && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.35))
                    .phaseAnimator([false, true]) { circle, expanded in
                        circle.scaleEffect(expanded ? 2.4 : 1).opacity(expanded ? 0 : 1)
                    } animation: { _ in .easeOut(duration: 1.4) }
            }
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(color, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .ledGlow(color, radius: 8, isOn: lit)
        }
        .frame(width: 18, height: 18)
        .position(x: pixel.x * scale, y: (CGFloat(map.height - 1) - pixel.y) * scale)
        .allowsHitTesting(false)
    }
}

/// A selected room grows a little around its own center and casts a soft shadow.
/// In Dark Mode it glows in its own color instead, like a lit tile.
private struct RoomLift: ViewModifier {
    let lifted: Bool
    let anchor: UnitPoint
    var glow: Color?

    func body(content: Content) -> some View {
        content
            .scaleEffect(lifted ? 1.06 : 1, anchor: anchor)
            .shadow(color: (glow ?? .black).opacity(lifted ? (glow == nil ? 0.28 : 0.3) : 0),
                    radius: lifted ? 8 : 0, y: lifted && glow == nil ? 4 : 0)
            .opacity(lifted ? 1 : 0)
    }
}

/// Virtual walls, no-go and no-mop zones, and carpets, drawn in one Canvas pass.
private struct ZonesOverlay: View {
    let map: VacuumMap
    let scale: CGFloat
    let showZones: Bool
    let showCarpets: Bool

    var body: some View {
        Canvas { context, _ in
            func point(_ mm: CGPoint) -> CGPoint {
                let pixel = map.pixel(for: mm)
                return CGPoint(x: pixel.x * scale, y: (CGFloat(map.height - 1) - pixel.y) * scale)
            }
            func rect(_ mm: CGRect) -> CGRect {
                let a = point(CGPoint(x: mm.minX, y: mm.minY)), b = point(CGPoint(x: mm.maxX, y: mm.maxY))
                return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            }

            if showCarpets {
                for carpet in map.zones.carpets {
                    let path = Path(roundedRect: rect(carpet), cornerRadius: 3)
                    context.fill(path, with: .color(.brown.opacity(0.12)))
                    context.stroke(path, with: .color(.brown.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            guard showZones else { return }
            for zone in map.zones.noMop {
                let path = Path(roundedRect: rect(zone), cornerRadius: 3)
                context.fill(path, with: .color(.blue.opacity(0.18)))
                context.stroke(path, with: .color(.blue), lineWidth: 2)
            }
            for zone in map.zones.noGo {
                let r = rect(zone)
                let path = Path(roundedRect: r, cornerRadius: 3)
                context.fill(path, with: .color(.red.opacity(0.18)))
                // Diagonal hatching, clipped to the zone.
                var hatch = Path()
                var x = r.minX - r.height
                while x < r.maxX {
                    hatch.move(to: CGPoint(x: x, y: r.maxY))
                    hatch.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                    x += 8
                }
                context.drawLayer { layer in
                    layer.clip(to: path)
                    layer.stroke(hatch, with: .color(.red.opacity(0.35)), lineWidth: 1)
                }
                context.stroke(path, with: .color(.red), lineWidth: 2)
            }
            for (start, end) in map.zones.virtualWalls {
                var line = Path()
                line.move(to: point(start))
                line.addLine(to: point(end))
                context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                context.stroke(line, with: .color(.red), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }
        }
    }
}

/// Draft zones while editing, with the selected one highlighted and its handles shown.
private struct ZoneEditorOverlay: View {
    let transform: MapTransform
    let zones: [EditableZone]
    let selectedID: UUID?

    var body: some View {
        Canvas { context, _ in
            for zone in zones {
                let selected = zone.id == selectedID
                let color: Color = zone.kind == .noMop ? .blue : .red
                if zone.kind == .wall {
                    var line = Path()
                    line.move(to: transform.view(zone.a))
                    line.addLine(to: transform.view(zone.b))
                    context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: selected ? 8 : 6, lineCap: .round))
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: selected ? 5 : 3.5, lineCap: .round))
                } else {
                    let path = Path(roundedRect: transform.viewRect(zone), cornerRadius: 3)
                    context.fill(path, with: .color(color.opacity(selected ? 0.3 : 0.18)))
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: selected ? 3 : 2, dash: selected ? [6, 3] : []))
                }
                if selected {
                    for handle in transform.handles(zone) {
                        let dot = Path(ellipseIn: CGRect(x: handle.x - 6, y: handle.y - 6, width: 12, height: 12))
                        context.fill(dot, with: .color(.white))
                        context.stroke(dot, with: .color(.accentColor), lineWidth: 2.5)
                    }
                }
            }
        }
    }
}

/// Glass toolbar shown over the map while editing zones.
private struct ZoneEditToolbar: View {
    @Environment(RobotController.self) private var robot
    @State private var confirmingRestore = false

    var body: some View {
        @Bindable var robot = robot
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(EditableZone.Kind.allCases, id: \.self) { kind in
                        Button {
                            robot.zoneTool = robot.zoneTool == kind ? nil : kind
                            robot.selectedZoneID = nil
                        } label: {
                            Label(kind.name, systemImage: kind.systemImage)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(robot.zoneTool == kind ? Color.accentColor.opacity(0.25) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Draw a \(kind.name.lowercased()) \(kind == .wall ? "" : "zone")")
                    }
                }
                .padding(3)
                .glassEffect(in: .capsule)

                if robot.hasZoneBackup {
                    Button("Restore previous", systemImage: "clock.arrow.circlepath") { confirmingRestore = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .help("Put back the zones from before the last save")
                }

                Button("Cancel") { robot.cancelEditingZones() }
                    .buttonStyle(.glass)
                Button {
                    Task { await robot.saveZones() }
                } label: {
                    if robot.isSavingZones { ProgressView().controlSize(.small) } else { Text("Save to robot") }
                }
                .buttonStyle(.glassProminent)
                .disabled(!robot.hasUnsavedZoneChanges || robot.isSavingZones)
            }
        }
        .animation(.smooth(duration: 0.25), value: robot.zoneTool)
        .confirmationDialog("Restore the zones from before your last save?", isPresented: $confirmingRestore) {
            Button("Restore") { Task { await robot.restorePreviousZones() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the robot's current walls and zones.")
        }
    }
}

/// The route the robot has driven, as a soft line.
/// At night it's a faint lit trail instead.
private struct PathOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let transform: MapTransform
    let path: [VacuumMap.PathPoint]

    var body: some View {
        Canvas { context, _ in
            var line = Path()
            for point in path {
                let p = transform.view(point.point)
                if point.startsStroke || line.isEmpty { line.move(to: p) } else { line.addLine(to: p) }
            }
            if colorScheme == .dark {
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: 3))
                    glow.stroke(line, with: .color(.cyan.opacity(0.45)),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                context.stroke(line, with: .color(.white.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                return
            }
            context.stroke(line, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            context.stroke(line, with: .color(.black.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The line a room will be divided along.
private struct DivideLineOverlay: View {
    let transform: MapTransform
    let line: (CGPoint, CGPoint)

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            let a = transform.view(line.0), b = transform.view(line.1)
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 5]))
            for end in [a, b] {
                let dot = Path(ellipseIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(.white))
                context.stroke(dot, with: .color(.accentColor), lineWidth: 2)
            }
        }
    }
}

/// Glass toolbar for merging and dividing rooms on the robot's saved map.
private struct RoomEditToolbar: View {
    @Environment(RobotController.self) private var robot
    @State private var confirming: RobotController.RoomEditTool?

    var body: some View {
        @Bindable var robot = robot
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Tool", selection: $robot.roomEditTool) {
                    Label("Merge", systemImage: "square.on.square.squareshape.controlhandles").tag(RobotController.RoomEditTool.merge)
                    Label("Divide", systemImage: "scissors").tag(RobotController.RoomEditTool.divide)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)

                Button("Done") { robot.endEditingRooms() }
                    .buttonStyle(.glass)

                Button {
                    confirming = robot.roomEditTool
                } label: {
                    if robot.isSendingRoomEdit {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(robot.roomEditTool == .merge ? "Merge rooms" : "Divide room")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(robot.isSendingRoomEdit || !(robot.roomEditTool == .merge ? robot.canMerge : robot.canDivide))
            }
        }
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(confirming == .merge ? "Merge" : "Divide") {
                // Read the choice now: the dialog clears `confirming` as soon as it closes.
                let tool = confirming
                Task {
                    if tool == .merge { await robot.mergeSelectedRooms() } else if tool == .divide { await robot.divideSelectedRoom() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the robot's saved map, also in the Xiaomi app. There's no backup to restore it, but you can undo it by hand by dividing or merging again.")
        }
    }

    private var title: String {
        let names = robot.selectedRooms.sorted().map { robot.name(ofRoom: $0) }
        return confirming == .merge ? "Merge \(names.joined(separator: " and "))?" : "Divide \(names.first ?? "this room")?"
    }
}

/// Zoom buttons in the map's corner, like Maps: one capsule with + over −, and "whole house" when zoomed in.
private struct MapZoomControls: View {
    @Environment(RobotController.self) private var robot

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if robot.mapZoom > 1 {
                    button("Zoom to Fit", systemImage: "arrow.down.right.and.arrow.up.left", help: "Show the whole house (⌘0)",
                           enabled: true) { robot.zoomToFit() }
                        .glassEffect(.regular.interactive(), in: .circle)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    button("Zoom In", systemImage: "plus", help: "Zoom in (⌘=), or pinch on the trackpad",
                           enabled: robot.canZoomIn) { robot.zoomIn() }
                    Divider().frame(width: 20)
                    button("Zoom Out", systemImage: "minus", help: "Zoom out (⌘−)",
                           enabled: robot.canZoomOut) { robot.zoomOut() }
                }
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .animation(.smooth(duration: 0.25), value: robot.mapZoom > 1)
    }

    private func button(_ title: String, systemImage: String, help: String, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
    }
}

/// A room's name on the map; selected rooms and rooms with their own settings add repeats, suction and water.
private struct RoomMapLabel: View {
    @Environment(RobotController.self) private var robot
    let id: Int
    @State private var showingSettings = false
    @AppStorage("roomLabelScale") private var labelScale = 1.0

    private var showsSettings: Bool { robot.selectedRooms.contains(id) || !robot.preference(forRoom: id).isDefault }

    var body: some View {
        let effective = robot.effectivePreference(forRoom: id)
        VStack(spacing: 3) {
            Text(robot.name(ofRoom: id))
                .font(.caption.weight(.medium))
            if showsSettings {
                HStack(spacing: 8) {
                    Text("\(effective.repeats)×")
                    if effective.mode != .mop {
                        Label(SuctionLevel(rawValue: effective.suction)?.name ?? "", systemImage: "wind")
                    }
                    if effective.mode != .vacuum {
                        Label(MopLevel(rawValue: effective.water)?.name ?? "", systemImage: "drop.fill")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(in: .rect(cornerRadius: 12))
        .scaleEffect(labelScale)
        .contentShape(Rectangle())
        .allowsHitTesting(showsSettings)
        .onTapGesture { showingSettings = true }
        .popover(isPresented: $showingSettings) { RoomSettingsPopover(id: id) }
        .help(showsSettings ? "Click to change this room's cleaning settings" : "")
    }
}
