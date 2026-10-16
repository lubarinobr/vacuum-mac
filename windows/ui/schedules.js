// The robot keeps all schedules in one text value (property 8.2). This reads and writes it the way the Mac app does:
// "id-state-HH:MM-days-repeat-map-suction-water-rooms", schedules separated by ";".
// Example: "1-1-08:36-0100000-1-12-1-0-6" = schedule 1, on, 08:36, Mondays, weekly, map 12, Standard, water 0, room 6.
// Days are Sunday first, like the robot stores them.

export const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DISPLAY_ORDER = [1, 2, 3, 4, 5, 6, 0];

const intOr = (text, fallback) => {
  const value = Number(text);
  return text !== undefined && text !== '' && Number.isFinite(value) ? Math.trunc(value) : fallback;
};
const pad = (n) => String(n).padStart(2, '0');

export function parseSchedule(text) {
  const f = text.split('-');
  if (f.length < 9) return null;
  const id = intOr(f[0], NaN);
  if (!Number.isInteger(id)) return null;
  const [hour, minute] = f[2].split(':');
  const days = f[3].padEnd(7, '0').slice(0, 7).split('').map((c) => c === '1');
  return {
    id,
    isEnabled: f[1] === '1' || f[1] === '2',
    hour: intOr(hour, 0),
    minute: intOr(minute, 0),
    days,
    mapID: f[5],
    suction: intOr(f[6], 1),
    water: intOr(f[7], 0),
    rooms: f[8] === '0' ? [] : f[8].split(',').map(Number).filter(Number.isFinite),
  };
}

export const parseAll = (text) =>
  (text ?? '')
    .split(';')
    .map(parseSchedule)
    .filter(Boolean)
    .sort((a, b) => a.hour - b.hour || a.minute - b.minute || a.id - b.id);

export function encodeSchedule(s) {
  const repeats = s.days.some(Boolean);
  return [
    String(s.id),
    s.isEnabled ? '1' : '0',
    `${pad(s.hour)}:${pad(s.minute)}`,
    s.days.map((d) => (d ? '1' : '0')).join(''),
    repeats ? '1' : '0',
    s.mapID,
    String(s.suction),
    String(s.water),
    s.rooms.length ? [...s.rooms].sort((a, b) => a - b).join(',') : '0',
  ].join('-');
}

export const encodeAll = (list) =>
  [...list].sort((a, b) => a.id - b.id).map(encodeSchedule).join(';');

export function daysText(days) {
  const selected = days.map((on, i) => (on ? i : -1)).filter((i) => i >= 0);
  if (selected.length === 0) return 'Once';
  if (selected.length === 7) return 'Every day';
  const key = selected.join(',');
  if (key === '1,2,3,4,5') return 'Weekdays';
  if (key === '0,6') return 'Weekends';
  return DISPLAY_ORDER.filter((i) => days[i]).map((i) => DAY_NAMES[i]).join(', ');
}

export const timeText = (s) => `${pad(s.hour)}:${pad(s.minute)}`;
