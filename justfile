# Waza Proto task runner. `just` (https://github.com/casey/just) wraps the
# four test tiers so any subset can be run with one short command, and a
# summary rolls up pass/fail/duration at the end of a full run.

# Default action when invoked with no arguments: list the recipes.
default:
    @just --list

# Run all four test tiers, then print a summary.
test:
    #!/usr/bin/env bash
    set -uo pipefail
    declare -a tiers=(unit e2e ios-unit ios-ui)
    declare -a results
    overall=0
    for tier in "${tiers[@]}"; do
        echo
        echo "━━━ test-$tier ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        start=$(date +%s)
        if just test-$tier; then
            status="PASS"
        else
            status="FAIL"
            overall=1
        fi
        elapsed=$(($(date +%s) - start))
        results+=("$tier|$status|${elapsed}s")
    done
    echo
    echo "━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s %-8s %s\n" "Tier" "Status" "Time"
    for r in "${results[@]}"; do
        IFS='|' read -r tier status time <<< "$r"
        printf "  %-14s %-8s %s\n" "$tier" "$status" "$time"
    done
    echo
    exit $overall

# Detailed mode: per-test catalog grouped by tier, with each tier's purpose.
test-detail:
    #!/usr/bin/env bash
    set -uo pipefail
    LOG_DIR=$(mktemp -d -t waza-tests-XXXXXX)
    overall=0

    echo "Running all four tiers (logs → $LOG_DIR)…"
    (cd viewer && npm test -- --reporter=verbose) > "$LOG_DIR/unit.log" 2>&1 || overall=1
    (cd viewer && npm run test:e2e) > "$LOG_DIR/e2e.log" 2>&1 || overall=1
    (cd ios/WazaProto && xcodebuild test \
        -project WazaProto.xcodeproj -scheme WazaProto \
        -destination 'platform=iOS Simulator,name=iPhone 17' \
        -parallel-testing-enabled NO -only-testing:WazaProtoTests) > "$LOG_DIR/ios-unit.log" 2>&1 || overall=1
    (cd ios/WazaProto && xcodebuild test \
        -project WazaProto.xcodeproj -scheme WazaProto \
        -destination 'platform=iOS Simulator,name=iPhone 17' \
        -parallel-testing-enabled NO -only-testing:WazaProtoUITests) > "$LOG_DIR/ios-ui.log" 2>&1 || overall=1

    echo
    echo "━━━ Test Catalog ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo
    echo "unit (Vitest) — Vercel /api/viewer-token: invite verify, JWT mint, env validation, identity collisions"
    grep -E '^ [✓✗] ' "$LOG_DIR/unit.log" \
        | sed -E 's/^ ([✓✗]) [^>]+> [^>]+> (.+) ([0-9]+m?s)$/  \1 \2  (\3)/'

    echo
    echo "e2e (Playwright) — full pipeline: lk publisher → LiveKit SFU → browser <video> frames flowing"
    grep -E '^[[:space:]]+[✓✘]' "$LOG_DIR/e2e.log" \
        | sed -E 's|^[[:space:]]*([✓✘])[[:space:]]+[0-9]+[[:space:]]+\[[^]]+\][[:space:]]+›[[:space:]]+[^›]+[[:space:]]+›[[:space:]]+[^›]+[[:space:]]+›[[:space:]]+(.+)[[:space:]]+\(([^)]+)\)$|  \1 \2  (\3)|'

    echo
    echo "ios-unit (XCTest) — Secrets shape, RoomConnection.Status labels, watcher filter, profiler IDs, smoothing-buffer contract, invite + publisher mint, glasses gate truth table, MDK device + permission-gate wiring"
    grep -E "^Test Case .* (passed|failed) " "$LOG_DIR/ios-unit.log" \
        | sed -E "s/^Test Case '-\[[^.]+\.([^ ]+) ([^]]+)\]' (passed|failed) \(([^ ]+) seconds\)\..*/\1|\2|\3|\4/" \
        | awk -F'|' '
            { cls=$1; name=$2; status=$3; time=$4
              if (cls != last) { print "  " cls; last = cls }
              marker = (status == "passed") ? "✓" : "✗"
              printf "    %s %s  (%ss)\n", marker, name, time
            }'

    echo
    echo "ios-ui (XCUITest) — app launch with --ui-testing → MDK mock pair → Connect button enables"
    grep -E "^Test Case .* (passed|failed) " "$LOG_DIR/ios-ui.log" \
        | sed -E "s/^Test Case '-\[[^.]+\.([^ ]+) ([^]]+)\]' (passed|failed) \(([^ ]+) seconds\)\..*/\1|\2|\3|\4/" \
        | awk -F'|' '
            { cls=$1; name=$2; status=$3; time=$4
              if (cls != last) { print "  " cls; last = cls }
              marker = (status == "passed") ? "✓" : "✗"
              printf "    %s %s  (%ss)\n", marker, name, time
            }'

    echo
    if [ $overall -eq 0 ]; then
        echo "All tiers passed. Logs: $LOG_DIR"
    else
        echo "One or more tiers FAILED. Inspect full logs in $LOG_DIR"
    fi
    exit $overall

