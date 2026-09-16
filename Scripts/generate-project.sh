#!/usr/bin/env bash
# Generates GolfTracker.xcodeproj from project.yml.
#
# The Xcode project is not committed: it is derived entirely from the file tree plus project.yml, and a
# generated project cannot drift from the files that are actually on disk.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  cat <<'MESSAGE'
xcodegen is not installed.

  brew install xcodegen

Alternatively, open Package.swift in Xcode to work on ScorecardKit and its tests without the app target.
MESSAGE
  exit 1
fi

xcodegen generate
echo "Generated GolfTracker.xcodeproj. Open it with: open GolfTracker.xcodeproj"
