import { api, tool, ensureService, mapImage, errorText } from './api.js';
import { parseAll, encodeAll, daysText, timeText } from './schedules.js';

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

// The app's names for the robot's modes, as the status tool reports them.
const MODE_BY_NAME = {
  'Vacuuming': 'vacuum',
  'Vacuuming and mopping': 'vacuum_and_mop',
  'Mopping': 'mop',
  'Vacuuming before mopping': 'mop_after_vacuum',
};
const ROOM_COLORS = ['#30d158', '#ff9f0a', '#64d2ff', '#ff375f', '#bf5af2', '#ffd60a', '#ac8e68', '#0a84ff'];
const SUCTION_LEVELS = ['silent', 'standard', 'strong', 'max'];
const MOP_LEVELS = ['low', 'medium', 'high'];
const CONSUMABLES = [
  ['Main brush', 'mainBrushPercentLeft'],
  ['Side brush', 'sideBrushPercentLeft'],
  ['Filter', 'filterPercentLeft'],
  ['Mop pads', 'mopPadPercentLeft'],
];
const REPLACE_BELOW = 20; // percent left
const POLL_MS = 2500;
const DRIVE_PULSE_MS = 300;
const DRIVE_STEP_MS = 400;

const DIRECTIONS = {
  forward: { key: ['ArrowUp', 'w', 'W'], sign: [1, 0] },
  back: { key: ['ArrowDown', 's', 'S'], sign: [-1, 0] },
  left: { key: ['ArrowLeft', 'a', 'A'], sign: [0, 1] },
  right: { key: ['ArrowRight', 'd', 'D'], sign: [0, -1] },
};

const state = {
  status: null,
  online: false,
  rooms: [],
  selected: new Set(),
  roomsLoadedAt: 0,
  polling: false,
  error: '',
};
const drive = { speed: 300, direction: null, timer: null, inFlight: false };

// MARK: - Helpers

let toastTimer = null;
function toast(message) {
  const el = $('#toast');
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
}

function setChecked(group, value) {
  for (const button of group.querySelectorAll('[data-value]')) {
    button.setAttribute('aria-checked', String(button.dataset.value === value));
  }
}

function alertItem(text, kind = '') {
  const li = document.createElement('li');
  if (kind) li.className = kind;
  li.textContent = text;
  return li;
}

// MARK: - Status

function render() {
  const s = state.status;
  const online = Boolean(s && s.online && !s.error);
  const dot = $('#online-dot');
  dot.className = 'dot';

  if (!s) {
    $('#online').textContent = 'Offline';
    $('#state').textContent = state.error || 'Can’t reach the robot';
  } else if (!online) {
    $('#online').textContent = 'Offline';
    $('#state').textContent = s.state ?? 'Can’t reach the robot';
  } else {
    $('#online').textContent = 'Online';
    dot.classList.add(s.fault ? 'warn' : s.busy ? 'busy' : 'ok');
    $('#state').textContent = s.state ?? '';
  }

  const battery = s?.batteryPercent;
  $('#battery-text').textContent = battery == null ? '--%' : `${battery}%`;
  const fill = $('#battery-fill');
  fill.style.width = battery == null ? '0' : `${Math.max(0, Math.min(100, battery))}%`;
  fill.style.background = battery != null && battery <= REPLACE_BELOW ? 'var(--orange)' : 'var(--green)';

  const alerts = $('#alerts');
  alerts.replaceChildren();
  if (!s && state.error) alerts.append(alertItem(state.error, 'error'));
  if (s?.fault) alerts.append(alertItem(s.fault.description ?? `Error ${s.fault.code}`, 'error'));
  if (s?.note) alerts.append(alertItem(s.note));
  for (const [label, key] of CONSUMABLES) {
    const left = s?.consumables?.[key];
    if (left != null && left <= REPLACE_BELOW) alerts.append(alertItem(`${label} ${left}%: replace soon`, 'warn'));
  }

  const busy = Boolean(s?.busy);
  $('#clean-all-label').textContent = busy ? 'Pause' : 'Clean whole house';
  $('#clean-all').classList.toggle('prominent', !busy);
  $('#clean-all').disabled = !online;
  $('#home').disabled = !online;
  $('#more').disabled = !online;

  setChecked($('#mode'), MODE_BY_NAME[s?.cleaningMode] ?? '');
  const suction = s?.suction?.toLowerCase();
  setChecked($('#suction'), suction ?? '');
  const mop = s?.mopLevel?.toLowerCase();
  setChecked($('#mop'), mop ?? '');
  $('#suction-label').textContent = s?.suction ?? '';
  $('#mop-label').textContent = s?.mopLevel ?? '';
  litBars($('#suction'), SUCTION_LEVELS.indexOf(suction));
  litBars($('#mop'), MOP_LEVELS.indexOf(mop));

  for (const control of $$('#mode button, #suction button, #mop button')) control.disabled = !online;
  renderRooms();
}

