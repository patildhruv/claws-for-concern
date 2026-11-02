#!/bin/zsh
# Builds "Claws for Concern.app", with the search helper inside it (Contents/Helpers/Claws Search.app).
#   ./build.sh                build, then install to /Applications (quits a running copy first)
#   ./build.sh --no-install   build only: build/Claws for Concern.app
#   UNIVERSAL=1 ./build.sh    arm64 + x86_64 (for releases)
#   SIGN_IDENTITY="Apple Development: …" ./build.sh
#       Sign with a stable identity. macOS keys the Ghostty permission to the signature, so an
#       ad-hoc build (the default) asks again after every rebuild.
set -euo pipefail
cd "${0:A:h}"

APP="build/Claws for Concern.app"
HELPER="$APP/Contents/Helpers/Claws Search.app"
MODE="${1:-}"
IDENTITY="${SIGN_IDENTITY:--}"
ARCHS=($(uname -m))
[[ "${UNIVERSAL:-}" == 1 ]] && ARCHS=(arm64 x86_64)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources" build/obj

for arch in $ARCHS; do
  FLAGS=(-O -swift-version 5 -target "$arch-apple-macos14.0")
  # The app compiles the helper's request format too, so both sides of the notification agree.
  xcrun swiftc $FLAGS -parse-as-library Sources/Shared/*.swift Sources/App/**/*.swift Sources/Search/ResumeRequest.swift \
    -o "build/obj/app-$arch"
  xcrun swiftc $FLAGS Sources/Shared/*.swift Sources/Hook/main.swift -o "build/obj/hook-$arch"
  xcrun swiftc $FLAGS -parse-as-library Sources/Search/*.swift -o "build/obj/search-$arch"
done
lipo -create build/obj/app-* -output "$APP/Contents/MacOS/ClawsForConcern"
lipo -create build/obj/hook-* -output "$APP/Contents/MacOS/claws-for-concern-hook"
lipo -create build/obj/search-* -output "$HELPER/Contents/MacOS/ClawsSearch"
rm -rf build/obj

cp Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] || xcrun swift tools/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# The helper carries the app's version.
cp Sources/Search/Info.plist "$HELPER/Contents/"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Add :$key string $(/usr/libexec/PlistBuddy -c "Print :$key" Info.plist)" "$HELPER/Contents/Info.plist"
done
[[ -f Resources/SearchIcon.icns ]] || xcrun swift tools/make-icon.swift Resources search
cp Resources/SearchIcon.icns "$HELPER/Contents/Resources/"

# Inside out: nested code first, the app last, so its signature seals the helper's.
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/claws-for-concern-hook"
codesign --force --sign "$IDENTITY" "$HELPER"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "$MODE" != "--no-install" ]]; then
  # A signal, not an AppleScript "quit": that needs Automation permission for whatever runs this script.
  pkill -x ClawsForConcern 2>/dev/null && sleep 0.7 || true
  pkill -x ClawsSearch 2>/dev/null || true
  rm -rf "/Applications/Claws for Concern.app"
  cp -R "$APP" /Applications/
  echo "installed /Applications/Claws for Concern.app"
else
  echo "built $APP"
fi
