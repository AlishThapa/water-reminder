import AppKit
import WebKit

// Water reminder, two faces of the same binary:
//
//   WaterReminder --remind    a Memoji-style 3D character (web/index.html) walks / falls / jumps onto the screen
//                             holding a "Did you drink water?" banner. Yes = dance + happy jingle, then leaves;
//                             Remind later = sad trombone, leaves, and comes back after the snooze. It always exits
//                             through the opposite edge, over a transparent full-screen overlay that lets clicks
//                             through everywhere except the two buttons. This is what the hourly schedule runs.
//   WaterReminder             no arguments (so: clicking the app) opens the tracking dashboard (web/dashboard.html):
//                             glasses today, streak, the last 14 days, a 12-week heatmap, recent activity, settings.
enum Mode { case remind, dashboard, snapshot }

// MARK: - stored state

let supportDir: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WaterReminder")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

let logURL = supportDir.appendingPathComponent("log.jsonl")
let settingsURL = supportDir.appendingPathComponent("settings.json")
let launchLabel = "com.user.water-reminder"
let plistURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist")

// One JSON object per line: {"t":"<ISO 8601, local offset>","a":"yes"|"later"|"away"|"glass"}.
// Append-only and line-based, so a half-written file costs at most one entry.
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func record(_ action: String) {
    let line = "{\"t\":\"\(isoFormatter.string(from: Date()))\",\"a\":\"\(action)\"}\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

func dropLastEntry() {
    guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard !lines.isEmpty else { return }
    lines.removeLast()
    try? (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        .write(to: logURL, atomically: true, encoding: .utf8)
}

// The whole log as a JSON array, to hand to the dashboard page.
func historyJSON() -> String {
    let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    return "[" + text.split(separator: "\n").filter { $0.hasPrefix("{") }.joined(separator: ",") + "]"
}

struct Settings: Codable {
    var remindersOn = true
    var startHour = 9           // first reminder of the day
    var endHour = 17            // last scheduled reminder
    var weekdays = [0, 1, 2, 3, 4, 5]   // launchd weekdays, 0 = Sunday (Sunday-Friday by default, like install.sh)
    var snoozeMinutes = 5.0
    var stopAfterHour = 18      // a snooze past this hour gives up for the day
    var goal = 8                // glasses that make a full day, shown on the dashboard
    var entrance = "random"     // random | left | right | top | bottom | walk | bike | surf | skate | chute | fall
    var volume = 0.5

    // Every key optional on the way in, so an older or hand-edited file keeps its defaults.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        remindersOn = try c.decodeIfPresent(Bool.self, forKey: .remindersOn) ?? d.remindersOn
        startHour = try c.decodeIfPresent(Int.self, forKey: .startHour) ?? d.startHour
        endHour = try c.decodeIfPresent(Int.self, forKey: .endHour) ?? d.endHour
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? d.weekdays
        snoozeMinutes = try c.decodeIfPresent(Double.self, forKey: .snoozeMinutes) ?? d.snoozeMinutes
        stopAfterHour = try c.decodeIfPresent(Int.self, forKey: .stopAfterHour) ?? d.stopAfterHour
        goal = try c.decodeIfPresent(Int.self, forKey: .goal) ?? d.goal
        entrance = try c.decodeIfPresent(String.self, forKey: .entrance) ?? d.entrance
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
    }

    // Keep the stored values sane whatever the page sent.
    mutating func clamp() {
        startHour = min(max(startHour, 0), 23)
        endHour = min(max(endHour, startHour), 23)
        stopAfterHour = min(max(stopAfterHour, endHour), 23)
        snoozeMinutes = min(max(snoozeMinutes, 1), 120)
        goal = min(max(goal, 1), 30)
        volume = min(max(volume, 0), 1)
        weekdays = Array(Set(weekdays.filter { (0...6).contains($0) })).sorted()
    }
}

func loadSettings() -> Settings {
    guard let data = try? Data(contentsOf: settingsURL),
          var s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
    s.clamp()
    return s
}

func saveSettings(_ s: Settings) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(s).write(to: settingsURL, options: .atomic)
}

var settings = loadSettings()

