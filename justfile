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

# Vitest unit suite for viewer/api/token.js.
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
      -parallel-testing-enabled NO

# iOS XCUITest (drives MDK test server through the SwiftUI Connect flow).
test-ios-ui:
    cd ios/WazaProto && xcodebuild test \
      -project WazaProto.xcodeproj -scheme WazaProto \
      -destination 'platform=iOS Simulator,name=iPhone 17' \
      -parallel-testing-enabled NO -only-testing:WazaProtoUITests
