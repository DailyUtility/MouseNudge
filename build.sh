#!/bin/sh
# Builds build/Shiftbell.app from source (macOS 13+).
# Usage: ./build.sh [--universal] [--install]
#   --universal  Apple silicon + Intel in one binary (used by make-dmg.sh)
#   --install    copy to /Applications and (re)start it
# Signs with the "Shiftbell Local Signing" certificate when it exists, so the Accessibility grant survives rebuilds;
# otherwise ad hoc. Set SIGN_IDENTITY to use another identity.
set -e
cd "$(dirname "$0")"
universal=0; install=0
for a in "$@"; do
  case "$a" in
    --universal) universal=1 ;;
    --install) install=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

app=build/Shiftbell.app
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/"

# The icon is drawn from the Mac's own Mouse settings icon on the building machine, so no Apple artwork is in the repo.
if [ ! -f build/Shiftbell.icns ]; then
  swiftc -O icon/make.swift -o build/make-icon
  rm -rf build/Shiftbell.iconset; build/make-icon build/Shiftbell.iconset
  iconutil -c icns build/Shiftbell.iconset -o build/Shiftbell.icns
fi
cp build/Shiftbell.icns "$app/Contents/Resources/"

if [ "$universal" = 1 ]; then
  for arch in arm64 x86_64; do swiftc -O -target $arch-apple-macos13 Sources/*.swift -o build/Shiftbell-$arch; done
  lipo -create build/Shiftbell-arm64 build/Shiftbell-x86_64 -output "$app/Contents/MacOS/Shiftbell"
  rm build/Shiftbell-arm64 build/Shiftbell-x86_64
else
  swiftc -O -target "$(uname -m)-apple-macos13" Sources/*.swift -o "$app/Contents/MacOS/Shiftbell"
fi

identity="${SIGN_IDENTITY:-}"
if [ -z "$identity" ] && security find-certificate -c "Shiftbell Local Signing" >/dev/null 2>&1; then identity="Shiftbell Local Signing"; fi
codesign --force -s "${identity:--}" "$app"
echo "signed: ${identity:-ad hoc}"

if [ "$install" = 1 ]; then
  # When the launch agent runs it, a plain kill counts as a crash and launchd restarts the old copy, so swap the
  # files first and let launchd restart it.
  job="gui/$(id -u)/io.github.mar-er.shiftbell.keepalive"
  if launchctl print "$job" >/dev/null 2>&1; then
    rm -rf /Applications/Shiftbell.app; cp -R "$app" /Applications/
    launchctl kickstart -k "$job"
  else
    pkill -x Shiftbell 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Shiftbell.app
    cp -R "$app" /Applications/
    open /Applications/Shiftbell.app
  fi
  echo "installed: /Applications/Shiftbell.app"
fi
# Only the installed copy should be known to Launch Services, or the Accessibility list can pick up this one instead.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] && "$lsregister" -u "$app" 2>/dev/null || true
[ "$install" = 1 ] || echo "$app"
