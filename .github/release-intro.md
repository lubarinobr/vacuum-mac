**vacuumd** lets AI agents (MCP) and the Vacuum app control a Xiaomi Robot Vacuum X20+. No Mac app is needed.

| Your computer | Download |
|---|---|
| Windows (64-bit) | `vacuumd-windows-x86_64.zip` |
| Mac with an Intel chip | `vacuumd-macos-x86_64.tar.gz` |
| Mac with Apple Silicon (M1 or newer) | `vacuumd-macos-arm64.tar.gz` |
| Any Mac | `vacuumd-macos-universal.tar.gz` |
| Linux (64-bit, experimental) | `vacuumd-linux-x86_64.tar.gz` |

Macs need macOS 11 or newer. Unpack the file, then in a terminal in that folder:

```
./vacuumd install      # Windows: .\vacuumd.exe install
vacuumd setup          # in a NEW terminal: sign in to Xiaomi once to find your robot
vacuumd status         # check that it is running and the robot answers
```

`install` prints the line that connects your AI agent. `vacuum-robot-skill.zip` is an optional skill that teaches agents how to use the tools well.

The programs are not signed with a paid certificate: Windows may show SmartScreen (*More info → Run anyway*), and macOS may need `xattr -d com.apple.quarantine ./vacuumd` once. Checksums are in `SHA256SUMS.txt`. Guide: [README](https://github.com/lubarinobr/vacuum-mac#install-vacuumd-no-app-needed) · [Security](https://github.com/lubarinobr/vacuum-mac/blob/main/SECURITY.md).
