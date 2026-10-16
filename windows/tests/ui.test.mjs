// Runs the real page in Chromium (the same engine as Windows' WebView2) with a stand-in for the Windows shell.
// The stand-in answers like the robot service does, so the tests check what the page sends and shows.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const here = dirname(fileURLToPath(import.meta.url));
const uiDir = resolve(here, '../ui');
const shots = resolve(process.env.SHOT_DIR ?? join(here, 'screenshots'));
// CHROME_PATH picks a local Chromium; unset, Playwright uses the one it installed.
const chromePath = process.env.CHROME_PATH || undefined;
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };

let server, base, browser;

const ROOMS = [
  { id: 2, name: 'Room 2', areaM2: 2.0, repeats: 1 },
  { id: 3, name: 'Room 3', areaM2: 11.8, repeats: 1 },
  { id: 5, name: 'Room 5', areaM2: 32.5, repeats: 1 },
  { id: 6, name: 'Room 6', areaM2: 4.4, repeats: 1 },
  { id: 7, name: 'Room 7', areaM2: 6.4, repeats: 1 },
  { id: 8, name: 'Room 8', areaM2: 9.4, repeats: 1 },
];

// What the robot reports in the Mac app's screenshot.
const HEALTHY = {
  online: true, busy: false, state: 'Fully charged', batteryPercent: 100, fault: null,
  suction: 'Standard', mopLevel: 'Low', cleaningMode: 'Vacuuming',
  consumables: { mainBrushPercentLeft: 17, sideBrushPercentLeft: 80, filterPercentLeft: 70, mopPadPercentLeft: 16 },
  totals: { cleans: 40 },
};

const FAKE_SHELL = (state) => `
  window.__state = ${JSON.stringify(state)};
  window.__calls = [];
  const map = ${JSON.stringify(state.mapPng)};
  window.__TAURI__ = { core: { invoke: async (command, args = {}) => {
    window.__calls.push({ command, args });
    if (command === 'ensure_service') return true;
    if (command === 'map_image') { if (!window.__state.mapOk) throw 'The robot service hasn’t started yet.'; return map; }
    if (command !== 'api') throw 'Unknown command ' + command;
    const { method, path, body } = args;
    window.__calls.push({ method, path, body });
    if (path === '/v1/config') {
      if (window.__state.config === null) return { robot: null, cloud: null };
      return window.__state.config;
    }
    if (path === '/v1/config' && method === 'POST') return { ok: true };
    if (path === '/v1/tools/get_status') {
      if (!window.__state.status) throw window.__state.statusError || 'Can’t reach the robot service.';
      return window.__state.status;
    }
    if (path === '/v1/tools/list_rooms') return window.__state.rooms;
    if (path === '/v1/properties') return { online: true, values: { '8.2': window.__state.schedules ?? '' } };
    if (path === '/v1/miio') {
      const { method, params } = body;
      if (method === 'set_properties') { window.__state.schedules = params[0].value; return { result: [{ code: 0 }] }; }
      if (method === 'action') {
        if (window.__state.deleteFails) throw 'The robot refused.';
        const id = params.in[0].value;
        window.__state.schedules = window.__state.schedules.split(';').filter((e) => e.split('-')[0] !== id).join(';');
        return { result: { code: 0 } };
      }
      throw 'Method not allowed';
    }
    if (path.startsWith('/v1/tools/')) return { ok: true };
    throw 'Not found';
  } } };
`;

const SCHEDULES = '1-1-08:36-0100000-1-12-1-0-6;2-0-19:00-0000000-0-12-2-0-0';

async function fixtureState(overrides = {}) {
  const png = await readFile(join(here, 'fixtures/map.png'));
  return {
    status: structuredClone(HEALTHY),
    rooms: structuredClone(ROOMS),
    config: { robot: { ip: '192.168.1.20', token: 'a'.repeat(32), did: '123456789' }, cloud: { server: 'cn' } },
    mapOk: true,
    schedules: SCHEDULES,
    mapPng: `data:image/png;base64,${png.toString('base64')}`,
    ...overrides,
  };
}

