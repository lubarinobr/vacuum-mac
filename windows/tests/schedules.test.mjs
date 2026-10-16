// The schedule format must read and write exactly what the robot and the Mac app use.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseAll, encodeAll, parseSchedule, daysText } from '../ui/schedules.js';

const EXAMPLE = '1-1-08:36-0100000-1-12-1-0-6';

test('reads the Mac app example: schedule 1, on, 08:36, Mondays, map 12, Standard, room 6', () => {
  const s = parseSchedule(EXAMPLE);
  assert.equal(s.id, 1);
  assert.equal(s.isEnabled, true);
  assert.equal(s.hour, 8);
  assert.equal(s.minute, 36);
  assert.deepEqual(s.days, [false, true, false, false, false, false, false]);
  assert.equal(s.mapID, '12');
  assert.equal(s.suction, 1);
  assert.deepEqual(s.rooms, [6]);
});

test('writes it back byte for byte', () => {
  assert.equal(encodeAll(parseAll(EXAMPLE)), EXAMPLE);
});

test('a whole-house, once-only schedule round-trips', () => {
  const text = '2-0-19:00-0000000-0-12-2-0-0';
  assert.equal(encodeAll(parseAll(text)), text);
  assert.equal(parseSchedule(text).isEnabled, false);
});

test('schedules come back sorted by time and written by id', () => {
  const list = parseAll('3-1-07:30-0111110-1-12-2-0-2,5;1-1-08:36-0100000-1-12-1-0-6');
  assert.deepEqual(list.map((s) => s.id), [3, 1]);
  assert.equal(encodeAll(list), '1-1-08:36-0100000-1-12-1-0-6;3-1-07:30-0111110-1-12-2-0-2,5');
});

test('day names read the way the Mac app shows them', () => {
  assert.equal(daysText([false, false, false, false, false, false, false]), 'Once');
  assert.equal(daysText([true, true, true, true, true, true, true]), 'Every day');
  assert.equal(daysText([false, true, true, true, true, true, false]), 'Weekdays');
  assert.equal(daysText([true, false, false, false, false, false, true]), 'Weekends');
  assert.equal(daysText([false, true, false, true, false, false, false]), 'Mon, Wed');
});

test('garbage entries are skipped instead of breaking the list', () => {
  assert.deepEqual(parseAll('nonsense;;x-1-08:00'), []);
});
