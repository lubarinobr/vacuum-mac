import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class RobotController {
    private(set) var config: RobotConfig?
    private(set) var cloud: CloudSession?
    private(set) var values: [PropertyID: Any] = [:]
    private(set) var isConnected = false
    /// Robot unreachable (from the status check); cleared as soon as it answers again.
    private(set) var connectionError: String?
    /// A command that failed; stays visible for 10 seconds or until dismissed.
    private(set) var actionError: String?
    var lastError: String? { actionError ?? connectionError }
    private var actionErrorTask: Task<Void, Never>?

    func report(_ message: String?) {
        actionErrorTask?.cancel()
        actionError = message
        guard message != nil else { return }
        actionErrorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.actionError = nil
        }
    }

    func dismissError() { report(nil) }
    private(set) var map: VacuumMap? {
        didSet {
            // Live snapshots arrive every few seconds while cleaning; most don't change what's drawn.
            if let old = oldValue, let new = map, old.header.width == new.header.width, old.header.height == new.header.height,
               old.header.left == new.header.left, old.header.top == new.header.top, old.cells == new.cells,
               var display = displayMap {
                display.zones = new.zones
                display.path = new.path
                displayMap = display
                return
            }
            rebuildMapRendering()
        }
    }
    private(set) var isLoadingMap = false
    private(set) var mapError: String?
    var selectedRooms: Set<Int> = [] {
        didSet {
            guard oldValue != selectedRooms, let display = displayMap else { return }
            mapImage = MapRenderer.image(display, selected: selectedRooms, style: mapStyle)
            // "Lift" images are made only for rooms that get selected.
            for id in selectedRooms where roomImages[id] == nil {
                roomImages[id] = MapRenderer.roomImage(display, room: id, style: mapStyle)
            }
        }
    }
    private var renderGeneration = 0
    /// Follows the window's appearance; set by the view.
    var mapStyle: MapRenderer.Style = .light {
        didSet { if oldValue != mapStyle { rebuildMapRendering() } }
    }

    /// Rooms hidden in this app only; the robot still knows them.
    private(set) var hiddenRooms: Set<Int> = AppStore.loadHiddenRooms()
    /// What's drawn: the map without hidden rooms, cropped to the visible part.
    private(set) var displayMap: VacuumMap?

    /// Hidden rooms that exist on the current map.
    var hiddenRoomsOnMap: [Int] { (map?.roomIDs ?? []).filter(hiddenRooms.contains) }

    func setHidden(_ hidden: Bool, room id: Int) {
        if hidden { hiddenRooms.insert(id) } else { hiddenRooms.remove(id) }
        AppStore.save(hiddenRooms: hiddenRooms)
        selectedRooms.remove(id)
        rebuildMapRendering()
    }

    // Derived from the map once, not on every status refresh.
    private(set) var mapImage: CGImage?
    private(set) var roomCenters: [Int: CGPoint] = [:]
    private(set) var roomAreas: [Int: Double] = [:]
    private(set) var roomImages: [Int: CGImage] = [:]
    private var valuesSignature = ""

    // Zone editing: edits stay local until saveZones().
    private(set) var isEditingZones = false
    var draftZones: [EditableZone] = []
    var selectedZoneID: UUID?
    var zoneTool: EditableZone.Kind?
    private(set) var isSavingZones = false
    private(set) var hasZoneBackup = !AppStore.loadZoneBackups().isEmpty
    private(set) var roomNames: [Int: String] = AppStore.loadRoomNames()

    private var client: MiIOClient?
    /// Its own socket, so drive commands never wait behind status polls or map requests.
    private var driveClient: MiIOClient?
    /// True while the drive pad is open; the 5-second status poll is paused so the robot isn't kept busy.
    private(set) var isDriving = false
    private var pollTask: Task<Void, Never>?
    private var lastMapLoad = Date.distantPast

    init() {
        // Unit tests launch the app too; don't talk to the real robot then.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        configure(robot: AppStore.loadRobot(), cloud: AppStore.loadCloud())
    }

    // MARK: - Setup

    func configure(robot: RobotConfig?, cloud: CloudSession?) {
        if let robot {
            AppStore.save(robot)
            config = robot
            client = Data(hex: robot.token).map { MiIOClient(ip: robot.ip, token: $0) }
            driveClient = Data(hex: robot.token).map { MiIOClient(ip: robot.ip, token: $0) }
        }
        if let cloud {
            AppStore.save(cloud)
            self.cloud = cloud
        }
        guard client != nil else { return }
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refresh()
            Task { await self?.loadMap() }  // separately, so the status check never waits for the map
            while !Task.isCancelled {
                await self?.refresh()
                // If the map failed to load (e.g. network blocked for a moment at launch), keep retrying.
                if let self, self.map == nil, !self.isLoadingMap, self.cloud != nil, self.isConnected,
                   Date().timeIntervalSince(self.lastMapLoad) > 15 {
                    Task { await self.loadMap() }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Status

    func refresh() async {
        guard let client, !isDriving else { return }
        do {
            var updated: [PropertyID: Any] = [:]
            for batch in stride(from: 0, to: Spec.polled.count, by: 10).map({ Array(Spec.polled[$0..<min($0 + 10, Spec.polled.count)]) }) {
                let request = batch.map { ["did": "\($0.siid).\($0.piid)", "siid": $0.siid, "piid": $0.piid] as [String: Any] }
                let result = try await client.send("get_properties", request) as? [[String: Any]] ?? []
                for item in result where item["code"] as? Int == 0 {
                    if let siid = item["siid"] as? Int, let piid = item["piid"] as? Int, let value = item["value"] {
                        updated[PropertyID(siid: siid, piid: piid)] = value
                    }
                }
            }
            // Only publish changes, so views (and the map) don't redraw every 5 seconds for nothing.
            let signature = updated.map { "\($0.key.siid).\($0.key.piid)=\($0.value)" }.sorted().joined(separator: ";")
            if signature != valuesSignature {
                valuesSignature = signature
                values = updated
            }
            if !isConnected { isConnected = true }
            if connectionError != nil { connectionError = nil }
            recordProblemIfNeeded()
            // Follow the robot live while it's moving.
            if isBusy { startTracking() } else { stopTracking() }
        } catch {
            if isConnected { isConnected = false }
            connectionError = error.localizedDescription
        }
    }

    /// Heavy work (hiding rooms, the image, room stats) runs off the main thread; only the result is applied here.
    private func rebuildMapRendering() {
        renderGeneration += 1
        let generation = renderGeneration
        guard let source = map else {
            displayMap = nil
            mapImage = nil
            roomCenters = [:]
            roomAreas = [:]
            roomImages = [:]
            return
        }
        let hidden = hiddenRooms
        let selected = selectedRooms
        let style = mapStyle
        Task.detached(priority: .userInitiated) {
            let display = source.hiding(rooms: hidden)
            let visibleSelection = selected.intersection(display.roomIDs)
            let image = MapRenderer.image(display, selected: visibleSelection, style: style)
            let stats = MapRenderer.roomStats(display)
            let lifted = Dictionary(uniqueKeysWithValues: visibleSelection.compactMap { id in
                MapRenderer.roomImage(display, room: id, style: style).map { (id, $0) }
            })
            await MainActor.run { [weak self] in
                guard let self, generation == self.renderGeneration else { return }  // a newer map arrived meanwhile
                self.displayMap = display
                self.roomImages = lifted
                self.roomCenters = stats.centers
                self.roomAreas = stats.areas
                self.mapImage = image
                if self.selectedRooms != visibleSelection { self.selectedRooms = visibleSelection }
            }
        }
    }

    func int(_ id: PropertyID) -> Int? { values[id] as? Int }
    func string(_ id: PropertyID) -> String? { values[id] as? String }
    func bool(_ id: PropertyID) -> Bool? { values[id] as? Bool }

    var statusText: String {
        guard let status = int(Spec.status) else { return isConnected ? "Unknown" : "Not connected" }
        return Spec.statusNames[status] ?? "Status \(status)"
    }

    var isBusy: Bool { int(Spec.status).map(Spec.busyStatuses.contains) ?? false }

    var statusSymbol: String {
        switch int(Spec.status) {
        case 4: "exclamationmark.triangle.fill"
        case 5: "house.fill"
        case 6, 13: "bolt.fill"
        case 8, 9, 10, 21: "drop.fill"
        case 22: "trash.fill"
        case 14: "arrow.down.circle.fill"
        case let status? where Spec.busyStatuses.contains(status): "sparkles"
        case nil: "wifi.slash"
        default: "pause.circle.fill"
        }
    }

    // MARK: - Commands

    func start() async { await run(Spec.startCleaning) }
    func stop() async { await run(Spec.stopCleaning) }
    func goHome() async { await run(Spec.goHome) }
    func emptyBin() async { await run(Spec.emptyBin) }
    func locate() async { await run(Spec.locate) }

    func setSuction(_ level: SuctionLevel) async { await set(Spec.suction, level.rawValue) }
    func setMop(_ level: MopLevel) async { await set(Spec.mopLevel, level.rawValue) }

    var cleaningMode: CleaningMode? { int(Spec.cleanSetting).flatMap(CleaningMode.init(packed:)) }

    func setCleaningMode(_ mode: CleaningMode) async {
        guard let current = int(Spec.cleanSetting) else { return }
        await set(Spec.cleanSetting, mode.packed(into: current))
        await refresh()  // the robot may refuse (e.g. mop pads not attached); show what it really uses
    }

    func cleanSelectedRooms() async {
        guard !selectedRooms.isEmpty else { return }
        let suction = int(Spec.suction) ?? 1
        let water = int(Spec.mopLevel) ?? 2
        let selects = selectedRooms.sorted().map { [$0, 1, suction, water, 1] }
        let data = String(decoding: try! JSONSerialization.data(withJSONObject: ["selects": selects]), as: UTF8.self)
        await run(Spec.startCustomClean, [
            ["piid": 1, "value": Spec.segmentCleaningWorkMode],
            ["piid": Spec.cleanExtendDataPiid, "value": data],
        ])
    }

    /// Manual driving. `velocity` > 0 is forward, `rotation` > 0 turns left; both 0 stands still.
    /// Returns false when the command didn't reach the robot. Send this every ~150 ms while driving.
    @discardableResult
    func drive(rotation: Int, velocity: Int) async -> Bool {
        guard let client = driveClient else { return false }
        // The first command of a session announces remote control by voice; later ones stay quiet.
        let audio = isRemoteSession ? "false" : "true"
        let payload = "{\"spdv\":\(velocity),\"spdw\":\(rotation),\"audio\":\"\(audio)\",\"random\":\(Int.random(in: 0..<65535))}"
        do {
            let result = try await client.send("set_properties", [["did": "\(Spec.remoteControl.siid).\(Spec.remoteControl.piid)",
                                                                  "siid": Spec.remoteControl.siid, "piid": Spec.remoteControl.piid,
                                                                  "value": payload] as [String: Any]],
                                                timeout: 0.3, retry: false)
            if let code = (result as? [[String: Any]])?.first?["code"] as? Int, code != 0 {
                report("The robot rejected the drive command (code \(code)). It may need to be off its dock.")
                return false
            }
            isRemoteSession = true
            driveTimeouts = 0
            if actionError != nil { report(nil) }
            return true
        } catch MiIOError.timeout {
            // A lost reply is normal while driving; the next command is already on its way. Only a long run of them is a problem.
            driveTimeouts += 1
            if driveTimeouts == 15 { report("The robot stopped answering drive commands.") }
            return false
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    func setDriving(_ driving: Bool) {
        isDriving = driving
        if driving { startTracking() }  // show the robot moving on the map
    }

    /// Leaves manual mode; the next drive command starts a new session.
    func endRemoteSession() async {
        guard isRemoteSession else { return }
        await drive(rotation: 0, velocity: 0)
        isRemoteSession = false
        await stop()
    }

    private var isRemoteSession = false
    private var driveTimeouts = 0

    private func run(_ action: ActionID, _ params: [[String: Any]] = []) async {
        guard let client else { return }
        do {
            let result = try await client.send("action", ["did": "\(action.siid).\(action.aiid)", "siid": action.siid,
                                                          "aiid": action.aiid, "in": params] as [String: Any])
            if let code = (result as? [String: Any])?["code"] as? Int, code != 0 {
                report("The robot rejected the command (code \(code)).")
            } else {
                report(nil)
            }
        } catch {
            report(error.localizedDescription)
        }
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    private func set(_ property: PropertyID, _ value: Any) async {
        guard let client else { return }
        do {
            _ = try await client.send("set_properties", [["did": "\(property.siid).\(property.piid)", "siid": property.siid,
                                                          "piid": property.piid, "value": value] as [String: Any]])
            values[property] = value
        } catch {
            report(error.localizedDescription)
        }
    }

    // MARK: - Live tracking

    /// Live robot position/heading from partial map frames; nil when not tracking.
    private(set) var livePosition: CGPoint?
    private(set) var liveAngle: Int?
    private(set) var livePath: [VacuumMap.PathPoint] = []
    /// Seconds between the last two live frames; the robot dot glides over this long.
    private(set) var liveFrameInterval: Double = 1.3
    private var lastLiveFrameAt: Date?
    private var trackingTask: Task<Void, Never>?

    var robotPosition: CGPoint? { livePosition ?? map?.header.robot }
    var robotAngle: Int? { liveAngle ?? map?.header.robotAngle }
    var robotPath: [VacuumMap.PathPoint] { livePath.isEmpty ? (map?.path ?? []) : livePath }

    private func startTracking() {
        guard trackingTask == nil else { return }
        trackingTask = Task { [weak self] in await self?.track() }
    }

    private func stopTracking() {
        guard let task = trackingTask else { return }
        task.cancel()
        trackingTask = nil
        Task {
            await loadMap()  // final picture of where the robot ended up
            livePosition = nil
            liveAngle = nil
            livePath = []
            lastLiveFrameAt = nil
        }
    }

    /// Asks for the next partial frame every 1.5 s. Partial frames come back over the local network;
    /// when the robot uploads a keyframe instead, it is downloaded from the EU cloud.
    private func track() async {
        if map == nil { await loadMap() }
        livePath = map?.path ?? []
        var nextFrame = (map?.header.frameID ?? 0) + 1
        var lastFrameReceived = Date()

        // The robot makes a new frame about every 1.3 s; asking every 0.5 s shows it within half a second.
        while !Task.isCancelled, let client {
            guard let map else {
                // No map yet (e.g. the robot was busy at launch): keep trying.
                try? await Task.sleep(for: .seconds(3))
                await loadMap()
                nextFrame = (self.map?.header.frameID ?? 0) + 1
                continue
            }
            do {
                let request = "{\"map_id\":\(map.header.mapID),\"req_type\":1,\"frame_id\":\(nextFrame),\"frame_type\":\"P\"}"
                let reply = try await client.send("action", [
                    "did": "6.1", "siid": 6, "aiid": 1, "in": [["piid": Spec.mapFrameInfoPiid, "value": request]],
                ] as [String: Any]) as? [String: Any]
                let out = reply?["out"] as? [[String: Any]] ?? []
                let inline = out.first(where: { $0["piid"] as? Int == 1 })?["value"] as? String ?? ""
                let objectName = out.first(where: { $0["piid"] as? Int == Spec.mapObjectNamePiid })?["value"] as? String ?? ""

                if !inline.isEmpty {
                    let frame = try MapDecoder.decodeFrame(inline, key: nil)
                    applyLiveFrame(frame.header, extra: frame.extra)
                    nextFrame = frame.header.frameID + 1
                    lastFrameReceived = Date()
                } else if !objectName.isEmpty, let cloud {
                    let parts = objectName.split(separator: ",", maxSplits: 1).map(String.init)
                    let xiaomi = XiaomiCloud(session: cloud)
                    let raw = try await xiaomi.download(try await xiaomi.mapFileURL(objectName: parts[0]))
                    let key = parts.count > 1 ? parts[1] : nil
                    let keyframe = try await Task.detached { try MapDecoder.decode(raw, key: key) }.value
                    self.map = keyframe
                    livePosition = keyframe.header.robot
                    liveAngle = keyframe.header.robotAngle
                    livePath = keyframe.path
                    nextFrame = keyframe.header.frameID + 1
                    lastFrameReceived = Date()
                }
            } catch {
                // Transient network hiccup: keep going; the resync below covers longer gaps.
            }
            if Date().timeIntervalSince(lastFrameReceived) > 12 {  // no frames for a while: resync with a fresh full map
                await loadMap()
                nextFrame = (self.map?.header.frameID ?? nextFrame) + 1
                lastFrameReceived = Date()
            }
            try? await Task.sleep(for: .seconds(0.5))
        }
    }

    private func applyLiveFrame(_ header: VacuumMap.Header, extra: [String: Any]) {
        let now = Date()
        if let last = lastLiveFrameAt {
            // Smoothed, and kept in a sensible range so one late frame doesn't make the dot crawl.
            liveFrameInterval = min(max(liveFrameInterval * 0.7 + now.timeIntervalSince(last) * 0.3, 0.4), 2)
        }
        lastLiveFrameAt = now
        livePosition = header.robot
        liveAngle = header.robotAngle
        if let trace = extra["tr"] as? String {
            let continuing = trace.hasPrefix("l")
            let points = MapDecoder.path(from: trace, continuingFrom: continuing ? livePath.last?.point : nil)
            livePath.append(contentsOf: points)
        }
    }

    // MARK: - Map

    func loadMap() async {
        guard let client, !isLoadingMap else { return }
        guard let cloud else {
            mapError = "Sign in to Xiaomi to load the map."
            return
        }
        isLoadingMap = true
        defer { isLoadingMap = false }
        // A docked robot is often asleep: the first request times out, or it answers before the map file
        // has reached the cloud. Retry a few times (staying on "Loading map…") before showing an error.
        let retryDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]
        for attempt in 0...retryDelays.count {
            lastMapLoad = Date()
            do {
                map = try await fetchMap(client: client, cloud: cloud)
                mapError = nil
                return
            } catch CloudError.loginExpired {
                mapError = CloudError.loginExpired.localizedDescription  // retrying won't help
                return
            } catch {
                guard attempt < retryDelays.count, !Task.isCancelled else {
                    mapError = error.localizedDescription
                    return
                }
                try? await Task.sleep(for: retryDelays[attempt])
            }
        }
    }

    private func fetchMap(client: MiIOClient, cloud: CloudSession) async throws -> VacuumMap {
        let xiaomi = XiaomiCloud(session: cloud)
        var objectName = ""
        do {
            let request = "{\"req_type\":1,\"frame_type\":\"I\",\"force_type\":1}"
            let reply = try await client.send("action", [
                "did": "\(Spec.requestMap.siid).\(Spec.requestMap.aiid)", "siid": Spec.requestMap.siid,
                "aiid": Spec.requestMap.aiid, "in": [["piid": Spec.mapFrameInfoPiid, "value": request]],
            ] as [String: Any]) as? [String: Any]
            let out = reply?["out"] as? [[String: Any]] ?? []
            objectName = out.first(where: { $0["piid"] as? Int == Spec.mapObjectNamePiid })?["value"] as? String ?? ""
        } catch {
            // The robot didn't answer (asleep on the dock, busy…); fall back to its latest uploaded map below.
            guard config?.did != nil else { throw error }
        }
        if objectName.isEmpty, let did = config?.did {
            // While cleaning, the robot often doesn't answer directly; use its latest uploaded map.
            objectName = try await xiaomi.lastMapObjectName(did: did) ?? ""
        }
        guard !objectName.isEmpty else { throw MapLoadError.noMap }
        let parts = objectName.split(separator: ",", maxSplits: 1).map(String.init)
        let raw = try await xiaomi.download(try await xiaomi.mapFileURL(objectName: parts[0]))
        let key = parts.count > 1 ? parts[1] : nil
        return try await Task.detached { try MapDecoder.decode(raw, key: key) }.value
    }

    private enum MapLoadError: LocalizedError {
        case noMap
        var errorDescription: String? { "The robot didn't send a map." }
    }

    // MARK: - Zones

    var hasUnsavedZoneChanges: Bool {
        guard let map else { return false }
        return ZoneEditing.payload(for: ZoneEditing.zones(from: draftZones, keepingCarpetsOf: map.zones))
            != ZoneEditing.payload(for: map.zones)
    }

    func beginEditingZones() {
        guard let map else { return }
        endEditingRooms()
        endEditingFurniture()
        draftZones = ZoneEditing.editable(from: map.zones)
        selectedZoneID = nil
        zoneTool = nil
        selectedRooms = []
        isEditingZones = true
    }

    func cancelEditingZones() {
        isEditingZones = false
        draftZones = []
        selectedZoneID = nil
        zoneTool = nil
    }

    func deleteSelectedZone() {
        draftZones.removeAll { $0.id == selectedZoneID }
        selectedZoneID = nil
    }

    /// Sends the complete set of walls/no-go/no-mop zones to the robot, after backing up the current set.
    func saveZones() async {
        guard let map else { return }
        let newZones = ZoneEditing.zones(from: draftZones, keepingCarpetsOf: map.zones)
        let previous = ZoneEditing.payload(for: map.zones)
        AppStore.appendZoneBackup(previous)
        hasZoneBackup = true
        if await sendZones(ZoneEditing.payload(for: newZones)) {
            self.map?.zones = newZones
            cancelEditingZones()
            await confirmZonesFromRobot()
        } else {
            AppStore.removeLastZoneBackup()
            hasZoneBackup = !AppStore.loadZoneBackups().isEmpty
        }
    }

    /// Puts back the zones from before the last save.
    func restorePreviousZones() async {
        guard let backup = AppStore.loadZoneBackups().last else { return }
        if await sendZones(backup.vw) {
            AppStore.removeLastZoneBackup()
            hasZoneBackup = !AppStore.loadZoneBackups().isEmpty
            cancelEditingZones()
            await confirmZonesFromRobot()
        }
    }

    private func sendZones(_ vw: [String: [[Int]]]) async -> Bool {
        guard let client else { return false }
        isSavingZones = true
        defer { isSavingZones = false }
        do {
            let value = String(decoding: try JSONSerialization.data(withJSONObject: ["vw": vw]), as: UTF8.self)
            let reply = try await client.send("action", [
                "did": "6.2", "siid": 6, "aiid": 2, "in": [["piid": 4, "value": value]],
            ] as [String: Any]) as? [String: Any]
            let resultCode = (reply?["out"] as? [[String: Any]])?.first(where: { $0["piid"] as? Int == 6 })?["value"] as? Int
            guard reply?["code"] as? Int == 0, resultCode ?? 0 == 0 else {
                report("The robot didn't accept the zones (code \(resultCode ?? reply?["code"] as? Int ?? -1)).")
                return false
            }
            report(nil)
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    private func confirmZonesFromRobot() async {
        try? await Task.sleep(for: .seconds(3))  // give the robot time to save before reading the map back
        await loadMap()
    }

    // MARK: - Map zoom (only how the map is shown)

    /// 1 = the whole map fits the window.
    static let zoomRange: ClosedRange<CGFloat> = 1...8
    private(set) var mapZoom: CGFloat = 1
    /// Where the buttons are taking the zoom; clicks during an animation build on it.
    private var zoomTarget: CGFloat = 1
    private var zoomAnimation: Task<Void, Never>?

    private func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// Follows a pinch directly, frame by frame.
    func setMapZoom(_ zoom: CGFloat) {
        zoomAnimation?.cancel()
        mapZoom = clampedZoom(zoom)
        zoomTarget = mapZoom
    }

    /// Glides to a zoom level (ease-out, about a quarter second), like Maps; jumps when Reduce Motion is on.
    func animateZoom(to zoom: CGFloat) {
        let target = clampedZoom(zoom), start = mapZoom
        zoomTarget = target
        zoomAnimation?.cancel()
        guard target != start, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            mapZoom = target
            return
        }
        let began = ContinuousClock.now, duration = Duration.milliseconds(280)
        zoomAnimation = Task { [weak self] in
            while !Task.isCancelled {
                let t = min((ContinuousClock.now - began) / duration, 1)
                let eased = 1 - pow(1 - t, 3)
                // Interpolated on a log scale, so going from 1x to 2x feels like 4x to 8x.
                self?.mapZoom = start * pow(target / start, CGFloat(eased))
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    func zoomIn() { animateZoom(to: zoomTarget * 1.5) }
    func zoomOut() { animateZoom(to: zoomTarget / 1.5) }
    func zoomToFit() { animateZoom(to: 1) }
    var canZoomIn: Bool { map != nil && zoomTarget < Self.zoomRange.upperBound }
    var canZoomOut: Bool { map != nil && zoomTarget > Self.zoomRange.lowerBound }

    // MARK: - Furniture (kept on this Mac only)

    private(set) var furniture: [Furniture] = AppStore.loadFurniture()
    private(set) var isEditingFurniture = false
    /// The kind the next click on the map places; nil = select and move.
    var furnitureTool: Furniture.Kind?
    var selectedFurnitureID: UUID?

    func beginEditingFurniture() {
        cancelEditingZones()
        endEditingRooms()
        selectedRooms = []
        furnitureTool = nil
        selectedFurnitureID = nil
        isEditingFurniture = true
    }

    func endEditingFurniture() {
        isEditingFurniture = false
        furnitureTool = nil
        selectedFurnitureID = nil
    }

    @discardableResult
    func placeFurniture(_ kind: Furniture.Kind, at point: CGPoint) -> Furniture {
        let item = Furniture(kind: kind, at: point)
        furniture.append(item)
        selectedFurnitureID = item.id
        saveFurniture()
        return item
    }

    /// Moves without saving, for live dragging; call saveFurniture() when the drag ends.
    func moveFurniture(_ id: UUID, to point: CGPoint) {
        guard let index = furniture.firstIndex(where: { $0.id == id }) else { return }
        furniture[index].point = point
    }

    /// Resizes without saving, for live dragging; call saveFurniture() when the drag ends.
    func resizeFurniture(_ id: UUID, to size: Double) {
        guard let index = furniture.firstIndex(where: { $0.id == id }) else { return }
        furniture[index].size = min(max(size, Furniture.sizeRange.lowerBound), Furniture.sizeRange.upperBound)
    }

    /// The − and + buttons: a quarter bigger or smaller each time.
    func scaleSelectedFurniture(by factor: Double) {
        guard let id = selectedFurnitureID, let item = furniture.first(where: { $0.id == id }) else { return }
        resizeFurniture(id, to: item.size * factor)
        saveFurniture()
    }

    var canScaleSelectedFurniture: Bool { isEditingFurniture && selectedFurnitureID != nil }

    func rename(furniture id: UUID, to label: String) {
        guard let index = furniture.firstIndex(where: { $0.id == id }) else { return }
        furniture[index].label = label.trimmingCharacters(in: .whitespaces)
        saveFurniture()
    }

    func deleteSelectedFurniture() {
        furniture.removeAll { $0.id == selectedFurnitureID }
        selectedFurnitureID = nil
        saveFurniture()
    }

    func saveFurniture() { AppStore.save(furniture: furniture) }

    // MARK: - Room editing (merge / divide on the robot's saved map)

    enum RoomEditTool { case merge, divide }

    private(set) var isEditingRooms = false
    var roomEditTool: RoomEditTool = .merge {
        didSet { if oldValue != roomEditTool { selectedRooms = []; divideLine = nil } }
    }
    /// Dividing line in millimeters, drawn across the selected room.
    var divideLine: (CGPoint, CGPoint)?
    private(set) var isSendingRoomEdit = false

    func beginEditingRooms() {
        cancelEditingZones()
        endEditingFurniture()
        selectedRooms = []
        divideLine = nil
        roomEditTool = .merge
        isEditingRooms = true
    }

    func endEditingRooms() {
        isEditingRooms = false
        selectedRooms = []
        divideLine = nil
    }

    /// Selection rules while editing: merge keeps up to two rooms, divide keeps one.
    func selectForRoomEdit(_ id: Int) {
        if selectedRooms.contains(id) {
            selectedRooms.remove(id)
        } else if roomEditTool == .divide {
            selectedRooms = [id]
            divideLine = nil
        } else {
            selectedRooms = selectedRooms.count >= 2 ? [id] : selectedRooms.union([id])
        }
    }

    var canMerge: Bool {
        guard selectedRooms.count == 2, let map else { return false }
        let rooms = selectedRooms.sorted()
        // If the robot didn't report neighbors, let it decide.
        guard let neighbors = map.roomNeighbors[rooms[0]], !map.roomNeighbors.isEmpty else { return true }
        return neighbors.contains(rooms[1])
    }

    var canDivide: Bool {
        guard selectedRooms.count == 1, let line = divideLine else { return false }
        return hypot(line.1.x - line.0.x, line.1.y - line.0.y) >= 300
    }

    func mergeSelectedRooms() async {
        guard canMerge, let map else {
            AppStore.saveDiagnostic("last-room-edit.json", ["step": "merge not started", "selected": "\(selectedRooms.sorted())", "date": "\(Date())"])
            report("Select two neighboring rooms to merge.")
            return
        }
        let rooms = selectedRooms.sorted()
        await sendRoomEdit(["msr": rooms, "mapid": map.savedMapID ?? 0])
    }

    func divideSelectedRoom() async {
        guard canDivide, let map, let room = selectedRooms.first, let drawn = divideLine else {
            AppStore.saveDiagnostic("last-room-edit.json", ["step": "divide not started", "selected": "\(selectedRooms.sorted())",
                                                            "line": "\(String(describing: divideLine))", "date": "\(Date())"])
            report("Select a room and draw a line across it first.")
            return
        }
        // The robot expects the line to cross the whole room, so extend it past the room's edges.
        let line = RoomGeometry.extend(drawn, across: RoomGeometry.bounds(ofRoom: room, in: map), margin: 300)
        divideLine = line
        let values = [line.0.x, line.0.y, line.1.x, line.1.y].map { Int($0.rounded()) } + [room]
        await sendRoomEdit(["dsrid": values, "mapid": map.savedMapID ?? 0])
    }

    private func sendRoomEdit(_ payload: [String: Any]) async {
        guard let client else { return }
        isSendingRoomEdit = true
        defer { isSendingRoomEdit = false }
        let value = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) } ?? "\(payload)"
        AppStore.saveDiagnostic("last-room-edit.json", ["step": "sending", "request": value, "date": "\(Date())"])
        do {
            let reply = try await client.send("action", [
                "did": "6.2", "siid": 6, "aiid": 2, "in": [["piid": 4, "value": value]],
            ] as [String: Any]) as? [String: Any]
            let resultCode = (reply?["out"] as? [[String: Any]])?.first(where: { $0["piid"] as? Int == 6 })?["value"] as? Int
            AppStore.saveDiagnostic("last-room-edit.json", ["request": value, "reply": "\(reply ?? [:])", "date": "\(Date())"])
            guard reply?["code"] as? Int == 0, resultCode ?? 0 == 0 else {
                report("The robot didn't accept the change (code \(resultCode ?? reply?["code"] as? Int ?? -1)).")
                return
            }
            report(nil)
            selectedRooms = []
            divideLine = nil
            try? await Task.sleep(for: .seconds(4))  // the robot recomputes its rooms
            await loadMap()
        } catch {
            AppStore.saveDiagnostic("last-room-edit.json", ["step": "failed", "request": value, "error": "\(error)", "date": "\(Date())"])
            report(error.localizedDescription)
        }
    }

    // MARK: - Insights

    private(set) var history: [CleanRecord] = HistoryStore.loadHistory()
    private(set) var problems: [ProblemEvent] = HistoryStore.loadProblems()
    private(set) var isLoadingHistory = false
    private(set) var historyError: String?
    private var lastFault = 0

    /// Downloads the robot's history from Xiaomi and merges it into the local cache.
    func loadHistory() async {
        guard let cloud, let did = config?.did, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let fresh = try await XiaomiCloud(session: cloud).cleanHistory(did: did)
            history = HistoryStore.merge(fresh)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    /// The robot doesn't keep a record of errors, so the app saves each new one with where it happened.
    private func recordProblemIfNeeded() {
        let fault = int(Spec.fault) ?? 0
        defer { lastFault = fault }
        guard fault != 0, fault != lastFault else { return }
        let position = robotPosition
        var room: Int?
        if let position, let map = displayMap {
            let pixel = map.pixel(for: position)
            if case .room(let id) = map.cell(x: Int(pixel.x), y: Int(pixel.y)) { room = id }
        }
        let event = ProblemEvent(date: Date(), code: fault, x: position.map { Double($0.x) }, y: position.map { Double($0.y) }, room: room)
        HistoryStore.append(event)
        problems.append(event)
    }

    // MARK: - Attention

    struct Part: Identifiable {
        let name: String
        let level: PropertyID
        let reset: ActionID
        var id: String { name }
    }

    static let parts = [
        Part(name: "Main brush", level: Spec.mainBrush, reset: Spec.resetMainBrush),
        Part(name: "Side brush", level: Spec.sideBrush, reset: Spec.resetSideBrush),
        Part(name: "Filter", level: Spec.filter, reset: Spec.resetFilter),
        Part(name: "Mop pads", level: Spec.mopPad, reset: Spec.resetMopPad),
    ]

    /// Parts that need replacing soon (under 20%).
    var partAlerts: [String] {
        Self.parts.compactMap { part in
            guard let level = int(part.level), level < 20 else { return nil }
            return "\(part.name) \(level)%: replace soon"
        }
    }

    /// After replacing a part, tells the robot to start counting its life from 100% again.
    func resetPart(_ part: Part) async { await run(part.reset) }

    var nextScheduleText: String? {
        let now = Date()
        guard let next = schedules.compactMap({ $0.nextRun(after: now) }).min() else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(next, equalTo: now, toGranularity: .weekOfYear) ? "EEE HH:mm" : "EEE d MMM HH:mm")
        let day = Calendar.current.isDateInToday(next) ? "Today " + next.formatted(date: .omitted, time: .shortened)
            : Calendar.current.isDateInTomorrow(next) ? "Tomorrow " + next.formatted(date: .omitted, time: .shortened)
            : formatter.string(from: next)
        return "Next clean: \(day)"
    }

    // MARK: - Schedules

    var schedules: [CleaningSchedule] { CleaningSchedule.parseAll(string(Spec.schedules) ?? "") }

    /// A new schedule with sensible defaults: next free id, current map, current suction, whole house.
    func newSchedule() -> CleaningSchedule {
        let existing = schedules
        return CleaningSchedule(
            id: (existing.map(\.id).max() ?? 0) + 1, isEnabled: true, hour: 9, minute: 0,
            days: [false, true, true, true, true, true, false],
            mapID: existing.first?.mapID ?? map.flatMap { $0.savedMapID.map(String.init) } ?? "0",
            suction: int(Spec.suction) ?? 1, water: existing.first?.water ?? 0, rooms: [])
    }

    /// Adds or replaces a schedule and writes the full list to the robot.
    func save(schedule: CleaningSchedule) async {
        var all = schedules.filter { $0.id != schedule.id }
        all.append(schedule)
        await writeSchedules(all)
    }

    func setEnabled(_ enabled: Bool, schedule: CleaningSchedule) async {
        var changed = schedule
        changed.isEnabled = enabled
        await save(schedule: changed)
    }

    func delete(schedule: CleaningSchedule) async {
        guard let client else { return }
        do {
            let reply = try await client.send("action", [
                "did": "8.1", "siid": Spec.deleteSchedule.siid, "aiid": Spec.deleteSchedule.aiid,
                "in": [["piid": Spec.scheduleIDPiid, "value": String(schedule.id)]],
            ] as [String: Any]) as? [String: Any]
            if reply?["code"] as? Int != 0 {
                // Fall back to writing the list without it.
                await writeSchedules(schedules.filter { $0.id != schedule.id })
                return
            }
            values[Spec.schedules] = CleaningSchedule.encodeAll(schedules.filter { $0.id != schedule.id })
            report(nil)
        } catch {
            report(error.localizedDescription)
        }
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    private func writeSchedules(_ all: [CleaningSchedule]) async {
        let value = CleaningSchedule.encodeAll(all)
        await set(Spec.schedules, value)
        try? await Task.sleep(for: .seconds(1))
        await refresh()  // show what the robot actually stored
    }

    // MARK: - Rooms

    func name(ofRoom id: Int) -> String {
        roomNames[id] ?? "Room \(id)"
    }

    func rename(room id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        roomNames[id] = trimmed.isEmpty ? nil : trimmed
        AppStore.save(roomNames: roomNames)
    }

    func toggle(room id: Int) {
        guard !isEditingZones, !isEditingFurniture else { return }
        if isEditingRooms { selectForRoomEdit(id); return }
        if selectedRooms.contains(id) { selectedRooms.remove(id) } else { selectedRooms.insert(id) }
    }
}