function litBars(group, level) {
  $$('button', group).forEach((button, index) => button.classList.toggle('lit', index <= level));
}

async function poll() {
  if (state.polling) return;
  state.polling = true;
  try {
    state.status = await tool('get_status', {});
    state.error = '';
    state.online = Boolean(state.status.online && !state.status.error);
    if (state.online && Date.now() - state.roomsLoadedAt > 60_000) loadRooms();
  } catch (error) {
    state.status = null;
    state.online = false;
    state.roomsLoadedAt = 0;
    state.error = errorText(error);
  } finally {
    state.polling = false;
    render();
  }
}

// MARK: - Rooms

async function loadRooms() {
  try {
    state.rooms = await tool('list_rooms', {});
    state.roomsLoadedAt = Date.now();
    state.selected = new Set([...state.selected].filter((id) => state.rooms.some((room) => room.id === id)));
    renderRooms();
  } catch (error) {
    toast(errorText(error));
  }
}

function renderRooms() {
  const list = $('#rooms');
  list.replaceChildren();
  $('#rooms-empty').hidden = state.rooms.length > 0;
  state.rooms.forEach((room, index) => {
    const item = document.createElement('li');
    const label = document.createElement('label');
    label.className = 'room';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = state.selected.has(room.id);
    box.disabled = !state.online;
    box.addEventListener('change', () => {
      if (box.checked) state.selected.add(room.id); else state.selected.delete(room.id);
      renderRooms();
    });
    const swatch = document.createElement('span');
    swatch.className = 'swatch';
    swatch.style.background = ROOM_COLORS[index % ROOM_COLORS.length];
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = room.name;
    const area = document.createElement('span');
    area.className = 'area';
    area.textContent = `${room.areaM2.toFixed(1)} m²`;
    label.append(box, swatch, name, area);
    item.append(label);
    list.append(item);
  });
  const cleanButton = $('#clean-rooms');
  cleanButton.disabled = !state.online || state.selected.size === 0 || Boolean(state.status?.busy);
  cleanButton.textContent = state.selected.size > 0 ? `Clean ${state.selected.size} selected` : 'Clean selected rooms';
}

// MARK: - Commands

async function act(name, args = {}, done = '') {
  try {
    await tool(name, args);
    if (done) toast(done);
  } catch (error) {
    toast(errorText(error));
  }
  await poll();
}

async function refreshMap(fresh) {
  const button = $('#refresh-map');
  button.disabled = true;
  $('#map-hint').textContent = 'Drawing the map…';
  try {
    const src = await mapImage(fresh);
    const image = $('#map');
    image.src = src;
    image.hidden = false;
    $('#map-empty').hidden = true;
    $('#map-hint').textContent = state.selected.size ? '' : 'Select rooms on the right to clean only those.';
  } catch (error) {
    $('#map-hint').textContent = errorText(error);
  } finally {
    button.disabled = false;
  }
}

// MARK: - Driving

function stopHold() {
  if (!drive.direction) return;
  clearInterval(drive.timer);
  drive.timer = null;
  drive.direction = null;
  $$('.pad-btn.held').forEach((button) => button.classList.remove('held'));
  // A short zero-speed step makes the robot stop at once instead of finishing the last step.
  tool('drive', { velocity: 0, rotation: 0, duration_ms: 100 }).catch(() => {});
}