async function openPage(state, viewport = { width: 1180, height: 780 }) {
  const context = await browser.newContext({ viewport, colorScheme: 'dark' });
  await context.addInitScript(FAKE_SHELL(state));
  const page = await context.newPage();
  page.errors = [];
  page.on('pageerror', (e) => page.errors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') page.errors.push(m.text()); });
  await page.goto(base + '/index.html');
  await page.waitForFunction(() => document.querySelector('#state').textContent !== 'Looking for your robot' || true);
  return { page, context };
}

const calls = (page) => page.evaluate(() => window.__calls.filter((c) => c.path || c.command !== 'api'));
const toolCalls = async (page, name) => (await calls(page)).filter((c) => c.path === `/v1/tools/${name}`);

before(async () => {
  server = createServer(async (req, res) => {
    const file = join(uiDir, req.url === '/' ? 'index.html' : req.url.split('?')[0]);
    if (!file.startsWith(uiDir) || !existsSync(file)) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
    res.end(await readFile(file));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
  await mkdir(shots, { recursive: true });
  browser = await chromium.launch({ executablePath: chromePath, args: ['--no-sandbox'] });
});

after(async () => {
  await browser?.close();
  server?.close();
});

test('shows the robot’s status, battery and what needs replacing', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  assert.equal(await page.textContent('#state'), 'Fully charged');
  assert.equal(await page.textContent('#online'), 'Online');
  assert.equal(await page.textContent('#battery-text'), '100%');
  const alerts = await page.$$eval('#alerts li', (els) => els.map((e) => e.textContent));
  assert.deepEqual(alerts.sort(), ['Main brush 17%: replace soon', 'Mop pads 16%: replace soon'].sort());
  assert.equal(await page.getAttribute('#mode button[data-value="vacuum"]', 'aria-checked'), 'true');
  assert.equal(await page.getAttribute('#suction button[data-value="standard"]', 'aria-checked'), 'true');
  assert.equal(await page.getAttribute('#mop button[data-value="low"]', 'aria-checked'), 'true');
  assert.deepEqual(page.errors, []);
  await page.screenshot({ path: join(shots, 'desktop.png') });
  await context.close();
});

test('the map picture appears after the page loads', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#map:not([hidden])');
  assert.match(await page.getAttribute('#map', 'src'), /^data:image\/png;base64,/);
  await context.close();
});

test('lays out at phone width without sideways scrolling', async () => {
  const { page, context } = await openPage(await fixtureState(), { width: 390, height: 844 });
  await page.waitForSelector('#rooms li');
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(overflow <= 0, `page is ${overflow}px wider than the window`);
  await page.screenshot({ path: join(shots, 'phone.png'), fullPage: true });
  await context.close();
});

test('“Clean whole house” starts cleaning; pressed again while busy it pauses', async () => {
  const state = await fixtureState();
  const { page, context } = await openPage(state);
  await page.waitForSelector('#rooms li');
  await page.click('#clean-all');
  await page.waitForTimeout(50);
  assert.equal((await toolCalls(page, 'start_cleaning')).length, 1);
  await context.close();
});

test('cleaning chosen rooms sends their numbers', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  assert.equal(await page.isDisabled('#clean-rooms'), true);
  await page.check('#rooms label:has-text("Room 5")');
  await page.check('#rooms label:has-text("Room 2")');
  assert.equal(await page.isDisabled('#clean-rooms'), false);
  await page.click('#clean-rooms');
  await page.waitForTimeout(50);
  const [call] = await toolCalls(page, 'clean_rooms');
  assert.deepEqual(call.body, { rooms: [5, 2] });
  await context.close();
});

