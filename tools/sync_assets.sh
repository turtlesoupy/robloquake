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

Built assets/$GAME chunks (and build/QuakeAssets.rbxl for manual import).

Preferred import path — serve exactly the folders the target mode needs:
  1. lune run tools/mode assets <preset>     # writes assets-current.project.json
  2. pkill -f "rojo serve"; rojo serve assets-current.project.json
  3. Studio Rojo plugin: Connect -> accept patch -> Disconnect
  4. Restore the code serve: pkill -f "rojo serve"; rojo serve
For publishing (strip + preset alignment + attribute stamp) follow
docs/PUBLISHING.md end to end. Never hand-type attribute sets — a missing
fraglimit/timelimit silently boots a no-limit server.
EOF
