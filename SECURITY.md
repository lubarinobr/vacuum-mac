# Security

`vacuumd` controls a physical robot in a home, so it is built to limit what a leaked setting, a misbehaving
program or a prompt-injected agent can do.

## What it protects against

| Threat | Protection |
|---|---|
| A web page trying to talk to the server | Only `127.0.0.1`; `Host` and `Origin` checks; every request needs a token |
| An agent token ending up in a config file, log or chat | The agent token can only use the 15 tools. It cannot reach the raw robot channel, the settings or shutdown |
| A stolen app token used to send odd robot commands | The raw channel allows only the commands the Mac app sends (no firmware, Wi-Fi or other device methods) |
| Settings that point the server at someone else's machine | The robot's address must be an IP on a home network; Xiaomi regions are checked; a bad request saves nothing |
| "What did the agent do?" | `vacuumd audit`: every change, every refused attempt, no tokens, no values written to the robot |
| A local program stalling or flooding the server | Request size, time and connection limits |
| Home layout leaking through map pictures | Saved in a private folder by default, not in synced folders such as Pictures |
| Secrets readable by others | Settings, tokens and sign-in are in a private folder with owner-only files (also on Windows) |
| Leftover credentials | `vacuumd logout` deletes the sign-in, the robot's token and both access tokens |

## What it does not protect against

- **Programs you run yourself.** Anything running as you can read the token files and use the tools. Connect only agents you trust.
- **A prompt-injected agent.** An agent that is tricked into acting can still start, stop or drive the robot. Map edits need an explicit confirmation step, and `vacuumd audit` shows what happened, but there is no hard block on the other tools.
- **Someone on your home network** who has the robot's token can control the robot directly (that is how the robot's own protocol works).
- Programs are **not signed** with a paid certificate (see the download notes in the README).

## Reporting a problem

Please open a private security advisory on GitHub (Security tab, "Report a vulnerability") rather than a public issue.
