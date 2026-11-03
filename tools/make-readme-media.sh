#!/bin/zsh
# Renders the README images with the app's own drawing code (needs the Clawd art: run the app
# once, or `--fetch-art`) and turns the strip frames into docs/media/demo.gif. Needs ffmpeg.
set -euo pipefail
cd "${0:A:h}/.."
APP="build/Claws for Concern.app/Contents/MacOS/ClawsForConcern"
[[ -x "$APP" ]] || ./build.sh --no-install
OUT=docs/media
TMP=$(mktemp -d)
"$APP" --snapshot "$TMP"
mkdir -p $OUT
cp "$TMP"/bubble-light.png "$TMP"/bubble-dark.png $OUT/
# The hero shots are mostly gradient: a high-quality JPEG is a tenth of the PNG's size.
for v in light dark; do sips -s format jpeg -s formatOptions 92 "$TMP/hero-$v.png" --out "$OUT/hero-$v.jpg" >/dev/null; done
ffmpeg -v error -y -framerate 20 -i "$TMP/frames/strip-%03d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=none" \
  -loop 0 $OUT/demo.gif
sips -Z 256 Resources/AppIcon-1024.png --out $OUT/icon.png >/dev/null
# Search, on made-up sessions only: --demo never reads your ~/.claude (its self-test checks the paths).
SEARCH="build/Claws for Concern.app/Contents/Helpers/Claws Search.app/Contents/MacOS/ClawsSearch"
for v in light dark; do "$SEARCH" --demo --snapshot "$OUT/search-$v.png" --query '"rate limit"' --appearance $v >/dev/null; done
# Usage, on the same made-up sessions (their work sits in daytime hours whenever this runs): the window a
# little under its default size, then its last row (by project, by model, when Claude works).
for v in light dark; do
  "$SEARCH" --demo --snapshot-usage "$OUT/usage-$v.png" --size 1280x800 --select first --appearance $v >/dev/null
  "$SEARCH" --demo --snapshot-usage "$OUT/usage-more-$v.png" --size 1280x400 --part breakdown --appearance $v >/dev/null
done
rm -rf "$TMP"
ls -la $OUT
