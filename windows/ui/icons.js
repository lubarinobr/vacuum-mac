// Line icons for the furniture on the map and the toolbar, drawn on a 24 px grid in the same stroke weight.
// They stand in for the SF Symbols the Mac app uses; each furniture kind has one.

const KIND_PATHS = {
  sofa: '<path d="M4 11V8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v3"/><path d="M3 11h18v5H3z"/><path d="M5 16v2M19 16v2"/>',
  armchair: '<path d="M7 10V7a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v3"/><path d="M5 12a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v4H5z"/><path d="M6 16v2M18 16v2"/>',
  chair: '<path d="M8 3h8v9H8z"/><path d="M6 12h12v3H6z"/><path d="M8 15v6M16 15v6"/>',
  table: '<path d="M3 8h18"/><path d="M5 8v13M19 8v13"/><path d="M7 4h10"/>',
  tv: '<rect x="3" y="5" width="18" height="11" rx="1"/><path d="M8 20h8M12 16v4"/>',
  fireplace: '<rect x="4" y="4" width="16" height="16" rx="1"/><path d="M8 20v-6a4 4 0 0 1 8 0v6"/>',
  floorLamp: '<path d="M8 3h8l-2 5h-4z"/><path d="M12 8v12"/><path d="M8 21h8"/>',
  plant: '<path d="M7 15h10l-1 6H8z"/><path d="M12 15c0-4-3-7-7-7 0 4 3 7 7 7zM12 15c0-4 3-7 7-7 0 4-3 7-7 7z"/>',
  bed: '<path d="M3 5v14M3 13h18v6M21 13v-2a2 2 0 0 0-2-2h-8v4"/><path d="M7 11a2 2 0 1 0 0-.01"/>',
  wardrobe: '<rect x="5" y="3" width="14" height="18" rx="1"/><path d="M12 3v18M10 11v2M14 11v2"/>',
  desk: '<path d="M3 14h18M5 14v7M19 14v7"/><rect x="8" y="3" width="8" height="7" rx="1"/>',
  deskLamp: '<path d="M5 20h8"/><path d="M9 20l4-11"/><path d="M12 4l5 5-3 3-5-5z"/>',
  toys: '<circle cx="12" cy="8" r="4"/><circle cx="8.5" cy="4" r="1.5"/><circle cx="15.5" cy="4" r="1.5"/><path d="M7 21v-5a5 5 0 0 1 10 0v5z"/>',
  fridge: '<rect x="6" y="3" width="12" height="18" rx="1"/><path d="M6 10h12M9 6v2M9 13v3"/>',
  oven: '<rect x="3" y="3" width="18" height="18" rx="1"/><path d="M6 9h12v8H6z"/><path d="M6 6h2M16 6h2"/>',
  dishwasher: '<rect x="3" y="3" width="18" height="18" rx="1"/><circle cx="12" cy="13" r="4"/><path d="M3 7h18"/>',
  sink: '<path d="M3 14h18v3a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4z"/><path d="M12 14V6h4"/>',
  washer: '<rect x="4" y="3" width="16" height="18" rx="1"/><circle cx="12" cy="13" r="5"/><path d="M7 6h3"/>',
  dryer: '<rect x="4" y="3" width="16" height="18" rx="1"/><circle cx="12" cy="13" r="4"/><circle cx="12" cy="13" r="1"/>',
  airPurifier: '<rect x="7" y="3" width="10" height="18" rx="1"/><path d="M9 7h6M9 10h6M9 13h6"/>',
  heater: '<rect x="7" y="3" width="10" height="18" rx="1"/><path d="M10 9h4M10 12h4M10 15h4"/>',
  fan: '<circle cx="12" cy="12" r="2"/><path d="M12 10c0-4 4-6 6-3-1 3-4 3-6 3zM14 12c4 0 6 4 3 6-3-1-3-4-3-6zM12 14c0 4-4 6-6 3 1-3 4-3 6-3zM10 12c-4 0-6-4-3-6 3 1 3 4 3 6z"/>',
  toilet: '<path d="M7 3h10v6H7z"/><path d="M6 10h12v3a6 6 0 0 1-12 0z"/>',
  bathtub: '<path d="M3 11h18v2a6 6 0 0 1-6 6H9a6 6 0 0 1-6-6z"/><path d="M6 19l-1 2M18 19l1 2M5 11V5a2 2 0 0 1 4 0"/>',
  shower: '<path d="M14 4h6v2h-6z"/><path d="M17 6v3M8 12h8M8 12v8M16 12v8M8 20h8"/>',
  door: '<rect x="5" y="3" width="11" height="18" rx="1"/><path d="M13 12h2"/>',
  petBowl: '<path d="M4 11h16c0 3-3.5 5-8 5s-8-2-8-5z"/><path d="M8 16l-1 4h10l-1-4"/>',
  shoes: '<path d="M3 15c3 0 4-2 6-4l3 2h9v4H3z"/>',
  boxes: '<path d="M3 8l9-4 9 4v9l-9 4-9-4z"/><path d="M3 8l9 4 9-4M12 12v9"/>',
  bike: '<circle cx="6" cy="16" r="4"/><circle cx="18" cy="16" r="4"/><path d="M6 16l3-6h6M9 10l3 6M15 10l3 6"/>',
  gym: '<path d="M3 10v4M6 8v8M18 8v8M21 10v4M6 12h12"/>',
};

const UI_PATHS = {
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  pencil: '<path d="M4 20h4L19 9l-4-4L4 16v4z"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
  chevron: '<path d="M6 9l6 6 6-6"/>',
};

const svg = (inner, size) =>
  `<svg viewBox="0 0 24 24" width="${size}" height="${size}" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;

export const kindIcon = (kind, size = 18) => svg(KIND_PATHS[kind] ?? KIND_PATHS.boxes, size);
export const uiIcon = (name, size = 18) => svg(UI_PATHS[name] ?? '', size);

// The icon size for a badge of `side` pixels: grows with the footprint, between 11 and 24 px, like the Mac app.
export const badgeIconSize = (side) => Math.min(Math.max(side * 0.42, 11), 24);
