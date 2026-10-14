import AppKit
import WebKit

// Water reminder: a Memoji-style 3D character (web/index.html) walks / falls / jumps onto the screen holding a
// "Did you drink water?" banner. Yes = dance + happy jingle, then leaves; Remind later = sad trombone, leaves,
// and comes back in 5 min (until 18:00). It always exits through the opposite edge.
// Runs as a transparent full-screen overlay that lets clicks through everywhere except the two buttons.
let snoozeMinutes = 5.0
let endHour = 18

// Take the first click even when the overlay isn't focused (otherwise buttons only hover).
final class ClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var buttons: NSRect? // in screen coordinates, while the choices are on screen
    var hitTimer: Timer?
    var readyTimeout: Timer?

    // `WaterReminder --snapshot <dir>`: play a scripted run and save PNGs, for checking the look.
    lazy var snapshotDir = arg("--snapshot")

    func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: name).flatMap { $0 + 1 < a.count && !a[$0 + 1].hasPrefix("--") ? a[$0 + 1] : nil }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // no display at all (lid closed, display asleep): skip this run, launchd tries again next hour
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame else { return NSApp.terminate(nil) }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        config.mediaTypesRequiringUserActionForPlayback = []
        if snapshotDir != nil {
            config.userContentController.addUserScript(WKUserScript(source: "window.SNAPSHOT = true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = ClickWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
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

        // Inside a .app the assets live in Contents/Resources/web; run from a plain
        // checkout they sit next to the executable.
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("web")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("web")
        let dir = [bundled, beside].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? beside
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        waitForReady()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        if body == "ready" { readyTimeout?.invalidate(); return snapshotDir == nil ? show() : snapshots() }
        if body.hasPrefix("err:") { return FileHandle.standardError.write((body + "\n").data(using: .utf8)!) }
        if body.hasPrefix("rect:") { log(body); return setButtons(String(body.dropFirst(5))) }
        guard snapshotDir == nil else { return }
        log(body)
        // "away" = nobody answered: quit rather than snooze, so an empty desk gets one reminder an hour, not six
        if body == "yes" || body == "away" { NSApp.terminate(nil) }
        if body == "later" { snooze() }
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
        // `--from <edge>[:<variant>]` forces the entrance (e.g. left:surf, top:nochute); otherwise random
        let edge = arg("--from") ?? ["left", "right", "top", "bottom"].randomElement()!
        // he stands in the lower third of the screen, so keep him above the Dock
        let dock = screen.visibleFrame.minY - screen.frame.minY
        web.evaluateJavaScript("start('\(edge)', \(dock))")
    }

    func snooze() {
        window.orderOut(nil)
        NSApp.hide(nil) // clicking the button made us the active app; hand focus back to whatever the user was in
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + snoozeMinutes * 60) { // wall clock: keeps counting while asleep
            Calendar.current.component(.hour, from: Date()) < endHour ? self.show() : NSApp.terminate(nil)
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
    delegate.log("usage: WaterReminder [--from left|right|top|bottom[:variant]] [--snapshot <dir>]")
    exit(2)
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
