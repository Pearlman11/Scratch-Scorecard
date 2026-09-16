#!/usr/bin/env bash
# One command to build everything on a Mac and print a compact, paste-able error summary.
#
# Runs the same two stages as CI, cheapest first: the parser package on its own, then the iOS app. Stopping
# at the first stage that fails is deliberate — the app imports ScorecardKit, so app errors caused by a
# broken package are noise that buries the real ones.
#
# Usage:
#   Scripts/build-local.sh           # build package, test it, then build the app
#   Scripts/build-local.sh --kit     # package only (fast: no Xcode project, no simulator)
set -uo pipefail

cd "$(dirname "$0")/.."
LOG_DIR="$(mktemp -d)"
KIT_ONLY="${1:-}"

banner() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

# Prints the first N unique compiler errors, which is what is actually useful to act on. A raw xcodebuild
# log is tens of thousands of lines and mostly repeats each error once per compilation unit.
summarize() {
  local log="$1" label="$2"
  banner "$label — unique errors"
  if grep -E "error:" "$log" >/dev/null 2>&1; then
    grep -E "error:" "$log" | sed 's|'"$PWD"'/||' | sort -u | head -60
    echo
    echo "Total unique errors: $(grep -cE 'error:' "$log" | head -1)"
    echo "Full log: $log"
  else
    echo "(no 'error:' lines found — see $log)"
  fi
}

banner "Toolchain"
xcodebuild -version || true
swift --version || true

banner "Stage 1/3 — building ScorecardKit"
if ! swift build 2>&1 | tee "$LOG_DIR/kit-build.log"; then
  summarize "$LOG_DIR/kit-build.log" "ScorecardKit build"
  echo
  echo "Fix these first: the app cannot build until the package does."
  exit 1
fi
echo "ScorecardKit built."

banner "Stage 2/3 — testing ScorecardKit"
if ! swift test 2>&1 | tee "$LOG_DIR/kit-test.log"; then
  banner "Test failures"
  grep -E "error:|XCTAssert|failed \(" "$LOG_DIR/kit-test.log" | sort -u | head -60
  echo
  echo "Full log: $LOG_DIR/kit-test.log"
  exit 1
fi
echo "ScorecardKit tests passed."

if [ "$KIT_ONLY" = "--kit" ]; then
  banner "Done (package only)"
  exit 0
fi

banner "Stage 3/3 — building the iOS app"
./Scripts/generate-project.sh >/dev/null || { echo "Could not generate the Xcode project."; exit 1; }

set -o pipefail
if ! xcodebuild build \
  -project GolfTracker.xcodeproj \
  -scheme GolfTracker \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$LOG_DIR/app-build.log"; then
  summarize "$LOG_DIR/app-build.log" "iOS app build"
  exit 1
fi

banner "Everything built"
echo "Open the project and press Run:  open GolfTracker.xcodeproj"
