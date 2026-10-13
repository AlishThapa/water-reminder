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

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    var buttons: NSRect? // in screen coordinates, while the choices are on screen
    var hitTimer: Timer?

    // `WaterReminder --snapshot <dir>`: play a scripted run and save PNGs, for checking the look.
    lazy var snapshotDir = arg("--snapshot")

    func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).frame
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        config.mediaTypesRequiringUserActionForPlayback = []
        if snapshotDir != nil {
            config.userContentController.addUserScript(WKUserScript(source: "window.SNAPSHOT = true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = ClickWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")

        window = OverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = web

        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("web")
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)

        // Clicks pass through the overlay except over the buttons.
        hitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let over = self.buttons?.contains(NSEvent.mouseLocation) ?? false
            if self.window.ignoresMouseEvents == over { self.window.ignoresMouseEvents = !over }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        if body == "ready" { return snapshotDir == nil ? show() : snapshots() }
        if body.hasPrefix("err:") { return FileHandle.standardError.write((body + "\n").data(using: .utf8)!) }
        if body.hasPrefix("rect:") { log(body); return setButtons(String(body.dropFirst(5))) }
        guard snapshotDir == nil else { return }
        log(body)
        if body == "yes" { NSApp.terminate(nil) }
        if body == "later" { snooze() }
    }

    func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    // "x,y,w,h" in page points (top-left origin) -> screen rect, padded a little.
    func setButtons(_ spec: String) {
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { buttons = nil; window.ignoresMouseEvents = true; return }
        let f = window.frame
        buttons = NSRect(x: f.minX + n[0], y: f.maxY - n[1] - n[3], width: n[2], height: n[3]).insetBy(dx: -6, dy: -6)
    }

    func show() {
        window.orderFrontRegardless()
        // `--from <edge>[:<variant>]` forces the entrance (e.g. left:surf, top:nochute); otherwise random
        let edge = arg("--from") ?? ["left", "right", "top", "bottom"].randomElement()!
        // he stands in the lower third of the screen, so keep him above the Dock
        let screen = window.screen ?? NSScreen.main!
        let dock = screen.visibleFrame.minY - screen.frame.minY
        web.evaluateJavaScript("start('\(edge)', \(dock))")
    }

    func snooze() {
        window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + snoozeMinutes * 60) {
            Calendar.current.component(.hour, from: Date()) < endHour ? self.show() : NSApp.terminate(nil)
        }
    }

    func snapshots() {
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
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
