#!/usr/bin/env bash
set -euo pipefail

# Validate a release tag against the fork's versioning spec and print its parts.
#
# Usage:
#   scripts/validate_release_tag.sh v4.7.2-stable.mod.1
#   scripts/validate_release_tag.sh v4.7.2-stable.mod.1-engine.minigame.1
#
# Accepted formats (see docs/SLIM_GODOT_ENGINE.md):
#   v<GodotTag>.mod.<N>
#   v<GodotTag>.mod.<N>-engine.<name>.<M>
#
# The tag must target the exact Godot tag the bundled certified engine ships,
# and the plugin version must agree across plugin.cfg and support-matrix.json.
#
# Prints key=value lines on stdout:
#   tag, godot_tag, iteration, engine_name, engine_iteration,
#   plugin_version, package_name

usage() {
    cat <<'EOF'
Usage: scripts/validate_release_tag.sh <tag>

Accepts v<GodotTag>.mod.<N> and v<GodotTag>.mod.<N>-engine.<name>.<M>.
EOF
}

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 1
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

TAG="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_CFG="${PROJECT_DIR}/addons/godot_mini_game/plugin.cfg"
SUPPORT_MATRIX="${PROJECT_DIR}/support-matrix.json"

cd "$PROJECT_DIR"

if ! command -v jq >/dev/null 2>&1; then
    echo "Missing required command: jq" >&2
    exit 1
fi
if [ ! -f "$PLUGIN_CFG" ]; then
    echo "Missing plugin config: $PLUGIN_CFG" >&2
    exit 1
fi
if [ ! -s "$SUPPORT_MATRIX" ]; then
    echo "Missing support matrix: $SUPPORT_MATRIX" >&2
    exit 1
fi

# v<GodotTag>.mod.<N>[-engine.<name>.<M>]
if ! [[ "$TAG" =~ ^v([0-9A-Za-z.+-]+)\.mod\.([1-9][0-9]*)(-engine\.([a-z][a-z0-9]*(-[a-z0-9]+)*)\.([1-9][0-9]*))?$ ]]; then
    echo "Invalid release tag: $TAG" >&2
    echo "Expected v<GodotTag>.mod.<N> or v<GodotTag>.mod.<N>-engine.<name>.<M>" >&2
    echo "See docs/SLIM_GODOT_ENGINE.md for the version scheme." >&2
    exit 1
fi

GODOT_TAG="${BASH_REMATCH[1]}"
ITERATION="${BASH_REMATCH[2]}"
ENGINE_NAME=""
ENGINE_ITERATION=""
if [ -n "${BASH_REMATCH[3]}" ]; then
    ENGINE_NAME="${BASH_REMATCH[4]}"
    ENGINE_ITERATION="${BASH_REMATCH[6]}"
fi

# The release must target the Godot tag the bundled certified engine actually ships.
BUNDLED_GODOT_TAG="$(jq -er '
    [.certified[] | select(.template.source == "bundled") | .godotTag]
    | if length == 1 then .[0] else error("support-matrix.json must declare exactly one bundled certified row") end
' "$SUPPORT_MATRIX")"
if [ "$GODOT_TAG" != "$BUNDLED_GODOT_TAG" ]; then
    echo "Godot tag mismatch:" >&2
    echo "  tag:                   $GODOT_TAG" >&2
    echo "  bundled certified tag: $BUNDLED_GODOT_TAG" >&2
    echo "The release must target the Godot version the bundled engine ships." >&2
    exit 1
fi

CFG_VERSION="$(grep 'version=' "$PLUGIN_CFG" | head -1 | cut -d'"' -f2)"
MATRIX_VERSION="$(jq -er '.pluginVersion | select(type == "string" and length > 0)' "$SUPPORT_MATRIX")"
if [ "$CFG_VERSION" != "$MATRIX_VERSION" ]; then
    echo "Plugin version mismatch:" >&2
    echo "  plugin.cfg:          $CFG_VERSION" >&2
    echo "  support-matrix.json: $MATRIX_VERSION" >&2
    echo "Update both before releasing." >&2
    exit 1
fi

echo "tag=$TAG"
echo "godot_tag=$GODOT_TAG"
echo "iteration=$ITERATION"
echo "engine_name=$ENGINE_NAME"
echo "engine_iteration=$ENGINE_ITERATION"
echo "plugin_version=$CFG_VERSION"
echo "package_name=godot_mini_game_${TAG}"
