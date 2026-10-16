// Runs the page against the real vacuumd server (no robot attached), through the same HTTP calls the Windows shell makes.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { chromium } from 'playwright-core';

const here = dirname(fileURLToPath(import.meta.url));
const uiDir = resolve(here, '../ui');
const vacuumd = process.env.VACUUMD_BIN ?? resolve(here, '../../rust/target/release/vacuumd');
// CHROME_PATH picks a local Chromium; unset, Playwright uses the one it installed.
const chromePath = process.env.CHROME_PATH || undefined;
const shots = join(here, 'screenshots');
const PORT = 47231;
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };

let dataDir, daemon, server, base, browser, token;

async function send(method, path, body) {
  const response = await fetch(`http://127.0.0.1:${PORT}${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const value = text ? JSON.parse(text) : null;
  if (!response.ok) throw value?.error ?? `The robot service said no (${response.status}).`;
  return value;
}

// Stands in for the Windows shell's commands, using the real service.
async function invoke(command, args = {}) {
  if (command === 'ensure_service') return true;
  if (command === 'map_image') {
    const result = await send('POST', '/v1/tools/get_map_image', { fresh: args.fresh });
    const bytes = await readFile(result.path);
    return { image: `data:image/png;base64,${bytes.toString('base64')}`, transform: result.mapTransform };
  }
  if (command === 'api') return send(args.method, args.path, args.body ?? undefined);
  throw `Unknown command ${command}`;
}

async function waitForHealth() {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/health`);
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('vacuumd did not start');
}

before(async () => {
  if (!existsSync(vacuumd)) throw new Error(`Build vacuumd first: ${vacuumd}`);
  dataDir = await mkdtemp(join(tmpdir(), 'vacuum-live-'));
  daemon = spawn(vacuumd, ['serve'], { env: { ...process.env, VACUUMD_DIR: dataDir }, stdio: 'ignore' });
  await waitForHealth();
  token = (await readFile(join(dataDir, 'daemon-token'), 'utf8')).trim();

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
  daemon?.kill();
  if (dataDir) await rm(dataDir, { recursive: true, force: true });
});

async function openLive() {
  const context = await browser.newContext({ viewport: { width: 1180, height: 780 } });
  const page = await context.newPage();
  page.errors = [];
  page.on('pageerror', (e) => page.errors.push(String(e)));
  await page.exposeFunction('__invoke', invoke);
  await context.addInitScript(() => {
    window.__TAURI__ = { core: { invoke: (command, args) => window.__invoke(command, args) } };
  });
  await page.goto(base + '/index.html');
  return { page, context };
}

test('with no robot set up, the page says so and offers settings', async () => {
  const { page, context } = await openLive();
  await page.waitForFunction(() => document.querySelector('#state').textContent.includes('No robot is set up'));
  assert.match(await page.textContent('#state'), /vacuumd setup/);
  assert.equal(await page.isDisabled('#clean-all'), true);
  assert.deepEqual(page.errors, []);
  await page.screenshot({ path: join(shots, 'live-no-robot.png') });
  await context.close();
});

test('saving a robot in settings reaches the real service, which saves it', async () => {
  const { page, context } = await openLive();
  await page.waitForFunction(() => document.querySelector('#state').textContent.includes('No robot is set up'));
  await page.click('#settings-open');
  await page.fill('#robot-ip', '127.0.0.1');
  await page.fill('#robot-token', 'c'.repeat(32));
  await page.fill('#robot-did', '424242');
  await page.click('#robot-form button[type="submit"]');
  await page.waitForFunction(() => document.querySelector('#settings-sheet').hidden === true);

  const config = await send('GET', '/v1/config');
  assert.deepEqual(config.robot, { ip: '127.0.0.1', token: 'c'.repeat(32), did: '424242' });

  // The robot doesn't answer at that address, so the page reports that instead of pretending it is online.
  await page.waitForFunction(() => document.querySelector('#online').textContent === 'Offline');
  assert.equal(await page.isDisabled('#clean-all'), true);
  assert.notEqual(await page.textContent('#state'), '');
  assert.deepEqual(page.errors, []);
  await context.close();
});

test('a saved robot is shown again when settings reopen', async () => {
  const { page, context } = await openLive();
  await page.click('#settings-open');
  await page.waitForFunction(() => document.querySelector('#robot-ip').value === '127.0.0.1');
  assert.equal(await page.inputValue('#robot-did'), '424242');
  assert.match(await page.textContent('#settings-state'), /Robot at 127\.0\.0\.1/);
  await context.close();
});

test('the map says why there is no picture yet', async () => {
  const { page, context } = await openLive();
  await page.click('#refresh-map');
  await page.waitForFunction(() => document.querySelector('#map-hint').textContent.length > 0 && document.querySelector('#map-hint').textContent !== 'Drawing the map…');
  assert.equal(await page.isHidden('#map'), true);
  await context.close();
});
