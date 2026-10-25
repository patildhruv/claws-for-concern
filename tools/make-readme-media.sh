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
rm -rf "$TMP"
ls -la $OUT
