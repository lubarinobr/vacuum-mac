import Foundation
import Testing
@testable import Vacuum

// Expected values were generated with python-miio and the robot-vacuum Python scripts,
// which talk to the real robot successfully.

struct MiIOPacketTests {
    let packet = MiIOPacket(token: Data(hex: "00112233445566778899aabbccddeeff")!)
    let request = #"{"id": 1, "method": "get_properties", "params": [{"did": "x", "siid": 3, "piid": 1}]}"#
    let expected = "213100800000000043f5b7a16553f1002804c4ac14f619c9db34f958a39345d92a36b2b7afa85bd6a9f1ed82b485a3d658c96ba3b375bd3a49af5151f5155f163087aefff022bc1b2374956dfc606d5805505f849e0fee2e061f2e9f401f0b99d28ff527d021af9308c852ea016fcf43d9c95e6a860b7477bddb54b98e5e369a"

    @Test func encodesExactlyLikePythonMiio() throws {
        let encoded = try packet.encode(Data(request.utf8) + Data([0]), deviceID: 0x43f5b7a1, stamp: 1_700_000_000)
        #expect(encoded.hex == expected)
    }

    @Test func decodesPythonMiioPacket() throws {
        let decoded = try packet.decode(Data(hex: expected)!)
        #expect(decoded.deviceID == 0x43f5b7a1)
        #expect(decoded.stamp == 1_700_000_000)
        #expect(String(decoding: decoded.payload, as: UTF8.self) == request)
    }

    @Test func rejectsGarbage() {
        #expect(throws: MiIOError.self) { try packet.decode(Data([1, 2, 3])) }
    }
}

struct CloudSigningTests {
    let ssecurity = "AAECAwQFBgcICQoLDA0ODw=="
    let nonce = "AAECAwQFBgcBuoFA"

    @Test func signedNonce() {
        #expect(CloudSigning.signedNonce(ssecurity: ssecurity, nonce: nonce) == "EUoFaowzj1OjSU1vYmiJV1IFL9iRmJdzldY/piGxtDo=")
    }

    @Test func fieldsMatchPython() {
        let fields = CloudSigning.fields(path: "/v2/home/get_interim_file_url", data: #"{"obj_name":"a/b/1"}"#,
                                         ssecurity: ssecurity, nonce: nonce)
        let byName = Dictionary(uniqueKeysWithValues: fields)
        #expect(byName["data"] == "e7L8ZipadWTAsUdOpn67z0FNz90=")
        #expect(byName["rc4_hash__"] == "b+TqQBRtfX3fuioQvGfExxgshuuYoFA3d5wMCQ==")
        #expect(byName["signature"] == "Dpz0iX6BRtul7MmosMIeAyKutq8=")
        #expect(fields.map(\.0) == ["data", "rc4_hash__", "signature", "ssecurity", "_nonce"])
    }

    @Test func rc4RoundTrips() {
        let key = CloudSigning.signedNonce(ssecurity: ssecurity, nonce: nonce)
        let message = Data("hello".utf8)
        #expect(CloudSigning.rc4(key, CloudSigning.rc4(key, message)) == message)
    }
}