async function pulse() {
  if (drive.inFlight || !drive.direction) return;
  const [v, r] = DIRECTIONS[drive.direction].sign;
  drive.inFlight = true;
  try {
    await tool('drive', { velocity: v * drive.speed, rotation: r * 90, duration_ms: DRIVE_STEP_MS });
  } catch (error) {
    toast(errorText(error));
    stopHold();
  } finally {
    drive.inFlight = false;
  }
}

function startHold(direction, button) {
  if (drive.direction === direction) return;
  stopHold();
  drive.direction = direction;
  button?.classList.add('held');
  pulse();
  drive.timer = setInterval(pulse, DRIVE_PULSE_MS);
}

// MARK: - Settings

async function openSettings() {
  $('#settings-sheet').hidden = false;
  showBackdrop();
  try {
    const config = await api('GET', '/v1/config');
    const robot = config.robot;
    $('#settings-state').textContent = robot
      ? `Robot at ${robot.ip}${config.cloud ? ' · signed in to Xiaomi' : ''}`
      : 'Not set up yet. Enter your robot’s details below.';
    if (robot) {
      $('#robot-ip').value = robot.ip;
      $('#robot-token').value = robot.token;
      $('#robot-did').value = robot.did;
    }
  } catch (error) {
    $('#settings-state').textContent = errorText(error);
  }
}

async function saveRobot(event) {
  event.preventDefault();
  const robot = {
    ip: $('#robot-ip').value.trim(),
    token: $('#robot-token').value.trim().toLowerCase(),
    did: $('#robot-did').value.trim(),
  };
  if (!/^[0-9a-f]{32}$/.test(robot.token)) return toast('The token is 32 letters and numbers (0–9, a–f).');
  if (!/^\d+$/.test(robot.did)) return toast('The device ID is numbers only.');
  try {
    await api('POST', '/v1/config', { robot });
    toast('Saved. Connecting…');
    await ensureService();
    await poll();
    await loadRooms();
    closeSheets();
  } catch (error) {
    toast(errorText(error));
  }
}

function showBackdrop() { $('#backdrop').hidden = false; }
function closeSheets() {
  stopHold();
  $('#drive-sheet').hidden = true;
  $('#schedules-sheet').hidden = true;
  $('#settings-sheet').hidden = true;
  $('#backdrop').hidden = true;
}

// MARK: - Schedules

const schedules = { list: [], editing: null };

async function guarded(action, done = '') {
  try {
    await action();
    if (done) toast(done);
  } catch (error) {
    toast(errorText(error));
  }
}

async function loadSchedules() {
  const properties = await api('GET', '/v1/properties');
  schedules.list = parseAll(properties.values?.['8.2'] ?? '');
  renderSchedules();
}

// The robot takes the whole list in one value, as the Mac app writes it.
async function writeSchedules(list) {
  await api('POST', '/v1/miio', {
    method: 'set_properties',
    params: [{ did: '8.2', siid: 8, piid: 2, value: encodeAll(list) }],
  });
  await loadSchedules();
}

async function deleteSchedule(schedule) {
  try {
    await api('POST', '/v1/miio', {
      method: 'action',
      params: { did: '8.1', siid: 8, aiid: 1, in: [{ piid: 3, value: String(schedule.id) }] },
    });
    await loadSchedules();
  } catch {
    // The same fallback as the Mac app: write the list again without this schedule.
    await writeSchedules(schedules.list.filter((s) => s.id !== schedule.id));
  }
}

function roomsText(schedule) {
  if (!schedule.rooms.length) return 'Whole house';
  return schedule.rooms.map((id) => state.rooms.find((room) => room.id === id)?.name ?? `Room ${id}`).join(', ');
}

