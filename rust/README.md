# vacuumd (Rust)

A single program that runs on Windows, macOS and Linux. It talks to the robot over your home network and
gives AI agents the same controls as the Vacuum app, through MCP.

## Download

Each **vacuumd** release on the [Releases page](../../../releases) has one file per system (the Mac app's own releases are listed there too, with different names):

| System | File |
|---|---|
| Windows (64-bit) | `vacuumd-windows-x86_64.zip` |
| Mac, Intel | `vacuumd-macos-x86_64.tar.gz` |
| Mac, Apple Silicon (M1 and newer) | `vacuumd-macos-arm64.tar.gz` |
| Mac, either | `vacuumd-macos-universal.tar.gz` |
| Linux (64-bit) | `vacuumd-linux-x86_64.tar.gz` |

The Mac versions run on macOS 11 and newer (Intel and Apple Silicon). `SHA256SUMS.txt` lists the checksums. The programs are not signed with a paid developer certificate, so the first run shows a warning:
- **Windows:** SmartScreen says "Windows protected your PC": choose *More info*, then *Run anyway*.
- **Mac:** if macOS refuses to open it, run `xattr -d com.apple.quarantine ./vacuumd` once.

## First run

Unpack it, then in a terminal in that folder:

```
./vacuumd install     # puts `vacuumd` on your PATH, starts it at every login (use .\vacuumd.exe on Windows)
vacuumd setup         # in a NEW terminal: sign in to Xiaomi once to find the robot
vacuumd status        # check that it's running and the robot answers
```

`vacuumd setup --ip 192.168.1.20 --token <32 hex characters> --did <id>` skips the sign-in if you already know them.
Settings live in `%APPDATA%\Vacuum` (Windows), `~/Library/Application Support/Vacuum` (macOS) or `~/.local/share/Vacuum`
(Linux), the same folder the Mac app uses.

## Tools

`get_status`, `start_cleaning`, `stop_cleaning`, `go_home`, `locate`, `empty_bin`, `set_suction`, `set_mop_level`,
`set_cleaning_mode`, `list_rooms`, `clean_rooms`, `drive`, and for the map: `get_map_image` (saves a PNG in
`Pictures/Vacuum` and returns the path), `merge_rooms` and `divide_room` (these change the robot's saved map, so
they only show a preview until called again with `confirm: true`).

## API (127.0.0.1:47231, `Authorization: Bearer <vacuumd token>`)

- `POST /mcp` — MCP over HTTP. `vacuumd mcp` bridges stdio clients (e.g. Claude Desktop) to it.
- `GET /v1/tools`, `POST /v1/tools/{name}` — the same tools as plain JSON.

## Build and release

```
cargo build --release     # needs a C toolchain for the TLS library (Xcode tools / MSVC Build Tools / gcc)
cargo test
```

The pipeline (`.github/workflows/vacuumd.yml`) tests on Windows, macOS and Linux for every push and pull request, and builds the downloads above. To publish a release, raise `version` in `rust/Cargo.toml`, commit, then:

```
git tag daemon-v0.2.0 && git push origin daemon-v0.2.0
```

The tag must be `daemon-v` plus the version in `Cargo.toml`, or the pipeline stops. It then creates a GitHub Release named "vacuumd 0.2.0" with all files, the agent skill and checksums. The `daemon-` prefix keeps it from replacing the Mac app's release as "Latest". To only get the builds without publishing, run the workflow by hand from the Actions tab and download its artifacts.

The Mac app's Release build bundles a universal `vacuumd` (Intel + Apple Silicon) when both Rust targets are installed: `rustup target add x86_64-apple-darwin aarch64-apple-darwin`.