// Rewrites the LaunchAgent from the current settings and reloads it, so the schedule the panel
// shows is the one launchd actually runs. install.sh writes the same plist on a fresh install.
@discardableResult
func applySchedule() -> String {
    let exe = Bundle.main.executableURL!.resolvingSymlinksInPath().path
    let uid = getuid()

    func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    launchctl(["bootout", "gui/\(uid)/\(launchLabel)"])
    guard settings.remindersOn, !settings.weekdays.isEmpty, settings.startHour <= settings.endHour else {
        try? FileManager.default.removeItem(at: plistURL)
        return "Reminders are off."
    }

    let entries = settings.weekdays.flatMap { day in
        (settings.startHour...settings.endHour).map { hour in
            "<dict><key>Weekday</key><integer>\(day)</integer><key>Hour</key><integer>\(hour)</integer><key>Minute</key><integer>0</integer></dict>"
        }
    }.joined(separator: "\n")

    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WaterReminder.log").path
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(launchLabel)</string>
    <key>ProgramArguments</key><array><string>\(exe)</string><string>--remind</string></array>
    <key>StandardErrorPath</key><string>\(log)</string>
    <key>StartCalendarInterval</key><array>
    \(entries)</array></dict></plist>
    """
    try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
    launchctl(["bootstrap", "gui/\(uid)", plistURL.path])
    return "Schedule updated."
}

// Take the first click even when the overlay isn't focused (otherwise buttons only hover).
final class ClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var buttons: NSRect? // in screen coordinates, while the choices are on screen
    var hitTimer: Timer?
    var readyTimeout: Timer?

    var dashWindow: NSWindow?
    var dash: WKWebView?

    // `WaterReminder --snapshot <dir>`: play a scripted run and save PNGs, for checking the look.
    lazy var snapshotDir = arg("--snapshot")

    lazy var mode: Mode = {
        if CommandLine.arguments.contains("--snapshot") { return .snapshot }
        // --from implies the overlay, since it picks the entrance
        if CommandLine.arguments.contains("--remind") || CommandLine.arguments.contains("--from") { return .remind }
        return .dashboard
    }()

    func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: name).flatMap { $0 + 1 < a.count && !a[$0 + 1].hasPrefix("--") ? a[$0 + 1] : nil }
    }

    // Inside a .app the assets live in Contents/Resources/web; run from a plain
    // checkout they sit next to the executable.
    lazy var webDir: URL = {
        let beside = Bundle.main.executableURL!.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("web")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("web")
        return [bundled, beside].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? beside
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        mode == .dashboard ? openDashboard() : setupOverlay()
    }

    func setupOverlay() {
        // no display at all (lid closed, display asleep): skip this run, launchd tries again next hour
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame else { return NSApp.terminate(nil) }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        config.mediaTypesRequiringUserActionForPlayback = []
        if snapshotDir != nil {
            config.userContentController.addUserScript(WKUserScript(source: "window.SNAPSHOT = true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = ClickWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        // Private KVC key, but the only way to get a transparent WKWebView on macOS (underPageBackgroundColor only
        // colours the overscroll area). If Apple drops it, the overlay turns opaque white.
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self

        window = OverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] // also over full-screen apps
        window.ignoresMouseEvents = true
        window.contentView = web

        web.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)
        waitForReady()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        if body.hasPrefix("err:") { return FileHandle.standardError.write((body + "\n").data(using: .utf8)!) }

        // from web/dashboard.html
        if body == "dash:ready" { return refreshDashboard() }
        if body == "dash:log" { record("glass"); return refreshDashboard() }
        if body == "dash:undo" { dropLastEntry(); return refreshDashboard() }
        if body == "dash:reset" { try? FileManager.default.removeItem(at: logURL); return refreshDashboard(status: "History cleared.") }
        if body == "dash:test" { return testReminder() }
        if body.hasPrefix("set:") { return saveFromPage(String(body.dropFirst(4))) }

        // from web/index.html
        if body == "ready" { readyTimeout?.invalidate(); return snapshotDir == nil ? show() : snapshots() }
        if body.hasPrefix("rect:") { log(body); return setButtons(String(body.dropFirst(5))) }
        guard snapshotDir == nil else { return }
        log(body)
        if ["yes", "later", "away"].contains(body) { record(body) }
        // "away" = nobody answered: quit rather than snooze, so an empty desk gets one reminder an hour, not six
        if body == "yes" || body == "away" { NSApp.terminate(nil) }
        if body == "later" { snooze() }
    }

    // MARK: - dashboard

    func openDashboard() {
        if let existing = dashWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return refreshDashboard()
        }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        let view = WKWebView(frame: .zero, configuration: config)
        dash = view

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Water Reminder"
        w.contentView = view
        w.minSize = NSSize(width: 620, height: 520)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        dashWindow = w

        view.loadFileURL(webDir.appendingPathComponent("dashboard.html"), allowingReadAccessTo: webDir)
        // the overlay is a background accessory; a window someone looks at needs a real app
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshDashboard(status: String? = nil) {
        let json = (try? JSONEncoder().encode(settings)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let note = status.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" } ?? "null"
        dash?.evaluateJavaScript("window.render?.(\(historyJSON()), \(json), \(note))")
    }

    // The panel sends the whole settings object on every change; schedule keys get re-applied only
    // when one of them actually moved, so a volume slider doesn't churn launchd.
    func saveFromPage(_ json: String) {
        guard let data = json.data(using: .utf8), var incoming = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        incoming.clamp()
        let scheduleMoved = incoming.remindersOn != settings.remindersOn
            || incoming.startHour != settings.startHour || incoming.endHour != settings.endHour
            || incoming.weekdays != settings.weekdays
        settings = incoming
        saveSettings(settings)
        refreshDashboard(status: scheduleMoved ? applySchedule() : "Saved.")
    }

    // A second copy of ourselves, so the dashboard stays open while the character runs.
    func testReminder() {
        let p = Process()
        p.executableURL = Bundle.main.executableURL!.resolvingSymlinksInPath()
        p.arguments = ["--remind"]
        try? p.run()
        refreshDashboard(status: "Here he comes.")
    }

    // Clicking the app in the Dock or Finder while a reminder instance is already
    // running comes through here instead of launching a second copy.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === dashWindow else { return }
        // in reminder mode the process still owes someone a snooze, so only the dashboard's own run exits
        if mode == .dashboard { return NSApp.terminate(nil) }
        dashWindow = nil
        dash = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // A page that never gets going (web/ missing, a JS error before "ready", WebContent crashing) must not leave an
    // invisible process behind: launchd won't start the next hourly run while this one is still alive.
    func waitForReady() {
        readyTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.log("page never posted ready, quitting")
            NSApp.terminate(nil)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("web content process died, quitting")
        NSApp.terminate(nil)
    }

    func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    // "x,y,w,h" in page points (top-left origin) -> screen rect, padded a little.
    // Clicks pass through the overlay except over the buttons, so poll the mouse, but only while they're up.
    func setButtons(_ spec: String) {
        hitTimer?.invalidate()
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { buttons = nil; window.ignoresMouseEvents = true; return }
        let f = window.frame
        buttons = NSRect(x: f.minX + n[0], y: f.maxY - n[1] - n[3], width: n[2], height: n[3]).insetBy(dx: -6, dy: -6)
        hitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let over = self.buttons?.contains(NSEvent.mouseLocation) ?? false
            if self.window.ignoresMouseEvents == over { self.window.ignoresMouseEvents = !over }
        }
    }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return NSApp.terminate(nil) }
        // The page sizes itself once, at load. If the displays changed since (e.g. during a snooze), fit the window to
        // the current screen and reload; the page posts "ready" again, which lands back here.
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
            web.reload()
            return waitForReady()
        }
        NSApp.unhideWithoutActivation() // undo snooze()'s hide without stealing focus
        window.orderFrontRegardless()
        // `--from <edge>[:<variant>]` forces the entrance (e.g. left:surf, top:nochute); otherwise the setting.
        // With Reduce Motion on, no falls, flips or rides: he just walks in from a side, whatever is set.
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let edge = arg("--from") ?? (calm ? ["left:walk", "right:walk"].randomElement()! : startSpec())
        // he stands in the lower third of the screen, so keep him above the Dock
        let dock = screen.visibleFrame.minY - screen.frame.minY
        web.evaluateJavaScript("setVolume?.(\(settings.volume)); start('\(edge)', \(dock))")
    }

    // Settings "Entrance" -> a start() spec. A named ride only works from the sides, and the two
    // top variants pick themselves, so each choice maps to the edge that can actually play it.
    func startSpec() -> String {
        switch settings.entrance {
        case "walk", "bike", "surf", "skate": return ["left", "right"].randomElement()! + ":" + settings.entrance
        case "chute": return "top:chute"
        case "fall": return "top:nochute"
        case "left", "right", "top", "bottom": return settings.entrance
        default: return ["left", "right", "top", "bottom"].randomElement()!
        }
    }

    func snooze() {
        window.orderOut(nil)
        NSApp.hide(nil) // clicking the button made us the active app; hand focus back to whatever the user was in
        let asked = Date()
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + settings.snoozeMinutes * 60) { // wall clock: keeps counting while asleep
            // after a long sleep this fires on wake, so check the day too: a Friday snooze must not reappear on Saturday
            Calendar.current.isDateInToday(asked) && Calendar.current.component(.hour, from: Date()) < settings.stopAfterHour ? self.show() : NSApp.terminate(nil)
        }
    }

    func snapshots() {
        do { try FileManager.default.createDirectory(atPath: snapshotDir!, withIntermediateDirectories: true) }
        catch { log("--snapshot: \(error.localizedDescription)"); exit(1) }
        window.orderFrontRegardless()
        // (seconds to wait, JS to run first, snapshot name)
        let steps: [(Double, String, String)] = [
            (0.8, "pose('ask', 3)", "p1-ask"), (0.8, "pose('happy', 3)", "p2-happy"), (0.8, "pose('sad', 3)", "p3-sad"),
            (0.8, "pose('ask', 1.4)", "p4-full"),
            (0.8, "pose('ask', 1.4, 'bike')", "r1-bike-stop"), (0.8, "pose('hey', 1.4, 'bike', true)", "r2-bike-ride"),
            (0.8, "pose('hey', 1.4, 'surf', true)", "r3-surf-ride"), (0.8, "pose('ask', 1.4, 'skate')", "r4-skate"),
            (0.8, "pose('ask', 1)", "r5-whole-screen"),
            (1.0, "start('left:bike')", "b1-peek"), (2.4, "", "b2-coming"), (0.9, "", "b3-braking"), (2.0, "", "b4-stopped"),
            (1.2, "answer(true)", "b5-dance"), (2.0, "", "b6-wheelie"),
            (3.4, "start('right:surf')", "s1-wave"), (1.2, "", "s2-riding"), (1.0, "", "s3-crash"), (2.0, "", "s4-stopped"),
            (3.0, "answer(false)", "s5-wave-back"),
            (3.4, "start('left:skate')", "k1-push"), (2.6, "", "k2-ollie"),
            (1.0, "start('top:chute')", "c1-plane"), (1.0, "", "c2-jump"), (1.2, "", "c3-chute"), (1.6, "", "c4-landing"), (1.0, "", "c5-collapse"),
        ]
        func step(_ i: Int) {
            guard i < steps.count else { return NSApp.terminate(nil) }
            if !steps[i].1.isEmpty { web.evaluateJavaScript(steps[i].1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + steps[i].0) {
                self.web.takeSnapshot(with: nil) { image, _ in
                    let rep = image.flatMap { $0.tiffRepresentation }.flatMap(NSBitmapImageRep.init(data:))
                    try? rep?.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(self.snapshotDir!)/\(steps[i].2).png"))
                    step(i + 1)
                }
            }
        }
        step(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
// A typo in these debugging flags would otherwise just play some other entrance, or a normal reminder.
let args = CommandLine.arguments, edge = delegate.arg("--from")?.components(separatedBy: ":")[0] ?? ""
if args.contains("--from") && !["left", "right", "top", "bottom"].contains(edge) || args.contains("--snapshot") && delegate.snapshotDir == nil {
    delegate.log("usage: WaterReminder [--remind] [--from left|right|top|bottom[:variant]] [--snapshot <dir>]")
    exit(2)
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
