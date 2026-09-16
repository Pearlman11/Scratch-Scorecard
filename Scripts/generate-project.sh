#!/usr/bin/env bash
# Generates GolfTracker.xcodeproj from project.yml, installing XcodeGen if it is missing.
#
# The Xcode project is not committed: it is derived entirely from the file tree plus project.yml, so it
# cannot drift from the files on disk, and adding a file never causes a merge conflict in a
# three-thousand-line pbxproj.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "XcodeGen not found. Installing with Homebrew..."
    brew install xcodegen
  else
    cat <<'MESSAGE'
XcodeGen is required to generate the Xcode project, and Homebrew was not found.

Install Homebrew from https://brew.sh then re-run this script, or install XcodeGen another way:
  https://github.com/yonaskolb/XcodeGen#installing

To work on the parser alone, no Xcode project is needed — open Package.swift in Xcode instead.
MESSAGE
    exit 1
  fi
fi

xcodegen generate
echo
echo "Generated GolfTracker.xcodeproj"
echo "Open it with:  open GolfTracker.xcodeproj"
