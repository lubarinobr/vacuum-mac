# Changelog

Changes to **vacuumd**, the background program that lets AI agents (MCP) and the Vacuum app control the robot.
Releases are tagged `daemon-vX.Y.Z`. The Mac app has its own releases (`vX.Y.Z`).

## [0.2.1] - 2026-10-15

Fixes the case where the robot has gone quiet (asleep, or off Wi-Fi) and everything seemed to hang.

### Fixed
- **`get_status` no longer hangs** when the robot isn't answering. It answers at once from the last reading, says `online: false` and why, and adds a `note` saying how old the values are. Asking for a fresh reading gives up after a few seconds instead of waiting half a minute.
- **The first message to a cold robot is sent up to three times.** The first packet after a quiet spell is often lost, which made the robot look offline until something woke it.
- **Many callers share one reading** of the robot instead of queuing behind each other.
- **Gentler polling while the robot is silent** (every 5 seconds while it answers, then 10 and 15 seconds), and a silent robot is detected by the first request instead of asking three times.
- **Clear messages.** "The robot isn't answering. It may be asleep or off Wi-Fi: press a button on it or lift it off the dock, then try again." replaces "Broken pipe". The Mac app shows the same wording.

### Upgrading from 0.2.0
Download the new file and run `./vacuumd install` again (`.\vacuumd.exe install` on Windows).

## [0.2.0] - 2026-10-15

A security release. Nothing changes in how you use the tools; what an agent or a leaked setting can do is smaller.

### Security
- **Two access tokens.** Agents now use their own token, which can only use the tools. The Mac app keeps its own token for the robot channel, settings and shutdown. If an agent's token leaks, it can't send arbitrary robot commands or change your settings. `vacuumd token` prints the agent token; `vacuumd token app` prints the app's.
- **The app's robot channel is limited** to the commands the Mac app really sends. Firmware, Wi-Fi and other device commands are refused.
- **Settings are checked.** The robot's address must be an IP on a home network, Xiaomi regions must be real ones, and a refused request saves nothing.
- **Audit log.** `vacuumd audit` lists what agents and the app asked the robot to do, and every refused attempt. It never contains tokens or the values written to the robot. The file is rotated when large.
- **Private map pictures.** Pictures from `get_map_image` are now saved in a private folder inside vacuumd's settings folder, not in Pictures, because a map shows the layout of a home and Pictures is often backed up to the cloud. `vacuumd map-folder pictures` (or any folder) changes it; a folder you pick keeps its own permissions.
- **`vacuumd logout`** deletes the Xiaomi sign-in, the robot's token and both access tokens, and stops vacuumd. Room names and furniture are kept.
- **Owner-only files on Windows.** The settings folder and the files in it are restricted to your user (macOS and Linux already were).
- **Limits** on request size, time to send a request and simultaneous connections; chunked request bodies are refused.
- New [SECURITY.md](SECURITY.md) explains what is protected and what is not.

### Added
- `vacuumd audit [N]`, `vacuumd map-folder`, `vacuumd logout`.

### Changed
- Map pictures are no longer saved in `Pictures/Vacuum` by default. Pictures you already have there stay where they are.
- `vacuumd token` now prints the **agent** token (it used to print the single token).

### Fixed
- A client whose request was refused halfway now sees the reason instead of a dropped connection.

### Upgrading from 0.1.0
1. Download the new file and run `./vacuumd install` again (`.\vacuumd.exe install` on Windows). It replaces the background copy.
2. Agents set up with `vacuumd mcp` (the command from `vacuumd install`) need nothing.
3. Agents set up with a URL and a token should switch to the new agent token (`vacuumd token`). The old token still works but is now the app's token, which can do more than an agent needs.
4. The Mac app needs no change.

## [0.1.0] - 2026-10-15

First release.
- One program for Windows, macOS and Linux that owns the connection to the robot and lets AI agents use it through MCP.
- 15 tools: status, start, stop, dock, locate, empty bin, suction, mop level, cleaning mode, list rooms, clean rooms, drive, a map picture, and merge or divide rooms (preview first, change only after confirmation).
- `vacuumd setup` (Xiaomi sign-in in a browser), `install` (start at login, add to PATH), `status`, `call`, `mcp`, `version`.
- The Vacuum Mac app now uses it, and bundles it.
- An agent skill, `skills/vacuum-robot`, that teaches agents how to use the tools well.
