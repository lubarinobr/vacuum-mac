# Vacuum

A native macOS app for the **Xiaomi Robot Vacuum X20+** (`xiaomi.vacuum.c102gl`). It talks to the robot directly over your home network and uses Xiaomi's cloud only to fetch the map.

![Vacuum main window](docs/images/main.png)

*The floor plan is pixelated in this screenshot for privacy.*

## Features

### Map and cleaning
A live map with the robot's position and cleaning path, with zoom and pan. Click the rooms you want and press **Start**, or clean the whole house. Rooms can be renamed or hidden, and the panel shows the robot's status, battery, suction, mop level and cleaning mode, plus start, stop, home, empty bin and locate.

### Insights
Cleaning history at a glance: cleans, area and time per week compared with the last one, totals since you got the robot, and how often each room was cleaned. Open it from **Insights** in the toolbar.

<p align="center"><img src="docs/images/insights.png" width="460" alt="Insights"></p>

### Schedules
Create, edit, enable and delete scheduled cleans, per day and per room. Open it from **Schedules** in the toolbar.

<p align="center"><img src="docs/images/schedules.png" width="460" alt="Schedules"></p>

### Furniture and belongings
Place furniture on the map (sofa, bed, fridge, plants, toys and more), then drag to move and resize. It helps you recognize each room and what the robot has to go around. Open it from the pencil button on the map, **Furniture and belongings**.

<p align="center"><img src="docs/images/furniture.png" width="230" alt="Furniture picker"></p>

### Walls, zones and rooms
From the same pencil menu you can draw **no-go zones**, **no-mop zones** and **virtual walls** and save them to the robot (the previous layout can be restored), and **merge or divide rooms**.

<p align="center"><img src="docs/images/zones.png" width="520" alt="Zone tools"></p>

### Parts and settings
Brush, filter and mop pad life with a reset after you replace them, and do-not-disturb hours. Open it with the gear icon.

### Also
There is a hidden **Drive** toggle in the toolbar that lets you steer the robot by hand with a joystick, the arrow keys or WASD. Keep an eye on the robot while you use it.

## Install

Requires **macOS 26 or later** (Apple Silicon or Intel).

1. Download **Vacuum.dmg** from the [latest release](../../releases/latest).
2. Open it and drag **Vacuum** into **Applications**.
3. Open Vacuum. The app isn't signed with an Apple Developer ID, so macOS blocks the first launch. Either:
   - go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Vacuum; or
   - run this in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Vacuum.app
     ```

## Set up your robot

On first launch, sign in with your Xiaomi account:

1. Choose your Xiaomi region and scan the QR code with the Mi Home app (or sign in on Xiaomi's website). Your password goes only to Xiaomi, never through this app.
2. Pick your robot from the list. The app fills in its IP address, token and ID.
3. If sign-in doesn't work, use the manual entry and type the robot's IP address and token yourself.

Your robot's token and Xiaomi login stay on your Mac, in the Keychain. The Mac and the robot must be on the same Wi-Fi network.

## Build from source

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Vacuum.xcodeproj
```

The map tests use a real map file that isn't included in the repo, because a map shows the layout of a home. Those tests fail until you add your own `VacuumTests/Fixtures/map_raw.txt`.

## Disclaimer

An unofficial project, not affiliated with Xiaomi or Dreame. Use it at your own risk, and keep an eye on the robot while driving it by hand.
