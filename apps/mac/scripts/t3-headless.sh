#!/bin/bash
# Runs a headless Conn server as a LaunchAgent, so agent sessions survive restarts of the desktop app.
# It uses the server bundled in the installed Conn app (a T3 Code fork), with its own data folder and a fixed port.
# The app is T3_APP if set, else /Applications/Conn.app, else /Applications/T3 Code (Alpha).app.
#
#   scripts/t3-headless.sh install    copy provider settings, write the LaunchAgent, start it
#   scripts/t3-headless.sh status     show whether it runs and where
#   scripts/t3-headless.sh restart    restart it, for example after a Conn update
#   scripts/t3-headless.sh pair       print a pairing URL for Settings › Connections › Add environment
#   scripts/t3-headless.sh uninstall  stop it and remove the LaunchAgent; the data folder stays
set -euo pipefail

if [ -n "${T3_APP:-}" ]; then
    app="$T3_APP"
elif [ -d "/Applications/Conn.app" ]; then
    app="/Applications/Conn.app"
else
    app="/Applications/T3 Code (Alpha).app"
fi
home="${T3_HEADLESS_HOME:-$HOME/.t3/headless}"
port="${T3_HEADLESS_PORT:-3780}"
label="com.nckrtl.t3-headless"
plist="$HOME/Library/LaunchAgents/$label.plist"
# An empty name (no app at $app) must not turn $executable into the MacOS folder, which passes `-x`.
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
executable="$app/Contents/MacOS/$executable_name"
script="$app/Contents/Resources/app.asar/apps/server/dist/bin.mjs"
cache="$app/Contents/Resources/app.asar/apps/desktop/dist-electron/compileCache.cjs"
domain="gui/$(id -u)"

t3() { ELECTRON_RUN_AS_NODE=1 "$executable" "$script" "$@"; }

fail() { echo "error: $*" >&2; exit 1; }

install() {
    [ -n "$executable_name" ] && [ -f "$executable" ] && [ -x "$executable" ] || fail "Conn (or T3 Code) not found at $app. Set T3_APP."
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && ! launchctl print "$domain/$label" >/dev/null 2>&1; then
        fail "port $port is in use by another program. Set T3_HEADLESS_PORT."
    fi
    mkdir -p "$home/userdata/logs"
    # Provider setup only. Never copy secrets/, environment-id or state.sqlite: they belong to the app's own server.
    for file in settings.json keybindings.json; do
        if [ ! -e "$home/userdata/$file" ] && [ -e "$HOME/.t3/userdata/$file" ]; then
            cp "$HOME/.t3/userdata/$file" "$home/userdata/$file"
            echo "copied $file"
        fi
    done
    if [ ! -e "$home/userdata/themes" ] && [ -d "$HOME/.t3/userdata/themes" ]; then cp -R "$HOME/.t3/userdata/themes" "$home/userdata/themes"; fi

    mkdir -p "$(dirname "$plist")"
    # PATH from this shell, so the server finds codex, claude and the other provider CLIs.
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$executable</string>
		<string>--require</string>
		<string>$cache</string>
		<string>$script</string>
		<string>serve</string>
		<string>--base-dir</string>
		<string>$home</string>
		<string>--host</string>
		<string>127.0.0.1</string>
		<string>--port</string>
		<string>$port</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>ELECTRON_RUN_AS_NODE</key>
		<string>1</string>
		<key>PATH</key>
		<string>$PATH</string>
	</dict>
	<key>WorkingDirectory</key>
	<string>$HOME</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$home/userdata/logs/headless.log</string>
	<key>StandardErrorPath</key>
	<string>$home/userdata/logs/headless.log</string>
</dict>
</plist>
EOF
    launchctl bootout "$domain/$label" 2>/dev/null || true
    launchctl bootstrap "$domain" "$plist"
    wait_ready
    echo "Headless Conn runs at http://127.0.0.1:$port (data in $home)."
    echo "Next: run '$0 pair' and add the URL in each Conn window under Settings › Connections › Add environment."
}

wait_ready() {
    for _ in $(seq 1 30); do
        if curl -fsS -m 1 "http://127.0.0.1:$port/.well-known/t3/environment" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    fail "the server did not start. See $home/userdata/logs/headless.log"
}

status() {
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
        echo "LaunchAgent: loaded ($plist)"
    else
        echo "LaunchAgent: not loaded"
    fi
    if curl -fsS -m 2 "http://127.0.0.1:$port/.well-known/t3/environment" 2>/dev/null; then
        echo
        echo "Server: running at http://127.0.0.1:$port"
    else
        echo "Server: not answering on port $port"
    fi
    echo "Data: $home"
}

restart() {
    launchctl kickstart -k "$domain/$label"
    wait_ready
    echo "Restarted."
}

pair() {
    curl -fsS -m 2 "http://127.0.0.1:$port/.well-known/t3/environment" >/dev/null 2>&1 || fail "the headless server is not running. Run '$0 install'."
    t3 pair --base-dir "$home" --label "${1:-Conn window}" --ttl 15m
}

uninstall() {
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "Stopped and removed $label. The data in $home stays."
}

case "${1:-}" in
    install) install ;;
    status) status ;;
    restart) restart ;;
    pair) shift; pair "$@" ;;
    uninstall) uninstall ;;
    *) sed -n '2,10p' "$0"; exit 1 ;;
esac