function renderSchedules() {
  const list = $('#schedule-list');
  list.replaceChildren();
  $('#schedule-empty').hidden = schedules.list.length > 0;
  for (const schedule of schedules.list) {
    const item = document.createElement('li');
    item.className = `schedule-row${schedule.isEnabled ? '' : ' off'}`;

    const toggle = document.createElement('input');
    toggle.type = 'checkbox';
    toggle.checked = schedule.isEnabled;
    toggle.setAttribute('aria-label', `Schedule at ${timeText(schedule)}`);
    toggle.addEventListener('change', () => guarded(
      () => writeSchedules(schedules.list.map((s) => (s.id === schedule.id ? { ...s, isEnabled: toggle.checked } : s))),
      'Schedule saved.',
    ));

    const info = document.createElement('div');
    info.className = 'sched-info';
    const time = document.createElement('div');
    time.className = 'sched-time';
    time.textContent = timeText(schedule);
    const detail = document.createElement('div');
    detail.className = 'muted';
    detail.textContent = `${daysText(schedule.days)} · ${roomsText(schedule)}`;
    info.append(time, detail);

    const remove = document.createElement('button');
    remove.className = 'btn';
    remove.type = 'button';
    remove.textContent = 'Delete';
    remove.setAttribute('aria-label', `Delete schedule at ${timeText(schedule)}`);
    remove.addEventListener('click', () => guarded(() => deleteSchedule(schedule), 'Schedule deleted.'));

    item.append(toggle, info, remove);
    list.append(item);
  }
}

function renderEditorRooms(selected) {
  const list = $('#sch-rooms');
  list.replaceChildren();
  state.rooms.forEach((room, index) => {
    const item = document.createElement('li');
    const label = document.createElement('label');
    label.className = 'room';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = String(room.id);
    box.checked = selected.includes(room.id);
    const swatch = document.createElement('span');
    swatch.className = 'swatch';
    swatch.style.background = ROOM_COLORS[index % ROOM_COLORS.length];
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = room.name;
    label.append(box, swatch, name);
    item.append(label);
    list.append(item);
  });
}

function openEditor(schedule) {
  schedules.editing = schedule;
  $('#schedule-form-title').textContent = schedule ? 'Edit schedule' : 'New schedule';
  $('#sch-time').value = schedule ? timeText(schedule) : '09:00';
  const days = schedule ? schedule.days : [false, true, true, true, true, true, false];
  for (const button of $$('#sch-days button')) {
    button.setAttribute('aria-pressed', String(days[Number(button.dataset.day)] === true));
  }
  renderEditorRooms(schedule?.rooms ?? []);
  const level = schedule ? SUCTION_LEVELS[schedule.suction] : state.status?.suction?.toLowerCase() ?? 'standard';
  setChecked($('#sch-suction'), level ?? 'standard');
  $('#schedules-list-view').hidden = true;
  $('#schedule-form').hidden = false;
}

function closeEditor() {
  schedules.editing = null;
  $('#schedule-form').hidden = true;
  $('#schedules-list-view').hidden = false;
}

async function saveSchedule(event) {
  event.preventDefault();
  const [hour, minute] = $('#sch-time').value.split(':').map(Number);
  const days = Array(7).fill(false);
  for (const button of $$('#sch-days button')) {
    days[Number(button.dataset.day)] = button.getAttribute('aria-pressed') === 'true';
  }
  const rooms = $$('#sch-rooms input:checked').map((box) => Number(box.value)).sort((a, b) => a - b);
  const level = $('#sch-suction [aria-checked="true"]')?.dataset.value ?? 'standard';
  const base = schedules.editing;
  const first = schedules.list[0];
  const next = {
    id: base?.id ?? Math.max(0, ...schedules.list.map((s) => s.id)) + 1,
    isEnabled: base?.isEnabled ?? true,
    hour,
    minute,
    days,
    mapID: base?.mapID ?? first?.mapID ?? '0',
    suction: SUCTION_LEVELS.indexOf(level),
    water: base?.water ?? first?.water ?? 0,
    rooms,
  };
  await guarded(async () => {
    await writeSchedules([...schedules.list.filter((s) => s.id !== next.id), next]);
    closeEditor();
  }, 'Schedule saved.');
}

async function openSchedules() {
  $('#schedules-sheet').hidden = false;
  showBackdrop();
  closeEditor();
  await guarded(loadSchedules);
}

// MARK: - Wiring

