// The map picture and the robot's millimeters must convert both ways without drifting.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { toPixel, toMm, sizeInPixels } from '../ui/mapview.js';
import { parseFurniture } from '../ui/furniture.js';

const t = { leftMm: -2000, topMm: -5000, gridSizeMm: 50, scale: 4, offsetX: 10, mapWidth: 200, mapHeight: 150 };

test('millimeters go to picture pixels and back', () => {
  const mm = { x: 1234, y: -3210 };
  const back = toMm(t, toPixel(t, mm));
  assert.ok(Math.abs(back.x - mm.x) < 1e-6 && Math.abs(back.y - mm.y) < 1e-6);
});

test('the map corner in millimeters is the bottom-left of the picture', () => {
  const p = toPixel(t, { x: t.leftMm, y: t.topMm });
  assert.equal(p.x, t.offsetX);
  assert.equal(p.y, t.mapHeight * t.scale);
});

test('a 500 mm piece is the right number of picture pixels', () => {
  assert.equal(sizeInPixels(t, 500), 500 / 50 * 4);
});

test('the furniture file is read the way the Mac app writes it', () => {
  const list = parseFurniture([{ id: 'A', kind: 'sofa', x: 1, y: 2, label: 'Blue', size: 1400 }, { nope: true }]);
  assert.deepEqual(list, [{ id: 'A', kind: 'sofa', x: 1, y: 2, label: 'Blue', size: 1400 }]);
});
