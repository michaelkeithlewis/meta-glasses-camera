#!/bin/bash
# Runs a command in the logged-in user's GUI session, where the login keychain is unlocked, and
# waits for it. Codesign over SSH fails with errSecInternalComponent; this is the way around it.
#   scripts/gui-run.sh <command...>
set -euo pipefail
label="metaglasses.guirun.$$"
dir=$(mktemp -d /tmp/mg-guirun.XXXXXX)
printf '%q ' "$@" > "$dir/cmd"
cat > "$dir/job.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>-c</string>
<string>cd "$PWD"; bash "$dir/cmd" &gt; "$dir/log" 2&gt;&amp;1; echo \$? &gt; "$dir/rc"</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
P
launchctl bootstrap "gui/$(id -u)" "$dir/job.plist"
touch "$dir/log"
tail -n +1 -f "$dir/log" & tailer=$!
while [ ! -f "$dir/rc" ]; do sleep 1; done
sleep 0.5; kill $tailer 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rc=$(cat "$dir/rc"); rm -rf "$dir"; exit "$rc"
