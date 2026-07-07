#!/bin/sh
# Build the QuakeAssets import file for Studio.
#
# Code syncs live via `rojo serve default.project.json`. Assets are a
# one-shot import instead: they're ~200MB of StringValue chunks that
# change a few times ever, so we `rojo build` them into a place file
# and insert the QuakeAssets folder manually.
#
# Usage: tools/sync_assets.sh [game]   (game = id1 | lq1, default id1)
set -e
cd "$(dirname "$0")/.."

GAME="${1:-id1}"

python3 tools/build_assets.py --game "$GAME"
# qwprogs.dat ships outside the paks; the QuakeWorld engine needs it
python3 tools/build_assets.py --file reference/quake-c/qw-qc/qwprogs.dat --game "$GAME"

mkdir -p build
rojo build assets.project.json -o build/QuakeAssets.rbxl

cat <<EOF

Built build/QuakeAssets.rbxl. To import into Studio:
  1. Open build/QuakeAssets.rbxl in Studio.
  2. Copy the ServerStorage.QuakeAssets folder.
  3. In your game place: delete ServerStorage.QuakeAssets, paste the new one.
  4. Re-stamp the mode attributes (they live in the place, not in rojo):
       lune run tools/mode stamp <preset>
     and paste the printed snippet into the Studio command bar. Never
     hand-type attribute sets — a missing fraglimit/timelimit silently
     boots a no-limit server.
  5. Save the place.
EOF
