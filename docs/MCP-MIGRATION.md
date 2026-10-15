# Migration plan: robot logic in a daemon, app and agents as clients

Goal: one process (`vacuumd`) owns the connection to the robot. The Mac app and any AI agent (MCP) call the same tools.

## Decisions
- **The server is Rust** (`rust/`), so it runs on Windows, macOS and Linux. The Swift daemon (`Sources/vacuumd`) was the first prototype and the reference the Rust port was checked against; it can be removed once the app talks to the Rust server.
- Runs as a launch agent, so agents work while the app is closed.
- The map is not an agent tool. Agents get `list_rooms` (ids, names, areas) only.
- All tools are open to agents without confirmation, protected by local tokens, loopback-only binding and Host/Origin checks. Agents and the Mac app have separate tokens (agent token: tools only); the app's raw robot channel is limited to what the app sends; every change is recorded (`vacuumd audit`). See SECURITY.md.

## Layout (Rust, the real server)
- `rust/src`: `miio` (robot protocol), `cloud` (Xiaomi sign-in, device list, map download), `map`, `service` (poll, commands, rooms, drive), `tools`, `server` (HTTP + MCP), `install` (launchd / Task Scheduler / systemd), `main` (CLI incl. `setup`).
- Verified on the real robot: status and room list are identical to the Swift daemon's.

## Mac app (done)
- The Swift prototype daemon was removed. The app keeps its protocol files (`Vacuum/Protocol`) for the Xiaomi cloud and map decoding.
- `RobotServer` / `RemoteMiIOClient` send everything the app used to send over UDP through the server instead, so the map, zones, schedules and drive pad work unchanged. Status comes from the server's cached readings (`GET /v1/properties`).
- `ServerManager` starts the server when it isn't running, after asking once: install at login, or only while the app is open. The server is bundled in the app (`Tools/bundle-vacuumd.sh` runs `cargo build --release`).
- The server is the only place the robot and Xiaomi settings are stored (owner-only files). The app reads them with `GET /v1/config` and hands over new ones with `POST /v1/config`; an older Keychain copy is moved over once and deleted.

## API (127.0.0.1:47231, `Authorization: Bearer <token>`)
- `POST /mcp` — MCP (JSON-RPC over HTTP). `vacuumd mcp` bridges stdio clients to it.
- `GET /v1/tools`, `POST /v1/tools/{name}` — same tools as plain JSON.
- For the app only (not tools): `GET /v1/properties`, `POST /v1/miio`, `POST /v1/config`.

## Status
1. Done: Rust server (tools, MCP, setup, autostart) with 32 tests against a fake robot.
2. Done: the Mac app talks to the server (15 new tests with a stand-in server); checked live against the robot.
3. Next: schedule and history tools, error notifications, universal (arm64 + x86_64) bundled binary, signing/notarisation.

## Known risks
- macOS "Local Network" permission for a background binary: verify the launch agent can reach the robot after `vacuumd install`.
- Anyone who can read the token file can use every endpoint, including raw robot access; the token protects against web pages and other users, not against other programs you run.
- Secrets live in owner-only files, not the system keychain (see SECURITY.md for why).
