import CoreGraphics
import Foundation

/// A piece of furniture or other belonging pinned to the map. Only this Mac knows about it:
/// the robot has no place for it. The position is in the robot's millimeters, so it stays put
/// when the map is refreshed or cropped differently.
struct Furniture: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        // Living
        case sofa, armchair, chair, table, tv, fireplace, floorLamp, plant
        // Bedroom and office
        case bed, wardrobe, desk, deskLamp, toys
        // Kitchen and utility
        case fridge, oven, dishwasher, sink, washer, dryer, airPurifier, heater, fan
        // Bathroom
        case toilet, bathtub, shower
        // Other
        case door, petBowl, shoes, boxes, bike, gym

        var id: Self { self }

        var name: String {
            switch self {
            case .sofa: "Sofa"
            case .armchair: "Armchair"
            case .chair: "Chair"
            case .table: "Table"
            case .tv: "TV"
            case .fireplace: "Fireplace"
            case .floorLamp: "Floor lamp"
            case .plant: "Plant"
            case .bed: "Bed"
            case .wardrobe: "Wardrobe"
            case .desk: "Desk"
            case .deskLamp: "Lamp"
            case .toys: "Toys"
            case .fridge: "Fridge"
            case .oven: "Oven"
            case .dishwasher: "Dishwasher"
            case .sink: "Sink"
            case .washer: "Washing machine"
            case .dryer: "Dryer"
            case .airPurifier: "Air purifier"
            case .heater: "Heater"
            case .fan: "Fan"
            case .toilet: "Toilet"
            case .bathtub: "Bathtub"
            case .shower: "Shower"
            case .door: "Door"
            case .petBowl: "Pet bowl"
            case .shoes: "Shoes"
            case .boxes: "Boxes"
            case .bike: "Bike"
            case .gym: "Gym gear"
            }
        }

        var systemImage: String {
            switch self {
            case .sofa: "sofa.fill"
            case .armchair: "chair.lounge.fill"
            case .chair: "chair.fill"
            case .table: "table.furniture.fill"
            case .tv: "tv.fill"
            case .fireplace: "fireplace.fill"
            case .floorLamp: "lamp.floor.fill"
            case .plant: "leaf.fill"
            case .bed: "bed.double.fill"
            case .wardrobe: "cabinet.fill"
            case .desk: "desktopcomputer"
            case .deskLamp: "lamp.desk.fill"
            case .toys: "teddybear.fill"
            case .fridge: "refrigerator.fill"
            case .oven: "oven.fill"
            case .dishwasher: "dishwasher.fill"
            case .sink: "sink.fill"
            case .washer: "washer.fill"
            case .dryer: "dryer.fill"
            case .airPurifier: "air.purifier.fill"
            case .heater: "heater.vertical.fill"
            case .fan: "fan.floor.fill"
            case .toilet: "toilet.fill"
            case .bathtub: "bathtub.fill"
            case .shower: "shower.fill"
            case .door: "door.left.hand.open"
            case .petBowl: "pawprint.fill"
            case .shoes: "shoe.fill"
            case .boxes: "shippingbox.fill"
            case .bike: "bicycle"
            case .gym: "dumbbell.fill"
            }
        }

        /// A typical footprint, one side in millimeters, so a bed starts bigger than a plant.
        var defaultSize: Double {
            switch self {
            case .bed: 1800
            case .sofa, .table, .bathtub: 1400
            case .wardrobe, .desk, .shower, .bike: 1100
            case .armchair, .tv, .fireplace, .boxes, .gym: 900
            case .fridge, .oven, .dishwasher, .sink, .washer, .dryer, .toilet, .door: 650
            case .chair, .toys, .shoes, .airPurifier, .heater, .fan, .floorLamp: 500
            case .plant, .deskLamp, .petBowl: 400
            }
        }

        /// Menu sections, so the list stays easy to scan.
        static let groups: [(name: String, kinds: [Kind])] = [
            ("Living room", [.sofa, .armchair, .chair, .table, .tv, .fireplace, .floorLamp, .plant]),
            ("Bedroom and office", [.bed, .wardrobe, .desk, .deskLamp, .toys]),
            ("Kitchen and utility", [.fridge, .oven, .dishwasher, .sink, .washer, .dryer, .airPurifier, .heater, .fan]),
            ("Bathroom", [.toilet, .bathtub, .shower]),
            ("Other", [.door, .petBowl, .shoes, .boxes, .bike, .gym]),
        ]
    }

    let id: UUID
    var kind: Kind
    /// Millimeters, like the robot's map.
    var x: Double
    var y: Double
    /// Your own label, e.g. "Kids' bed". Empty uses the kind's name.
    var label: String
    /// One side of its footprint, in millimeters.
    var size: Double

    /// From a small bowl to a big corner sofa.
    static let sizeRange: ClosedRange<Double> = 250...4000

    init(id: UUID = UUID(), kind: Kind, at point: CGPoint, label: String = "", size: Double? = nil) {
        self.id = id
        self.kind = kind
        self.x = Double(point.x)
        self.y = Double(point.y)
        self.label = label
        self.size = size ?? kind.defaultSize
    }

    private enum CodingKeys: String, CodingKey { case id, kind, x, y, label, size }

    /// Files from before sizes existed load with the kind's default size.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? kind.defaultSize
    }

    var point: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = Double(newValue.x); y = Double(newValue.y) }
    }

    var displayName: String { label.isEmpty ? kind.name : label }
}
