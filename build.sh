#!/bin/sh
# Builds build/MouseNudge.app from source (macOS 13+).
# Usage: ./build.sh [--universal] [--install]
#   --universal  Apple silicon + Intel in one binary (used by make-dmg.sh)
#   --install    copy to /Applications and (re)start it
# Signs with the "MouseNudge Local Signing" certificate when it exists, so the Accessibility grant survives rebuilds;
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

app=build/MouseNudge.app
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/"

# The icon is drawn from the Mac's own Mouse settings icon on the building machine, so no Apple artwork is in the repo.
if [ ! -f build/MouseNudge.icns ]; then
  swiftc -O icon/make.swift -o build/make-icon
  rm -rf build/MouseNudge.iconset; build/make-icon build/MouseNudge.iconset
  iconutil -c icns build/MouseNudge.iconset -o build/MouseNudge.icns
fi
cp build/MouseNudge.icns "$app/Contents/Resources/"

if [ "$universal" = 1 ]; then
  for arch in arm64 x86_64; do swiftc -O -target $arch-apple-macos13 Sources/*.swift -o build/MouseNudge-$arch; done
  lipo -create build/MouseNudge-arm64 build/MouseNudge-x86_64 -output "$app/Contents/MacOS/MouseNudge"
  rm build/MouseNudge-arm64 build/MouseNudge-x86_64
else
  swiftc -O -target "$(uname -m)-apple-macos13" Sources/*.swift -o "$app/Contents/MacOS/MouseNudge"
fi

identity="${SIGN_IDENTITY:-}"
if [ -z "$identity" ] && security find-certificate -c "MouseNudge Local Signing" >/dev/null 2>&1; then identity="MouseNudge Local Signing"; fi
codesign --force -s "${identity:--}" "$app"
echo "signed: ${identity:-ad hoc}"

if [ "$install" = 1 ]; then
  pkill -x MouseNudge 2>/dev/null && sleep 1 || true
  rm -rf /Applications/MouseNudge.app
  cp -R "$app" /Applications/
  open /Applications/MouseNudge.app
  echo "installed: /Applications/MouseNudge.app"
fi
# Only the installed copy should be known to Launch Services, or the Accessibility list can pick up this one instead.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] && "$lsregister" -u "$app" 2>/dev/null || true
[ "$install" = 1 ] || echo "$app"
