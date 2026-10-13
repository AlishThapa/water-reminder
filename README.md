# water-reminder

A macOS water reminder. A Memoji-style 3D character walks, falls, or jumps onto the
screen holding a "Did you drink water?" banner.

- **Yes** → dances, happy jingle, leaves
- **Remind later** → sad trombone, leaves, returns in 5 minutes (until 18:00)

It runs as a transparent full-screen overlay that lets clicks through everywhere
except the two buttons.

## Install

```sh
./install.command
```

This compiles `main.swift` with `swiftc` and schedules the app hourly from
09:00–17:00, Sunday–Friday, via a LaunchAgent (`com.user.water-reminder`).
Re-run it any time — for example after moving the folder — to rebuild and
re-point the schedule.

Run it once by hand with `./WaterReminder`.

> Building locally matters: a binary downloaded from a browser is quarantined by
> Gatekeeper and gets killed on launch.

## Layout

| Path | What it is |
| --- | --- |
| `main.swift` | The AppKit overlay window and WKWebView host |
| `web/index.html` | The character, animation, and banner UI |
| `web/three.min.js` | three.js |
| `web/RoomEnvironment.js` | three.js lighting environment |
| `install.command` | Build + schedule script |