# Vitest unit suite for viewer/api/viewer-token.js.
test-unit:
    cd viewer && npm test

# Playwright e2e for the viewer (auto-spawns lk publisher; needs .env + system Chrome).
test-e2e:
    cd viewer && npm run test:e2e

# iOS XCTest unit suite (Secrets, RoomConnection, MDK smoke).
test-ios-unit:
    cd ios/WazaProto && xcodebuild test \
      -project WazaProto.xcodeproj -scheme WazaProto \
      -destination 'platform=iOS Simulator,name=iPhone 17' \
      -parallel-testing-enabled NO -only-testing:WazaProtoTests

# iOS XCUITest (drives MDK test server through the SwiftUI Connect flow).
test-ios-ui:
    cd ios/WazaProto && xcodebuild test \
      -project WazaProto.xcodeproj -scheme WazaProto \
      -destination 'platform=iOS Simulator,name=iPhone 17' \
      -parallel-testing-enabled NO -only-testing:WazaProtoUITests

# --- Coach agent (plan 19) ---------------------------------------------------

# Run the coach in the foreground (dev mode: hot-reload, terminal-bound, dies
# with the terminal). For active development only. Don't run this while the
# supervised worker (`coach-up`) is live — it double-registers `waza-coach` and
# LiveKit will route summons to either one. Ctrl-C to stop.
coach:
    cd agent && uv run coach_agent.py dev

# Smoke-test the coach with local mic/speaker, no room (needs GOOGLE_API_KEY).
coach-console:
    cd agent && uv run coach_agent.py console

# Install + start the coach as a supervised always-on background service
# (production `start` mode). It auto-starts at login, restarts if it crashes,
# and survives reboots — so ✨ help always finds a worker waiting. It connects
# OUT to LiveKit Cloud (no inbound port is opened). Re-run to update the config.
coach-up:
    #!/usr/bin/env bash
    set -euo pipefail
    label=com.waza.coach
    plist="$HOME/Library/LaunchAgents/$label.plist"
    repo="{{justfile_directory()}}"
    # launchd's bare env doesn't reach the in-code SSL_CERT_FILE setdefault, so
    # the uv-managed CPython can't verify LiveKit's TLS cert. Pin certifi's CA
    # bundle here, before any Python runs (inherited by every spawned process).
    cert="$(cd "$repo/agent" && /opt/homebrew/bin/uv run python -c 'import certifi; print(certifi.where())')"
    # launchd appends to the log forever; truncate if it's grown past ~5 MB.
    log="$repo/agent/coach.log"
    [ -f "$log" ] && [ "$(stat -f%z "$log")" -gt 5000000 ] && : > "$log" || true
    cat > "$plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>$label</string>
        <key>ProgramArguments</key>
        <array>
            <string>/opt/homebrew/bin/uv</string>
            <string>run</string>
            <string>coach_agent.py</string>
            <string>start</string>
        </array>
        <key>WorkingDirectory</key><string>$repo/agent</string>
        <key>EnvironmentVariables</key>
        <dict>
            <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
            <key>SSL_CERT_FILE</key><string>$cert</string>
        </dict>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ThrottleInterval</key><integer>10</integer>
        <key>StandardOutPath</key><string>$repo/agent/coach.log</string>
        <key>StandardErrorPath</key><string>$repo/agent/coach.log</string>
    </dict>
    </plist>
    EOF
    uid=$(id -u)
    # bootout is async; wait until the old job is truly gone or bootstrap can
    # collide with it ("Input/output error").
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    for _ in $(seq 1 10); do launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break; sleep 1; done
    launchctl bootstrap "gui/$uid" "$plist"
    echo "✅ coach worker up + supervised."
    echo "   logs:  just coach-logs   ·   off:  just coach-down"

# Stop and FULLY REMOVE the supervised coach worker. It won't restart and won't
# come back on reboot — the off switch for when you're done with the project.
coach-down:
    #!/usr/bin/env bash
    set -uo pipefail
    label=com.waza.coach
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
    echo "🛑 coach worker stopped + removed."

# Is the supervised coach worker loaded and running?
coach-status:
    #!/usr/bin/env bash
    label=com.waza.coach
    launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -E 'state = |pid = ' \
        || echo "not loaded — run: just coach-up"

# Tail the supervised coach worker's log.
coach-logs:
    tail -n 40 -f agent/coach.log
