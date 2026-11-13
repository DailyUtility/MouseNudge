#!/bin/sh
# Runs the schedule tests: the scheduling half of main.swift (everything before the UI classes), with work hours
# turned into plain variables and the data folder pointed at a temporary one, plus tests/ScheduleTests.swift.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sed '/^final class ClosureTarget/,$d' Sources/main.swift \
  | sed -e 's/^var workStart: String .*/var workStart = "09:00"/' \
        -e 's/^var workEnd: String .*/var workEnd = "18:00"/' \
        -e "s#^let dir = .*#let dir = \"$tmp/data\"#" > "$tmp/main.swift"
cat tests/ScheduleTests.swift >> "$tmp/main.swift"
swiftc "$tmp/main.swift" Sources/Language.swift Sources/Strings.swift -o "$tmp/tests"
"$tmp/tests"