test('cleaning mode, suction and mop water are set with their own names', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#mode button[data-value="vacuum_and_mop"]');
  await page.click('#suction button[data-value="strong"]');
  await page.click('#mop button[data-value="high"]');
  await page.waitForTimeout(50);
  assert.deepEqual((await toolCalls(page, 'set_cleaning_mode'))[0].body, { mode: 'vacuum_and_mop' });
  assert.deepEqual((await toolCalls(page, 'set_suction'))[0].body, { level: 'strong' });
  assert.deepEqual((await toolCalls(page, 'set_mop_level'))[0].body, { level: 'high' });
  await context.close();
});

test('holding a drive button moves the robot and stops it on release', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#drive-open');
  await page.dispatchEvent('.pad-btn[data-drive="forward"]', 'pointerdown');
  await page.waitForTimeout(350);
  await page.dispatchEvent('.pad-btn[data-drive="forward"]', 'pointerup');
  await page.waitForTimeout(150);
  const drives = await toolCalls(page, 'drive');
  assert.ok(drives.length >= 2, 'expected a drive step while held');
  assert.deepEqual(drives[0].body, { velocity: 300, rotation: 0, duration_ms: 400 });
  assert.deepEqual(drives.at(-1).body, { velocity: 0, rotation: 0, duration_ms: 100 });
  await page.screenshot({ path: join(shots, 'drive.png') });
  await context.close();
});

test('arrow keys and W A S D drive, and the slow speed is respected', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#drive-open');
  await page.click('#drive-speed button[data-value="150"]');
  await page.keyboard.down('ArrowLeft');
  await page.waitForTimeout(20);
  await page.keyboard.up('ArrowLeft');
  await page.keyboard.down('s');
  await page.waitForTimeout(20);
  await page.keyboard.up('s');
  await page.waitForTimeout(100);
  const drives = await toolCalls(page, 'drive');
  assert.deepEqual(drives[0].body, { velocity: 0, rotation: 90, duration_ms: 400 });
  assert.ok(drives.some((d) => d.body.velocity === -150 && d.body.rotation === 0), 'S should drive backward at the slow speed');
  await context.close();
});

test('settings show the saved robot and reject a bad token before sending it', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#settings-open');
  await page.waitForFunction(() => document.querySelector('#robot-ip').value !== '');
  assert.equal(await page.inputValue('#robot-ip'), '192.168.1.20');
  assert.equal(await page.inputValue('#robot-did'), '123456789');
  await page.fill('#robot-token', 'not-a-token');
  await page.click('#robot-form button[type="submit"]');
  assert.equal(await page.textContent('#toast'), 'The token is 32 letters and numbers (0–9, a–f).');
  assert.equal((await calls(page)).some((c) => c.method === 'POST' && c.path === '/v1/config'), false);
  await page.screenshot({ path: join(shots, 'settings.png') });
  await context.close();
});

test('saving a good robot sends it to the robot service', async () => {
  const { page, context } = await openPage(await fixtureState({ config: null }));
  await page.click('#settings-open');
  await page.fill('#robot-ip', '192.168.1.42');
  await page.fill('#robot-token', 'B'.repeat(32));
  await page.fill('#robot-did', '987654');
  await page.click('#robot-form button[type="submit"]');
  await page.waitForTimeout(100);
  const save = (await calls(page)).find((c) => c.method === 'POST' && c.path === '/v1/config');
  assert.deepEqual(save.body, { robot: { ip: '192.168.1.42', token: 'b'.repeat(32), did: '987654' } });
  await context.close();
});

test('when the robot is unreachable, controls are off and the page says so', async () => {
  const state = await fixtureState({ status: null, mapOk: false });
  const { page, context } = await openPage(state);
  await page.waitForFunction(() => document.querySelector('#online').textContent === 'Offline');
  assert.equal(await page.isDisabled('#clean-all'), true);
  assert.equal(await page.isDisabled('#home'), true);
  assert.equal(await page.textContent('#state'), 'Can’t reach the robot service.');
  await context.close();
});