function wire() {
  $('#refresh-map').addEventListener('click', () => refreshMap(true));

  $('#clean-all').addEventListener('click', () => {
    if (state.status?.busy) act('stop_cleaning', {}, 'Paused.');
    else act('start_cleaning', {}, 'Cleaning the whole house.');
  });
  $('#home').addEventListener('click', () => act('go_home', {}, 'Going home.'));

  const more = $('#more');
  more.addEventListener('click', () => {
    const open = $('#more-menu').hidden;
    $('#more-menu').hidden = !open;
    more.setAttribute('aria-expanded', String(open));
  });
  $('#locate').addEventListener('click', () => act('locate', {}, 'The robot is saying “I’m here”.'));
  $('#empty-bin').addEventListener('click', () => act('empty_bin', {}, 'Emptying the bin.'));

  $('#clean-rooms').addEventListener('click', () => {
    const rooms = [...state.selected];
    if (!rooms.length) return;
    act('clean_rooms', { rooms }, `Cleaning ${rooms.length} room${rooms.length > 1 ? 's' : ''}.`);
  });

  for (const button of $$('#mode button')) {
    button.addEventListener('click', () => act('set_cleaning_mode', { mode: button.dataset.value }));
  }
  for (const button of $$('#suction button')) {
    button.addEventListener('click', () => act('set_suction', { level: button.dataset.value }));
  }
  for (const button of $$('#mop button')) {
    button.addEventListener('click', () => act('set_mop_level', { level: button.dataset.value }));
  }

  $('#schedules-open').addEventListener('click', openSchedules);
  $('#schedules-close').addEventListener('click', closeSheets);
  $('#schedule-add').addEventListener('click', () => openEditor(null));
  $('#sch-cancel').addEventListener('click', closeEditor);
  $('#schedule-form').addEventListener('submit', saveSchedule);
  for (const button of $$('#sch-days button')) {
    button.addEventListener('click', () => button.setAttribute('aria-pressed', String(button.getAttribute('aria-pressed') !== 'true')));
  }
  for (const button of $$('#sch-suction button')) {
    button.addEventListener('click', () => setChecked($('#sch-suction'), button.dataset.value));
  }

  $('#drive-open').addEventListener('click', () => {
    $('#drive-sheet').hidden = false;
    showBackdrop();
  });
  $('#drive-close').addEventListener('click', closeSheets);
  $('#settings-open').addEventListener('click', openSettings);
  $('#settings-close').addEventListener('click', closeSheets);
  $('#backdrop').addEventListener('click', closeSheets);
  $('#robot-form').addEventListener('submit', saveRobot);

  for (const button of $$('#drive-speed button')) {
    button.addEventListener('click', () => {
      drive.speed = Number(button.dataset.value);
      setChecked($('#drive-speed'), button.dataset.value);
    });
  }
  setChecked($('#drive-speed'), String(drive.speed));

  for (const button of $$('.pad-btn')) {
    const direction = button.dataset.drive;
    button.addEventListener('pointerdown', (event) => { event.preventDefault(); startHold(direction, button); });
    for (const end of ['pointerup', 'pointercancel', 'pointerleave']) {
      button.addEventListener(end, stopHold);
    }
  }
  window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeSheets();
    if (event.repeat || $('#drive-sheet').hidden) return;
    const match = Object.entries(DIRECTIONS).find(([, d]) => d.key.includes(event.key));
    if (match) {
      event.preventDefault();
      startHold(match[0], document.querySelector(`.pad-btn[data-drive="${match[0]}"]`));
    }
  });
  window.addEventListener('keyup', (event) => {
    const match = Object.entries(DIRECTIONS).find(([, d]) => d.key.includes(event.key));
    if (match && drive.direction === match[0]) stopHold();
  });
  window.addEventListener('blur', stopHold);
}

async function init() {
  wire();
  try {
    await ensureService();
  } catch (error) {
    toast(errorText(error));
  }
  await poll();
  await loadRooms();
  if (state.online) refreshMap(false);
  setInterval(() => {
    if (!document.hidden && !drive.direction) poll();
  }, POLL_MS);
}

init();
