# Vacuum for Windows

A Windows app for the Xiaomi robot vacuum. It has the same layout as the Mac app: the map on the left, and the
robot's status, rooms, cleaning settings and driving on the right, in the same glass style.

It is a small window over the robot service (`vacuumd`, in `../rust`). The service owns the connection to the
robot, and the Mac app and the Windows app use the same service and the same settings folder.

## Layout

| Path | What it is |
|---|---|
| `ui/` | The page: plain HTML, CSS and JavaScript (no build step). `styles.css` holds the glass design tokens. |
| `src-tauri/` | The Windows shell (Rust + Tauri). It starts `vacuumd` if needed, forwards the page's requests to it, and adds the Mica or Acrylic backdrop. |
| `tests/` | Page tests in Chromium: `ui.test.mjs` (with a stand-in for the shell) and `live.test.mjs` (against the real `vacuumd`). |

## What works

- Status: online, state, battery, fault, and consumables that need replacing.
- Cleaning: whole house, pause, go home, locate, empty bin.
- Rooms: pick rooms and clean just those.
- Settings: cleaning mode, suction, mop water.
- Map: draws the robot's map through the service (Refresh map).
- Drive: a pad you hold, or the arrow keys / W A S D, with slow and normal speeds.
- Sign in to Xiaomi inside the app: a QR code and Xiaomi's own sign-in page, then pick the robot. The service keeps the sign-in and tokens; the window only sees names and addresses.
- Settings sheet: see and change the robot's address, token and device ID.
- Schedules: list, turn on or off, add, edit and delete. They use the same format and robot commands as the Mac app.
- Room names, showing and hiding rooms, and per-room settings (suction, mop water, cleaning, passes). Saved in the same files the Mac app uses.
- Furniture and belongings: add, drag into place, resize, rename and remove. They are placed on the robot's map and kept on this PC only, as on the Mac.

## Not yet (the Mac app has these)

- Insights (cleaning history) and the problem log.
- Editing the map: no-go zones, virtual walls, and merging or dividing rooms (these change the robot's saved map).
- Choosing rooms by tapping them on the map (the map shows the picture only).
- Signing in to Xiaomi inside the app: run `vacuumd setup` once in a terminal, then the app connects.
- Resetting consumables after you replace them.

## Build and test

Requirements for building on Windows: Rust (stable), and the WebView2 runtime (already on Windows 10 and 11).

```powershell
cd rust;          cargo build --release    # the robot service
cd ..\windows\src-tauri; cargo build --release    # the app
```

Put `vacuumd.exe` next to the app's program. The app starts it when it isn't running.

Page tests (Chromium):

```bash
cd windows/tests
npm ci
npx playwright-core install chromium     # or set CHROME_PATH to a Chromium you already have
npm test                                 # stand-in for the shell, plus schedule-format tests
VACUUMD_BIN=../../rust/target/release/vacuumd npm run test:live   # against the real service
```

CI runs all of this on every push (see `.github/workflows/windows-app.yml`) and builds the Windows zip.

## Design

- **Glass:** each panel uses a translucent layer with a blur and saturation boost, a bright top edge and a soft
  shadow. The window behind it is Mica on Windows 11 (Acrylic on older versions), so the glass picks up the
  desktop color. Colors come from tokens in `styles.css`, with light and dark themes that follow Windows.
- **Layout:** a two-column layout; on narrow windows the panel moves under the map.