struct MapDecoderTests {
    // A real map file downloaded from the robot, with the key the robot returned alongside it.
    func fixture() throws -> String {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "map_raw", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func decodesRealMap() throws {
        let map = try MapDecoder.decode(try fixture(), key: "okzjB9uF4WCUU3d9")
        // Rooms come from the embedded saved map (208x355); the robot position from the live map.
        #expect(map.width == 208)
        #expect(map.height == 355)
        #expect(map.header.gridSize == 50)
        #expect(map.roomIDs == [1, 2, 3, 4, 5, 6])
        // Visible area: saved room shapes minus what the live map sees as blocked (sofa, furniture).
        #expect(abs(map.area(ofRoom: 5) - 32.7) < 0.1)
        #expect(abs(map.area(ofRoom: 6) - 4.45) < 0.1)
    }

    @Test func decodesRestrictedZonesFromSavedMap() throws {
        let map = try MapDecoder.decode(try fixture(), key: "okzjB9uF4WCUU3d9")
        #expect(map.zones.virtualWalls.count == 4)
        #expect(map.zones.noGo.count == 1)
        #expect(map.zones.noMop.isEmpty)
        #expect(map.zones.carpets.count == 5)
        #expect(map.zones.noGo.first == CGRect(x: 993, y: -2517, width: 829, height: 1647))
    }

    @Test func readsSavedMapIDAndRoomNeighbors() throws {
        let map = try MapDecoder.decode(try fixture(), key: "okzjB9uF4WCUU3d9")
        #expect(map.savedMapID == 12)
        #expect(map.roomNeighbors[6] == [1, 2, 3, 4, 5])
        #expect(map.roomNeighbors[2] == [4, 6])
    }

    @Test func wrongKeyFails() throws {
        #expect(throws: (any Error).self) { try MapDecoder.decode(try fixture(), key: "wrongwrongwrong1") }
    }

    @Test func rendersImageOfMapSize() throws {
        let map = try MapDecoder.decode(try fixture(), key: "okzjB9uF4WCUU3d9")
        let image = try #require(MapRenderer.image(map, selected: [6]))
        #expect(image.width == 208 && image.height == 355)
        #expect(MapRenderer.roomCenters(map).count == 6)
    }
}

final class BundleMarker {}

struct CleaningModeTests {
    // Real value from the X20+ while the Xiaomi app showed "Vacuum".
    let realValue = 198_658  // 0x030802

    @Test func readsModeFromLowBits() {
        #expect(CleaningMode(packed: realValue) == .vacuum)
    }

    @Test func changesOnlyTheModeBits() {
        #expect(CleaningMode.mop.packed(into: realValue) == 0x030801)
        #expect(CleaningMode.vacuumAndMop.packed(into: realValue) == 0x030800)
        #expect(CleaningMode.mopAfterVacuum.packed(into: realValue) == 0x030803)
        #expect(CleaningMode.vacuum.packed(into: CleaningMode.mop.packed(into: realValue)) == realValue)
    }
}

struct ZoneEditingTests {
    @Test func roundTripsRealZonesIntoTheSamePayload() throws {
        // Payload the robot accepted, built from its own zones.
        let vw: [String: Any] = ["line": [[4591, 769, 4609, 3485], [5461, -5220, 5417, 884]],
                                 "rect": [[993, -2517, 1822, -870]], "mop": [] as [[Int]]]
        let zones = MapDecoder.zones(from: vw)
        let edited = ZoneEditing.zones(from: ZoneEditing.editable(from: zones), keepingCarpetsOf: zones)
        let payload = ZoneEditing.payload(for: edited)
        #expect(payload["line"] == [[4591, 769, 4609, 3485], [5461, -5220, 5417, 884]])
        #expect(payload["rect"] == [[993, -2517, 1822, -870]])
        #expect(payload["mop"] == [])
    }

    @Test func rectanglesAreNormalizedWhenDrawnBackwards() {
        let zone = EditableZone(kind: .noGo, a: CGPoint(x: 1000, y: 500), b: CGPoint(x: 200, y: -300))
        let payload = ZoneEditing.payload(for: ZoneEditing.zones(from: [zone], keepingCarpetsOf: .init()))
        #expect(payload["rect"] == [[200, -300, 1000, 500]])
    }