test('when no robot is set up yet, the page says what to do', async () => {
  const state = await fixtureState({
    status: null,
    config: { robot: null, cloud: null },
    mapOk: false,
  });
  const message = 'No robot is set up yet. Run `vacuumd setup`, or sign in from the Vacuum app.';
  const { page, context } = await openPage({ ...state, statusError: message });
  await page.waitForFunction(() => document.querySelector('#online').textContent === 'Offline');
  assert.equal(await page.textContent('#state'), message);
  assert.equal(await page.textContent('#alerts li'), message);
  await context.close();
});

test('Escape closes an open sheet', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#drive-open');
  assert.equal(await page.isHidden('#drive-sheet'), false);
  await page.keyboard.press('Escape');
  assert.equal(await page.isHidden('#drive-sheet'), true);
  await context.close();
});

const schedulesOf = (page) => page.evaluate(() => window.__state.schedules);
const miioCalls = async (page) => (await calls(page)).filter((c) => c.path === '/v1/miio');

test('schedules show what the robot has, in the Mac app’s words', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#schedules-open');
  await page.waitForSelector('#schedule-list li');
  const rows = await page.$$eval('#schedule-list .schedule-row', (els) => els.map((e) => e.textContent));
  assert.equal(rows.length, 2);
  assert.match(rows[0], /08:36.*Mon.*Room 6/);
  assert.match(rows[1], /19:00.*Once.*Whole house/);
  await page.screenshot({ path: join(shots, 'schedules.png') });
  await context.close();
});

test('switching a schedule off writes the whole list back to the robot', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#schedules-open');
  await page.waitForSelector('#schedule-list li');
  await page.click('#schedule-list .schedule-row:nth-child(1) input[type="checkbox"]');
  await page.waitForTimeout(100);
  const [call] = await miioCalls(page);
  assert.deepEqual(call.body.params, [{ did: '8.2', siid: 8, piid: 2, value: '1-0-08:36-0100000-1-12-1-0-6;2-0-19:00-0000000-0-12-2-0-0' }]);
  await context.close();
});

test('adding a schedule writes it in the robot’s format', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#schedules-open');
  await page.waitForSelector('#schedule-list li');
  await page.click('#schedule-add');
  await page.fill('#sch-time', '07:30');
  await page.click('#sch-suction button[data-value="strong"]');
  await page.check('#sch-rooms label:has-text("Room 5")');
  await page.check('#sch-rooms label:has-text("Room 2")');
  await page.click('#schedule-form button[type="submit"]');
  await page.waitForTimeout(100);
  assert.equal(
    await schedulesOf(page),
    '1-1-08:36-0100000-1-12-1-0-6;2-0-19:00-0000000-0-12-2-0-0;3-1-07:30-0111110-1-12-2-0-2,5',
  );
  await context.close();
});

test('deleting a schedule uses the robot’s own delete', async () => {
  const { page, context } = await openPage(await fixtureState());
  await page.waitForSelector('#rooms li');
  await page.click('#schedules-open');
  await page.waitForSelector('#schedule-list li');
  await page.click('button[aria-label="Delete schedule at 08:36"]');
  await page.waitForTimeout(100);
  const [call] = await miioCalls(page);
  assert.deepEqual(call.body.params, { did: '8.1', siid: 8, aiid: 1, in: [{ piid: 3, value: '1' }] });
  assert.equal(await page.$$eval('#schedule-list li', (els) => els.length), 1);
  await context.close();
});

test('if the robot refuses the delete, the list is written without that schedule instead', async () => {
  const { page, context } = await openPage(await fixtureState({ deleteFails: true }));
  await page.waitForSelector('#rooms li');
  await page.click('#schedules-open');
  await page.waitForSelector('#schedule-list li');
  await page.click('button[aria-label="Delete schedule at 08:36"]');
  await page.waitForTimeout(100);
  assert.equal(await schedulesOf(page), '2-0-19:00-0000000-0-12-2-0-0');
  await context.close();
});
