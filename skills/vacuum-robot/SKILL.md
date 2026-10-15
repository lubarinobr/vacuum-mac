---
name: vacuum-robot
description: Control the user's Xiaomi robot vacuum (X20+) through the "vacuum" MCP server (vacuumd). Check status and battery, start, stop or send the robot home, clean specific rooms, show the map as a picture, and fix room boundaries. Use whenever the user talks about their robot vacuum, cleaning the house or a room, where the robot is, the map, battery, or merging/splitting rooms.
---

# Vacuum robot

You control a real robot in the user's home through the MCP server named **vacuum**. Its tools appear as
`mcp__vacuum__<tool>` (the prefix can differ by client). Everything runs on the user's own machine and
home network; there is no cloud account for you to sign in to.

## Before you start

- If no `vacuum` tools exist, the server isn't connected. Tell the user to run `vacuumd status` in a terminal.
  If it isn't running: `vacuumd install` (starts it at every login). Then they restart the agent session.
- If a tool answers "No robot is set up yet", the user has to run `vacuumd setup` (a Xiaomi sign-in in a
  browser). You cannot do that for them: signing in is deliberately not a tool.

## Rules that keep the robot and the user safe

1. **Look before you act.** Call `get_status` first. If `fault` is set, `online` is false, or `busy` is true,
   say so before sending anything new.
2. **Check after you act.** Commands return "ok" as soon as the robot accepts them, not when the job is done.
   Wait a few seconds, call `get_status`, and report what the robot is really doing (`state`).
3. **Do what was asked, no more.** "Clean the kitchen" is `clean_rooms`, not `start_cleaning` (that cleans the
   whole house). If a request is ambiguous about which rooms, ask.
4. **Never loop on failures.** Tool errors are written for people: read them to the user and stop or ask.
5. **Map edits change the robot permanently.** Follow "Fixing rooms" below exactly.
6. The robot is physical. A running robot can bump pets, cables and people. Don't start cleaning while the
   user says someone is sleeping, working in the room, or that the floor isn't ready.

## Tools

| Tool | Use it to | Notes |
|---|---|---|
| `get_status` | See state, battery, fault, settings, brush and filter life, totals | Fast (cached a few seconds). `fresh: true` asks the robot again. |
| `start_cleaning` | Clean the **whole house** with current settings | Also resumes a paused job. |
| `stop_cleaning` | Pause the job | The robot stays where it is. Use `go_home` to dock it. |
| `go_home` | Send it back to the dock to charge | |
| `locate` | Make it say "I'm here" | For "where is the robot?" |
| `empty_bin` | Empty the dust bin into the dock | Robot must be docked. |
| `set_suction` | `silent`, `standard`, `strong`, `max` | Applies to the next cleaning. |
| `set_mop_level` | `low`, `medium`, `high` water | |
| `set_cleaning_mode` | `vacuum`, `vacuum_and_mop`, `mop`, `mop_after_vacuum` | Can fail if the mop pads aren't attached; say so. |
| `list_rooms` | Room numbers, names, sizes, positions (`boundsM`) and saved per-room settings | Rooms the user hid in the app are not listed. |
| `clean_rooms` | Clean only some rooms | `rooms`: names or numbers. Optional `suction`, `mop_level`, `mode`, `repeats` (1-3). |
| `get_map_image` | Draw the map as a PNG and return its **file path** | `grid: true` adds a ruler in meters. |
| `merge_rooms` | Merge two neighboring rooms | Preview first, see "Fixing rooms". |
| `divide_room` | Split a room with a straight line | Preview first, see "Fixing rooms". |
| `drive` | Steer by hand for up to 10 s | See "Driving". |

### Cleaning rooms
1. `list_rooms` to learn the names and numbers. Users usually say names; names default to "Room 5" when the
   user never named them, so go by the numbers shown on the map picture if unsure.
2. `clean_rooms` with those rooms. Settings the user saved per room (suction, water, passes) apply unless you
   pass overrides. Pass overrides only when the user asked for them.