    @Test func tinyShapesAreDiscarded() {
        #expect(!EditableZone(kind: .wall, a: .zero, b: CGPoint(x: 50, y: 0)).isUsable)
        #expect(EditableZone(kind: .wall, a: .zero, b: CGPoint(x: 500, y: 0)).isUsable)
        #expect(!EditableZone(kind: .noGo, a: .zero, b: CGPoint(x: 1000, y: 100)).isUsable)
    }
}

struct RobotPathTests {
    @Test func parsesAbsoluteAndRelativeSteps() {
        let path = MapDecoder.path(from: "S258,-318L0,2L52,0M1000,1000L10,10")
        #expect(path.map(\.point) == [CGPoint(x: 258, y: -318), CGPoint(x: 258, y: -316), CGPoint(x: 310, y: -316),
                                       CGPoint(x: 1000, y: 1000), CGPoint(x: 1010, y: 1010)])
        #expect(path.map(\.startsStroke) == [true, false, false, true, false])
    }

    @Test func partialFrameContinuesThePreviousPath() {
        // Real partial frame trace from the robot.
        let path = MapDecoder.path(from: "l1113,387L-47,19L-47,19", continuingFrom: CGPoint(x: 1156, y: 378))
        #expect(path.first == VacuumMap.PathPoint(point: CGPoint(x: 1113, y: 387), startsStroke: false))
        #expect(path.last?.point == CGPoint(x: 1019, y: 425))
    }

    @Test func dockedMapHasNoPath() throws {
        // Downloaded while the robot sat on the dock: "tr" is an empty string.
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "map_raw", withExtension: "txt"))
        let map = try MapDecoder.decode(try String(contentsOf: url, encoding: .utf8), key: "okzjB9uF4WCUU3d9")
        #expect(map.extra["tr"] as? String == "")
        #expect(map.path.isEmpty)
    }
}

struct RoomGeometryTests {
    @Test func extendsAShortLineAcrossTheWholeBox() {
        let box = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let line = RoomGeometry.extend((CGPoint(x: 400, y: 200), CGPoint(x: 600, y: 200)), across: box, margin: 100)
        #expect(line.0 == CGPoint(x: -100, y: 200))
        #expect(line.1 == CGPoint(x: 1100, y: 200))
    }

    @Test func keepsTheDrawnAngle() {
        let box = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let line = RoomGeometry.extend((CGPoint(x: 400, y: 400), CGPoint(x: 600, y: 600)), across: box, margin: 0)
        #expect(line.0 == CGPoint(x: 0, y: 0))
        #expect(line.1 == CGPoint(x: 1000, y: 1000))
    }

    @Test func realRoomHasBounds() throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "map_raw", withExtension: "txt"))
        let map = try MapDecoder.decode(try String(contentsOf: url, encoding: .utf8), key: "okzjB9uF4WCUU3d9")
        let bounds = try #require(RoomGeometry.bounds(ofRoom: 6, in: map))
        #expect(bounds.width > 0 && bounds.height > bounds.width)  // the corridor is tall and narrow
    }
}

struct SavedMapFallbackTests {
    @Test func savedPixelsAreRoomNumbersWithEdgesAsWalls() {
        // 4x3: a 2x1 strip of room 7 (one carpet pixel) surrounded by nothing.
        let pixels: [UInt8] = [0, 0, 0, 0,
                               0, 7, 0x87, 0,
                               0, 0, 0, 0]
        let cells = MapDecoder.savedCells(pixels, width: 4, height: 3)
        #expect(cells[5] == .wall && cells[6] == .wall)  // both touch the outside
        let bigger = MapDecoder.savedCells([UInt8](repeating: 3, count: 9), width: 3, height: 3)
        #expect(bigger[4] == .room(3))  // interior cell keeps its room
    }
}

struct HiddenRoomsTests {
    @Test func hidingRemovesTheRoomAndCropsTheMap() throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "map_raw", withExtension: "txt"))
        let map = try MapDecoder.decode(try String(contentsOf: url, encoding: .utf8), key: "okzjB9uF4WCUU3d9")
        let hidden = map.hiding(rooms: [4])
        #expect(!hidden.roomIDs.contains(4))
        #expect(hidden.roomIDs == [1, 2, 3, 5, 6])
        #expect(hidden.width * hidden.height <= map.width * map.height)
        // Real-world positions survive the crop: room 6 keeps its area.
        #expect(abs(hidden.area(ofRoom: 6) - map.area(ofRoom: 6)) < 0.01)
    }
}

