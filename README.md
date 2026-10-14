# water-reminder

A macOS water reminder that's hard to ignore. On the hour, a 3D character walks,
falls, or skateboards onto your screen holding a **"Did you drink water?"** banner,
waits for an answer, then leaves through the opposite edge.

- **Yes** → it dances, plays a happy jingle, and goes
- **Remind later** → sad trombone, and it's back in 5 minutes (until 18:00)
- **No answer** for 5 minutes → it leaves and waits for the next hour

It runs as a transparent full-screen overlay that clicks pass straight through,
except over the two buttons. No Dock icon, no menu bar item.

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
| Run it now | `open -a WaterReminder` |
| Change the schedule | clone the repo (see below), edit the hours and days in `install.sh`, run `./install.sh` |
| Uninstall | `curl -fsSL https://raw.githubusercontent.com/AlishThapa/water-reminder/main/install.sh \| zsh -s -- --uninstall` |

Default schedule is hourly, 09:00–17:00, Sunday–Friday. Snooze is 5 minutes and
the app stops asking after 18:00 — both are constants at the top of `main.swift`.

Handy flags when running the binary directly:

```sh
WaterReminder --from left:surf     # force an entrance (left|right|top|bottom)
WaterReminder --snapshot ./shots   # play a scripted run, save PNGs
```

## Build from source

```sh
git clone https://github.com/AlishThapa/water-reminder.git
cd water-reminder
./make-app.sh          # -> dist/WaterReminder.app and dist/WaterReminder-macos.zip
```

| Path | What it is |
| --- | --- |
| `main.swift` | AppKit overlay window hosting a WKWebView |
| `web/index.html` | The character, animations, and banner UI |
| `web/three.min.js` | [three.js r147](https://github.com/mrdoob/three.js/blob/r147/build/three.min.js), unmodified |
| `web/RoomEnvironment.js` | Lighting environment, [`examples/js/environments/RoomEnvironment.js` from r147](https://github.com/mrdoob/three.js/blob/r147/examples/js/environments/RoomEnvironment.js), unmodified |
| `make-app.sh` | Builds the `.app` bundle and release zip |
| `install.sh` | Build + install + schedule (the one-liner above) |
| `install.command` | Runs `install.sh`, double-clickable in Finder |

Upgrading three.js past r147 is a small port, not a file swap: r148 dropped the
`examples/js` builds `RoomEnvironment.js` comes from, and r152 replaced the
`outputEncoding` / `sRGBEncoding` / `texture.encoding` API that `index.html` uses
with `outputColorSpace` / `colorSpace`.

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
