#!/bin/zsh
# Builds WaterReminder.app and zips it for a GitHub release.
#   ./make-app.sh            -> dist/WaterReminder.app + dist/WaterReminder-macos.zip
#   ./make-app.sh --sign ID  -> same, signed with Developer ID "ID" (see README: Notarising)
set -e
cd "${0:A:h}"

sign_id=""
[[ "$1" == "--sign" ]] && sign_id="$2"

app="dist/WaterReminder.app"
rm -rf dist && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O main.swift -o "$app/Contents/MacOS/WaterReminder"
cp -R web "$app/Contents/Resources/web"

cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WaterReminder</string>
  <key>CFBundleDisplayName</key><string>Water Reminder</string>
  <key>CFBundleIdentifier</key><string>com.user.water-reminder</string>
  <key>CFBundleExecutable</key><string>WaterReminder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <!-- Overlay only: no Dock tile, no menu bar. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

if [[ -n "$sign_id" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$sign_id" "$app"
  echo "Signed with: $sign_id"
else
  # Ad-hoc signature: satisfies the arm64 loader, but NOT Gatekeeper on download.
  codesign --force --deep --sign - "$app"
  echo "Ad-hoc signed (unsigned for Gatekeeper purposes)."
fi

# ditto preserves the bundle correctly; plain `zip` can mangle it.
(cd dist && ditto -c -k --sequesterRsrc --keepParent WaterReminder.app WaterReminder-macos.zip)
echo "Built: $app"
echo "       dist/WaterReminder-macos.zip"
