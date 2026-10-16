// Converts between the robot's map (millimeters, x right, y up) and the picture vacuumd draws (pixels, y down).
// `t` is the transform vacuumd returns with each picture (get_map_image → mapTransform).

export const toPixel = (t, mm) => ({
  x: t.offsetX + ((mm.x - t.leftMm) / t.gridSizeMm) * t.scale,
  y: (t.mapHeight - (mm.y - t.topMm) / t.gridSizeMm) * t.scale,
});

export const toMm = (t, px) => ({
  x: t.leftMm + ((px.x - t.offsetX) / t.scale) * t.gridSizeMm,
  y: t.topMm + (t.mapHeight - px.y / t.scale) * t.gridSizeMm,
});

// Millimeters across one picture pixel.
export const mmPerPixel = (t) => t.gridSizeMm / t.scale;

// Furniture sizes are millimeters; this is how big they are in picture pixels.
export const sizeInPixels = (t, mm) => mm / mmPerPixel(t);
