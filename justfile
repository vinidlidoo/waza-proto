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

# Run the AI coach against the LiveKit Cloud room (needs GOOGLE_API_KEY in .env).
coach:
    cd agent && uv run coach_agent.py dev

# Smoke-test the coach with local mic/speaker, no room (needs GOOGLE_API_KEY).
coach-console:
    cd agent && uv run coach_agent.py console
