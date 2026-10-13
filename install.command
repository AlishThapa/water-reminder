#!/bin/zsh
# Builds WaterReminder for this Mac and schedules it hourly 9:00-17:00, Sun-Fri (same as the original setup).
# Re-run any time (e.g. after moving the folder) to rebuild and re-point the schedule.
set -e
cd "${0:A:h}"

swiftc main.swift -o WaterReminder

label=com.user.water-reminder
plist=~/Library/LaunchAgents/$label.plist
entries=""
for day in 0 1 2 3 4 5; do
  for hour in {9..17}; do
    entries+="<dict><key>Weekday</key><integer>$day</integer><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>0</integer></dict>"$'\n'
  done
done

mkdir -p ~/Library/LaunchAgents
cat > $plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$PWD/WaterReminder</string></array>
<key>StartCalendarInterval</key><array>
$entries</array></dict></plist>
EOF

launchctl unload $plist 2>/dev/null || true
launchctl load $plist
echo "Installed. Try it now: ./WaterReminder  (you can close this window)"
