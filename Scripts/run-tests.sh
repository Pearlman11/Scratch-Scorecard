#!/usr/bin/env bash
# Runs the ScorecardKit test suite.
#
# The parser core is a platform-independent SwiftPM package, so its tests run with plain `swift test` on
# macOS without a simulator. That is deliberate: the tests that matter most should be the fastest to run.
set -euo pipefail

cd "$(dirname "$0")/.."
swift test "$@"
