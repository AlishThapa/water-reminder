#!/bin/zsh
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/AlishThapa/water-reminder/main/install.sh | zsh
#
# Builds from source ON THIS MAC, so Gatekeeper never quarantines the result.
# Installs WaterReminder.app to /Applications and schedules it hourly 09:00-17:00, Sun-Fri.
#   ... | zsh -s -- --uninstall    removes the app and the schedule
set -e

repo=https://github.com/AlishThapa/water-reminder.git
label=com.user.water-reminder
plist=~/Library/LaunchAgents/$label.plist
app=/Applications/WaterReminder.app

if [[ "$1" == "--uninstall" ]]; then
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"; rm -rf "$app"
  echo "Uninstalled."
  exit 0
fi

if ! command -v swiftc >/dev/null; then
  echo "Xcode Command Line Tools are needed to build. Run:  xcode-select --install"
  exit 1
fi

# Build in a temp checkout unless we're already inside the repo.
if [[ -f "${0:A:h}/main.swift" ]]; then
  src="${0:A:h}"
else
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  src=$tmp/water-reminder
  echo "Fetching source..."
  git clone -q --depth 1 "$repo" "$src"
fi

echo "Building..."
(cd "$src" && ./make-app.sh >/dev/null)

rm -rf "$app"
cp -R "$src/dist/WaterReminder.app" "$app"
# Locally built, but strip any xattrs inherited from the checkout just in case.
xattr -cr "$app" 2>/dev/null || true

entries=""
for day in 0 1 2 3 4 5; do
  for hour in {9..17}; do
    entries+="<dict><key>Weekday</key><integer>$day</integer><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>0</integer></dict>"$'\n'
  done
done

mkdir -p ~/Library/LaunchAgents
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/WaterReminder</string></array>
<key>StartCalendarInterval</key><array>
$entries</array></dict></plist>
EOF

launchctl unload "$plist" 2>/dev/null || true
launchctl load "$plist"

echo "Installed to $app and scheduled hourly 09:00-17:00, Sun-Fri."
echo "Try it now:  open -a WaterReminder"