struct CleaningScheduleTests {
    @Test func parsesTheRealSchedules() throws {
        // Before and after editing it in the Xiaomi app (Monday only, room 6).
        let before = try #require(CleaningSchedule.parse("1-0-08:36-0000000-0-12-2-16-0"))
        #expect(!before.isEnabled && !before.repeats && before.rooms.isEmpty && before.daysText == "Once")
        let after = try #require(CleaningSchedule.parse("1-1-08:36-0100000-1-12-1-0-6"))
        #expect(after.isEnabled)
        #expect(after.days == [false, true, false, false, false, false, false])  // Sunday first: Monday is index 1
        #expect(after.daysText == "Mon")
        #expect(after.rooms == [6] && after.suction == 1 && after.water == 0 && after.timeText == "08:36")
    }

    @Test func encodesBackToTheSameString() throws {
        for raw in ["1-0-08:36-0000000-0-12-2-16-0", "1-1-08:36-0100000-1-12-1-0-6"] {
            #expect(try #require(CleaningSchedule.parse(raw)).encoded == raw)
        }
    }

    @Test func multipleSchedulesAndRooms() {
        let all = CleaningSchedule.parseAll("2-1-18:00-0111110-1-12-2-0-3,6;1-0-08:36-0000000-0-12-2-16-0")
        #expect(all.map(\.id) == [1, 2])  // sorted by time
        #expect(all[1].rooms == [3, 6] && all[1].daysText == "Weekdays")
        #expect(CleaningSchedule.encodeAll(all) == "1-0-08:36-0000000-0-12-2-16-0;2-1-18:00-0111110-1-12-2-0-3,6")
    }
}

struct NextRunTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return c
    }()

    @Test func weeklyScheduleRunsNextMonday() throws {
        let schedule = try #require(CleaningSchedule.parse("1-1-08:36-0100000-1-12-1-0-6"))
        // Tuesday 13 Oct 2026, 15:00 → next Monday 19 Oct, 08:36.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15)))
        let next = try #require(schedule.nextRun(after: now, calendar: calendar))
        #expect(calendar.dateComponents([.day, .hour, .minute], from: next) == DateComponents(day: 19, hour: 8, minute: 36))
    }

    @Test func disabledScheduleNeverRuns() throws {
        let schedule = try #require(CleaningSchedule.parse("1-0-08:36-0100000-1-12-1-0-6"))
        #expect(schedule.nextRun(after: .now, calendar: calendar) == nil)
    }
}

struct OnboardingTests {
    @Test func onlyTheX20PlusIsSupported() {
        let x20 = CloudDevice(did: "1", name: "Xiaomi Robot Vacuum X20+", model: "xiaomi.vacuum.c102gl", localIP: "192.168.1.20", token: String(repeating: "a", count: 32), region: .de)
        let other = CloudDevice(did: "2", name: "Other", model: "roborock.vacuum.a15", localIP: "", token: "", region: .de)
        let band = CloudDevice(did: "3", name: "Smart Band 7", model: "hmpace.watch.v7", localIP: "", token: "", region: .de)
        #expect(x20.isSupported && x20.isVacuum)
        #expect(!other.isSupported && other.isVacuum)
        #expect(!band.isVacuum)
    }
}

