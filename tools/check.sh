#!/bin/sh
# Pipeline gate: luau-lsp strict-mode analysis, then the offline test sweep.
#
#   tools/check.sh                    # analyze + all tests
#   tools/check.sh --analyze          # analyze only
#   tools/check.sh --update-baseline  # grandfather all current diagnostics
#
# Analysis is baselined per-diagnostic: tools/analyze_baseline.txt lists every
# currently-known finding (file, line/col, kind, message), normalized and
# deduped. Any diagnostic not already in that file fails the run; commit
# tools/check.sh --update-baseline after intentionally introducing pre-existing
# debt (rare). Diagnostics that get fixed silently shrink the baseline — commit
# the updated file with your change.
set -eu
cd "$(dirname "$0")/.."

TYPES=build/globalTypes.d.luau
SOURCEMAP=build/sourcemap.json
REPORT=build/analyze.txt
NORMALIZED=build/analyze_normalized.txt
BASELINE_FILE=tools/analyze_baseline.txt

mkdir -p build

# Roblox API type definitions (gitignored; fetched once)
if [ ! -f "$TYPES" ]; then
    echo "fetching Roblox type definitions..."
    curl -fsSL -o "$TYPES" \
        https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
fi

# Lune typedefs for the @lune/* aliases in .luaurc
if [ ! -d "$HOME/.lune/.typedefs/$(lune --version | awk '{print $2}')" ]; then
    lune setup
fi

# Sourcemap so instance-style requires in src/client + src/server resolve
rojo sourcemap default.project.json -o "$SOURCEMAP"

luau-lsp analyze --definitions="$TYPES" --sourcemap="$SOURCEMAP" \
    src tests > "$REPORT" 2>&1 || true

# Strip the absolute repo-root prefix and the Rojo sourcemap annotation
# ("[game/ReplicatedStorage/...]") so entries are portable across machines,
# then dedupe: luau-lsp emits the same diagnostic once per module that
# depends on the file, so raw output has heavy duplication.
repo_root=$(pwd)
grep -E '\([0-9]+,[0-9]+\): [A-Za-z]+:' "$REPORT" \
    | sed -E "s#^${repo_root}/##; s/ \[game[^]]*\]//" \
    | sort -u > "$NORMALIZED"

if [ "${1:-}" = "--update-baseline" ]; then
    cp "$NORMALIZED" "$BASELINE_FILE"
    echo "baseline updated: $(wc -l < "$BASELINE_FILE" | tr -d ' ') diagnostics grandfathered"
    exit 0
fi

touch "$BASELINE_FILE"
new=$(comm -13 "$BASELINE_FILE" "$NORMALIZED")
fixed_count=$(comm -23 "$BASELINE_FILE" "$NORMALIZED" | wc -l | tr -d ' ')

if [ -n "$new" ]; then
    echo "== luau-lsp analyze: new diagnostics not in $BASELINE_FILE =="
    echo "$new"
    echo ""
    new_count=$(echo "$new" | wc -l | tr -d ' ')
    echo "FAIL: $new_count new diagnostic(s). Fix them, or if this is intentional"
    echo "      pre-existing debt, run: tools/check.sh --update-baseline"
    exit 1
fi

if [ "$fixed_count" -gt 0 ]; then
    cp "$NORMALIZED" "$BASELINE_FILE"
    echo "luau-lsp analyze: $fixed_count diagnostic(s) fixed — baseline shrunk, commit $BASELINE_FILE"
else
    echo "luau-lsp analyze: no new diagnostics ($(wc -l < "$NORMALIZED" | tr -d ' ') baselined; full report: $REPORT)"
fi

if [ "${1:-}" = "--analyze" ]; then
    exit 0
fi

for f in tests/test_*.luau; do
    echo "== $f"
    lune run "$f" || { echo "FAIL: $f"; exit 1; }
done
echo "OK: analyze + all tests passed"
