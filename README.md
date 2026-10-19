# water-reminder

A macOS water reminder that's hard to ignore. On the hour, a 3D character walks,
falls, or skateboards onto your screen holding a **"Did you drink water?"** banner,
waits for an answer, then leaves through the opposite edge.

- **Yes** → it dances, plays a happy jingle, and goes
- **Remind later** → sad trombone, and it's back in 5 minutes (until 18:00)

Every answer is logged, so **clicking the app opens a dashboard** instead of a
reminder: glasses today against a goal of 8, your streak, the last 14 days drunk
vs snoozed, a 12-week heatmap, and the recent log. There's a **+ Log a glass**
button for the ones you drink without being asked.

The reminder itself runs as a transparent full-screen overlay that clicks pass
straight through, except over the two buttons. No Dock icon, no menu bar item.

## Get the app

**One line — recommended:**

```sh
curl -fsSL https://raw.githubusercontent.com/AlishThapa/water-reminder/main/install.sh | zsh
```

This builds the app on your Mac, installs it to `/Applications`, and schedules it.
Because it's compiled locally it is **not** quarantined, so it just runs — see
[Why not a plain download?](#why-not-a-plain-download) below.

Needs the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

**Prefer a download?** Grab `WaterReminder-macos.zip` from
[Releases](https://github.com/AlishThapa/water-reminder/releases), unzip, and drag
`WaterReminder.app` to Applications. macOS will refuse to open it the first time —
it's unsigned — so clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/WaterReminder.app
```

Then `open -a WaterReminder`. (Right-click → **Open** also works on some macOS
versions, but on Sequoia and later the `xattr` command is the reliable route.)

## Why not a plain download?

> **"WaterReminder" Not Opened — Apple could not verify this app is free of malware.**

If you've seen that dialog, this is why. macOS attaches a `com.apple.quarantine`
flag to anything a browser downloads. Gatekeeper then refuses to run it unless it
is signed with a paid Apple Developer ID *and* notarised by Apple. An unsigned app
in a GitHub release will always hit this — the download is what triggers it.

Building on your own machine sidesteps the whole thing, which is why the one-line
install is the recommended path. It's the same reason projects like
[scrcpy](https://github.com/Genymobile/scrcpy) point macOS users at Homebrew
instead of a binary.

## Usage

| | |
| --- | --- |
| Open the dashboard | `open -a WaterReminder` |
| Trigger a reminder now | `WaterReminder --remind` |
| Change the schedule | dashboard → **Settings** |
| Uninstall | `curl -fsSL .../install.sh \| zsh -s -- --uninstall` |

## Settings

The **Settings** tab in the dashboard covers everything there is to change:

| | |
| --- | --- |
| Remind me | the hourly schedule, on or off |
| Hours | first and last reminder of the day (default 09:00–17:00) |
| Days | which weekdays it runs (default Sunday–Friday) |
| Entrance | surprise me, or pin it to walking / bike / skateboard / surf / parachute / falling in, or to one edge |
| Volume | the jingles and sound effects |
| Snooze for | how long **Remind me later** waits (default 5 min) |
| Stop asking after | a snooze past this hour gives up for the day (default 18:00) |
| Daily goal | glasses that count as a full day (default 8) |
| Test reminder | runs one right now, dashboard stays open |
| Clear history | deletes the log |

Changing the hours, days, or the on/off switch rewrites the LaunchAgent and
reloads it on the spot — no reinstall, no editing plists by hand.

Handy flags when running the binary directly:

```sh
WaterReminder                      # no arguments: the dashboard
WaterReminder --remind             # the reminder overlay (what the schedule runs)
WaterReminder --from left:surf     # force an entrance (left|right|top|bottom)
WaterReminder --snapshot ./shots   # play a scripted run, save PNGs
```

## Where the data lives

```
~/Library/Application Support/WaterReminder/log.jsonl     answers
~/Library/Application Support/WaterReminder/settings.json  settings
```

The log is one JSON object per line — `{"t":"<ISO 8601>","a":"yes"|"later"|"glass"}` — appended
as you answer. Delete the file to start over; it's plain text, so it's easy to graph
elsewhere or sync yourself.

**Upgrading from a version without the dashboard?** Re-run the installer. The
schedule now launches the app with `--remind`, and an old LaunchAgent would pop
the dashboard on the hour instead of the character.

## Build from source

```sh
git clone https://github.com/AlishThapa/water-reminder.git
cd water-reminder
./make-app.sh          # -> dist/WaterReminder.app and dist/WaterReminder-macos.zip
```

| Path | What it is |
| --- | --- |
| `main.swift` | AppKit overlay + dashboard windows, settings, the LaunchAgent writer |
| `web/index.html` | The character, animations, and banner UI |
| `web/dashboard.html` | The tracking dashboard |
| `web/three.min.js` | three.js |
| `web/RoomEnvironment.js` | three.js lighting environment |
| `assets/icon.svg` | The logo, hand-written SVG |
| `assets/AppIcon.icns` | Generated from it by `make-icon.sh` (committed) |
| `make-icon.sh` | Re-renders the icon — only needed if the artwork changes |
| `make-app.sh` | Builds the `.app` bundle and release zip |
| `install.sh` | Build + install + schedule (the one-liner above) |
| `install.command` | Older in-place build, double-clickable in Finder |

The compiled binary is deliberately not committed — see
[Why not a plain download?](#why-not-a-plain-download).

## Notarising (optional)

To make downloads open with no warning, you need an Apple Developer account
($99/yr). With a Developer ID certificate installed:

```sh
./make-app.sh --sign "Developer ID Application: Your Name (TEAMID)"

ditto -c -k --keepParent dist/WaterReminder.app dist/notarize.zip
xcrun notarytool submit dist/notarize.zip \
  --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
xcrun stapler staple dist/WaterReminder.app
```

Re-zip after stapling and attach that to the release. Downloads then open cleanly.

## Requirements

macOS 12 or later, Apple silicon or Intel. Xcode Command Line Tools to build.
