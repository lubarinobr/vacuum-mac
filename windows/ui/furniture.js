// The furniture and belongings the Mac app lets you pin to the map. Same kinds, names and default sizes.
// Positions are in the robot's millimeters, so they stay put when the map is redrawn.

export const SIZE_RANGE = [250, 4000];

export const GROUPS = [
  { name: 'Living room', kinds: [['sofa', 'Sofa', 1400], ['armchair', 'Armchair', 900], ['chair', 'Chair', 500], ['table', 'Table', 1400], ['tv', 'TV', 900], ['fireplace', 'Fireplace', 900], ['floorLamp', 'Floor lamp', 500], ['plant', 'Plant', 400]] },
  { name: 'Bedroom and office', kinds: [['bed', 'Bed', 1800], ['wardrobe', 'Wardrobe', 1100], ['desk', 'Desk', 1100], ['deskLamp', 'Lamp', 400], ['toys', 'Toys', 500]] },
  { name: 'Kitchen and utility', kinds: [['fridge', 'Fridge', 650], ['oven', 'Oven', 650], ['dishwasher', 'Dishwasher', 650], ['sink', 'Sink', 650], ['washer', 'Washing machine', 650], ['dryer', 'Dryer', 650], ['airPurifier', 'Air purifier', 500], ['heater', 'Heater', 500], ['fan', 'Fan', 500]] },
  { name: 'Bathroom', kinds: [['toilet', 'Toilet', 650], ['bathtub', 'Bathtub', 1400], ['shower', 'Shower', 1100]] },
  { name: 'Other', kinds: [['door', 'Door', 650], ['petBowl', 'Pet bowl', 400], ['shoes', 'Shoes', 500], ['boxes', 'Boxes', 900], ['bike', 'Bike', 1100], ['gym', 'Gym gear', 900]] },
];

const NAMES = Object.fromEntries(GROUPS.flatMap((g) => g.kinds.map(([kind, name]) => [kind, name])));

export const kindName = (kind) => NAMES[kind] ?? kind;
export const displayName = (piece) => piece.label || kindName(piece.kind);
export const clampSize = (mm) => Math.min(SIZE_RANGE[1], Math.max(SIZE_RANGE[0], Math.round(mm)));

// The file is the same JSON the Mac app writes: an array of { id, kind, x, y, label, size }.
export function parseFurniture(value) {
  if (!Array.isArray(value)) return [];
  return value
    .filter((p) => p && typeof p.kind === 'string' && Number.isFinite(p.x) && Number.isFinite(p.y))
    .map((p) => ({ id: String(p.id), kind: p.kind, x: p.x, y: p.y, label: p.label ?? '', size: clampSize(p.size ?? 500) }));
}
