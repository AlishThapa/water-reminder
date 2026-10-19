#!/bin/zsh
# Regenerates assets/AppIcon.icns (and assets/icon-1024.png) from assets/icon.svg.
# Both outputs are committed, so this only needs running when the artwork changes.
set -e
cd "${0:A:h}"

tmp=$(mktemp -d)
cat > "$tmp/icon.html" <<'HTML'
<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;background:transparent}img{display:block;width:1024px;height:1024px}</style>
<img src="icon.svg">
HTML
cp assets/icon.svg "$tmp/icon.svg"

# WebKit is the only SVG renderer macOS ships, so snapshot the SVG in a WKWebView.
cat > "$tmp/render.swift" <<'SWIFT'
import AppKit
import WebKit
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
web.setValue(false, forKey: "drawsBackground")
final class D: NSObject, WKNavigationDelegate {
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            w.takeSnapshot(with: nil) { img, _ in
                let rep = img.flatMap { $0.tiffRepresentation }.flatMap(NSBitmapImageRep.init(data:))
                try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                exit(0)
            }
        }
    }
}
let d = D(); web.navigationDelegate = d
let win = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = web; win.orderBack(nil)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
SWIFT

swiftc -O "$tmp/render.swift" -o "$tmp/render"
"$tmp/render" "$tmp/icon.html" assets/icon-1024.png

rm -rf "$tmp/AppIcon.iconset" && mkdir -p "$tmp/AppIcon.iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz assets/icon-1024.png --out "$tmp/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) assets/icon-1024.png --out "$tmp/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
cp assets/icon-1024.png "$tmp/AppIcon.iconset/icon_512x512@2x.png"
iconutil -c icns "$tmp/AppIcon.iconset" -o assets/AppIcon.icns
rm -rf "$tmp"
echo "Built: assets/AppIcon.icns"
