#!/bin/sh
# Builds a shareable Shiftbell.dmg (Apple silicon + Intel, macOS 13+) with the usual "drag to Applications" window.
# Usage: ./make-dmg.sh [output.dmg]
set -e
cd "$(dirname "$0")"
# Named after the version in Resources/Info.plist, e.g. build/Shiftbell-1.0.0.dmg.
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
out="${1:-$PWD/build/Shiftbell-$version.dmg}"
./build.sh --universal >/dev/null
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
cp -R build/Shiftbell.app "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Shiftbell -srcfolder "$stage" -format UDZO -ov "$out" >/dev/null
echo "$out"