3. All rooms in one call must use the **same cleaning mode** (you can't vacuum one room and mop another in a
   single job). If the call refuses, run two jobs one after the other, waiting until the first one is done.
4. `get_status` a few seconds later and report.

### Showing the map
`get_map_image` saves a PNG in vacuumd's private maps folder (or the folder the user chose with `vacuumd map-folder`) and returns `path`. **Tell the user the path**
(and attach or open the file if your client can). The picture shows each room's number, a legend with names and
sizes, the robot, the dock and restricted zones. It's the user's home layout: don't upload or send it anywhere
unless they ask; it is kept private on purpose. `fresh: false` reuses a recent map; the default downloads a new one (a few seconds).

### Driving
Only when the user explicitly asks to steer the robot. Use short steps and look at `get_status` in between.
`velocity` -600..600 (positive forward; 150 slow, 300 normal), `rotation` -128..128 (positive turns left),
`duration_ms` 100..10000. The first command makes the robot announce remote control out loud; warn the user.
Never chain many long drives without checking in.

## Fixing rooms (merge and divide)

These tools rewrite the robot's saved map. They can only be undone by merging or dividing again, and room
numbers may change afterwards. **Never call them with `confirm: true` on your own.**

1. Understand the problem. Call `get_map_image` with `grid: true` and `list_rooms` (each room has `boundsM`:
   `[min x, min y, max x, max y]` in meters; x points right, y points up; the same numbers as the grid).
2. Call the tool **without** `confirm`. It changes nothing and returns `picture`, a map with the proposed line or
   the rooms to merge outlined in magenta.
3. Show the user that picture (give the path) and say in plain words what will happen. Ask for a yes.
4. Only after a clear yes, call the same tool again with the same arguments and `confirm: true`.
5. Read the returned `rooms` and `warnings`. Numbers can change: use the **new** list from then on. Remind the
   user that hidden rooms, room names and per-room settings in the Vacuum app are stored by number and may need
   checking. Offer to draw a new `get_map_image` so they can confirm the result.

Moving an area from one room to its neighbor takes two edits: `divide_room` to cut the area off, then
`merge_rooms` to join the piece to the neighbor (rooms must touch). A divide line is straight, at least 0.3 m
long, and is stretched across the whole room, so check the preview carefully. If a single line can't isolate
the area, say so and suggest the Vacuum app's editor instead of guessing.

## Reading the answers

- `state` examples: Idle, Sweeping, Mopping, Going home, Charging, Fully charged, Washing mop, Drying mop,
  Emptying bin, Remote control, Error. `busy: true` means it is working or heading somewhere.
- `batteryPercent` below about 20% while not charging deserves a mention before long jobs.
- `consumables`: percent of life left for main brush, side brush, filter and mop pads. Under 20% means "replace
  soon"; mention it when relevant, not on every answer.
- `fault` has a code and a description (stuck wheel, dust bin missing, and so on). Tell the user in plain words
  what to check physically; you can't clear faults remotely.
- `online: false` / "isn't answering": the robot is asleep, off Wi-Fi or out of range, or the computer isn't on the
  same network. An idle robot often goes quiet. The values are then the **last known ones**: a `note` says how old
  they are, so don't present them as current. Tell the user to press a button on the robot or lift it off the dock,
  then call `get_status` with `fresh: true` once. Don't retry in a loop, and don't send commands until it answers.

## If something looks wrong

`vacuumd audit` (a command the user runs in a terminal) lists what was asked of the robot, including refused
attempts. If the user asks "what did you do?" or suspects something odd, point them to it. `vacuumd logout`
forgets all credentials. Don't try to work around a refusal ("isn't allowed", "can only use the agent tools"):
those limits are deliberate.

## What you cannot do here

Schedules, restricted zones and virtual walls, cleaning history, room names and furniture are managed in the
Vacuum app (Mac) or the Xiaomi app, not through these tools. The Xiaomi sign-in is only done by the user.