struct InsightsTests {
    // Real history events from the robot (event 4.1).
    let wholeHouse = #"[{"piid":1,"value":2},{"piid":2,"value":9},{"piid":3,"value":9},{"piid":6,"value":0},{"piid":13,"value":0},{"piid":8,"value":1791900022},{"piid":9,"value":"2026/10/13/8257271745/1140024801_221144395.1087.bin,7SwXbYidS9mHRycLVJNj9w"},{"piid":10,"value":"{\"cmc\":1,\"area_clean_detail\":\"[[4,0],[2,0],[6,0],[1,0],[3,0]]\"}"}]"#
    let corridor = #"[{"piid":1,"value":18},{"piid":2,"value":12},{"piid":3,"value":5},{"piid":13,"value":1},{"piid":8,"value":1791896839},{"piid":10,"value":"{\"area_clean_detail\":\"[[6,0]]\"}"}]"#

    @Test func parsesHistoryEvents() throws {
        let record = try #require(CleanRecord(eventValue: wholeHouse))
        #expect(record.minutes == 9 && record.area == 9 && !record.completed && !record.isRoomClean)
        #expect(record.rooms == [4, 2, 6, 1, 3])
        #expect(record.start == Date(timeIntervalSince1970: 1_791_900_022))
        let room = try #require(CleanRecord(eventValue: corridor))
        #expect(room.isRoomClean && room.completed && room.rooms == [6])
    }

    @Test func summarizesWeeksAndRooms() throws {
        let records = [try #require(CleanRecord(eventValue: wholeHouse)), try #require(CleanRecord(eventValue: corridor))]
        let now = Date(timeIntervalSince1970: 1_791_910_000)
        let summary = InsightsSummary(history: records, rooms: [2, 6], now: now)
        #expect(summary.weeks.count == 8)
        #expect(summary.thisWeek?.cleans == 2 && summary.thisWeek?.area == 14 && summary.thisWeek?.minutes == 21)
        #expect(summary.rooms.first { $0.room == 6 }?.cleans == 2)
        #expect(summary.rooms.first { $0.room == 2 }?.cleans == 1)
    }

    @Test func problemCategories() {
        #expect(ProblemEvent(date: .now, code: 93).isStuck)          // stuck on threshold
        #expect(!ProblemEvent(date: .now, code: 101).isStuck)        // bin full
        #expect(ProblemEvent(date: .now, code: 93).name == "Stuck on threshold")
    }
}

struct FurnitureTests {
    @Test func savedFormatRoundTrips() throws {
        let items = [Furniture(kind: .sofa, at: CGPoint(x: 1200, y: -350), label: "Big sofa"),
                     Furniture(kind: .petBowl, at: CGPoint(x: 0, y: 4100))]
        let decoded = try JSONDecoder().decode([Furniture].self, from: JSONEncoder().encode(items))
        #expect(decoded == items)
    }

    @Test func readsTheFileFormat() throws {
        // What furniture.json holds: kinds by name, so adding kinds later keeps old files readable.
        let json = #"[{"id":"0F6B4E2C-1D3A-4B5C-8E9F-123456789ABC","kind":"bed","x":2500,"y":1800,"label":""}]"#
        let item = try #require(try JSONDecoder().decode([Furniture].self, from: Data(json.utf8)).first)
        #expect(item.kind == .bed)
        #expect(item.point == CGPoint(x: 2500, y: 1800))
        #expect(item.displayName == "Bed")
    }

    @Test func everyKindIsInTheMenu() {
        #expect(Set(Furniture.Kind.groups.flatMap(\.kinds)) == Set(Furniture.Kind.allCases))
    }
}

struct FurnitureSizeTests {
    @Test func olderFilesGetTheKindsDefaultSize() throws {
        let json = #"[{"id":"0F6B4E2C-1D3A-4B5C-8E9F-123456789ABC","kind":"plant","x":0,"y":0,"label":""}]"#
        let item = try #require(try JSONDecoder().decode([Furniture].self, from: Data(json.utf8)).first)
        #expect(item.size == Furniture.Kind.plant.defaultSize)
    }

    @Test func aBedStartsBiggerThanAPlant() {
        #expect(Furniture(kind: .bed, at: .zero).size > Furniture(kind: .plant, at: .zero).size)
    }
}
