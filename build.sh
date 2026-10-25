#!/bin/zsh
# Builds "Claws for Concern.app".
#   ./build.sh                build, then install to /Applications (quits a running copy first)
#   ./build.sh --no-install   build only: build/Claws for Concern.app
#   UNIVERSAL=1 ./build.sh    arm64 + x86_64 (for releases)
#   SIGN_IDENTITY="Apple Development: …" ./build.sh
#       Sign with a stable identity. macOS keys the Ghostty permission to the signature, so an
#       ad-hoc build (the default) asks again after every rebuild.
set -euo pipefail
cd "${0:A:h}"

APP="build/Claws for Concern.app"
MODE="${1:-}"
IDENTITY="${SIGN_IDENTITY:--}"
ARCHS=($(uname -m))
[[ "${UNIVERSAL:-}" == 1 ]] && ARCHS=(arm64 x86_64)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in $ARCHS; do
  FLAGS=(-O -swift-version 5 -target "$arch-apple-macos14.0")
  xcrun swiftc $FLAGS -parse-as-library Sources/Shared/*.swift Sources/App/**/*.swift -o "build/obj/app-$arch"
  xcrun swiftc $FLAGS Sources/Shared/*.swift Sources/Hook/main.swift -o "build/obj/hook-$arch"
done
lipo -create build/obj/app-* -output "$APP/Contents/MacOS/ClawsForConcern"
lipo -create build/obj/hook-* -output "$APP/Contents/MacOS/claws-for-concern-hook"
rm -rf build/obj

cp Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] || xcrun swift tools/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/claws-for-concern-hook"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

if [[ "$MODE" != "--no-install" ]]; then
  # A signal, not an AppleScript "quit": that needs Automation permission for whatever runs this script.
  pkill -x ClawsForConcern 2>/dev/null && sleep 0.7 || true
  rm -rf "/Applications/Claws for Concern.app"
  cp -R "$APP" /Applications/
  echo "installed /Applications/Claws for Concern.app"
else
  echo "built $APP"
fi
