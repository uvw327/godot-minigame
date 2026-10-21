#!/usr/bin/env bash
set -euo pipefail

# Create the immutable release tag for the Godot Mini Game plugin.
#
# Usage:
#   scripts/release_plugin.sh v4.7.2-stable.mod.1
#   scripts/release_plugin.sh v4.7.2-stable.mod.1 --no-push
#
# The tag scheme is defined in docs/SLIM_GODOT_ENGINE.md:
#   v<GodotTag>.mod.<N>
#   v<GodotTag>.mod.<N>-engine.<name>.<M>
#
# Requirements:
#   - the tag targets the Godot version the bundled certified engine ships
#   - plugin.cfg and support-matrix.json agree on the plugin version
#   - the working tree is clean and carries the exact release contents

usage() {
    cat <<'EOF'
Usage: scripts/release_plugin.sh <tag> [--no-push]

Examples:
  scripts/release_plugin.sh v4.7.2-stable.mod.1
  scripts/release_plugin.sh v4.7.2-stable.mod.1-engine.minigame.1
  scripts/release_plugin.sh v4.7.2-stable.mod.1 --no-push

The script validates the tag, rebuilds the reproducible install ZIP, refuses
existing local or remote tags, and pushes the tag. The tag-driven GitHub
Actions workflow is the only release publisher.
EOF
}

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 1
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

TAG="$1"
shift

NO_PUSH=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-push) NO_PUSH=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$TAG" in
    v*) ;;
    *) TAG="v${TAG}" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_CFG="${PROJECT_DIR}/addons/godot_mini_game/plugin.cfg"
SUPPORT_MATRIX="${PROJECT_DIR}/support-matrix.json"

cd "$PROJECT_DIR"

for cmd in git jq zip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
done

if [ ! -f "$PLUGIN_CFG" ]; then
    echo "Missing plugin config: $PLUGIN_CFG" >&2
    exit 1
fi
if [ ! -s "$SUPPORT_MATRIX" ]; then
    echo "Missing support matrix: $SUPPORT_MATRIX" >&2
    exit 1
fi

# Validate the tag shape and the release identities it claims.
TAG_FACTS="$("${SCRIPT_DIR}/validate_release_tag.sh" "$TAG")" || exit 1
GODOT_TAG="$(printf '%s\n' "$TAG_FACTS" | sed -n 's/^godot_tag=//p')"
ITERATION="$(printf '%s\n' "$TAG_FACTS" | sed -n 's/^iteration=//p')"
ENGINE_NAME="$(printf '%s\n' "$TAG_FACTS" | sed -n 's/^engine_name=//p')"
ENGINE_ITERATION="$(printf '%s\n' "$TAG_FACTS" | sed -n 's/^engine_iteration=//p')"
PACKAGE_NAME="$(printf '%s\n' "$TAG_FACTS" | sed -n 's/^package_name=//p')"
ZIP_PATH="${PROJECT_DIR}/dist/${PACKAGE_NAME}.zip"

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is not clean. Commit the exact release contents first." >&2
    git status --short
    exit 1
fi

# The iteration must be the next one for this Godot tag, and an engine release
# must sit on an existing mod tag. Both rules come from
# docs/SLIM_GODOT_ENGINE.md; the sequence check itself lives in a standalone
# script so it can be exercised against fixtures instead of the live remote.
if ! REMOTE_TAGS="$(git ls-remote --refs --tags origin "refs/tags/v${GODOT_TAG}.mod.*" 2>/dev/null)"; then
    echo "Unable to list remote tags; refusing to publish." >&2
    exit 1
fi
printf '%s\n' "$REMOTE_TAGS" | "${SCRIPT_DIR}/check_release_iteration.sh" "$TAG" || exit 1

"${SCRIPT_DIR}/package_plugin.sh" "$PACKAGE_NAME"

if [ ! -f "$ZIP_PATH" ]; then
    echo "Package was not created: $ZIP_PATH" >&2
    exit 1
fi

if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Refusing to reuse existing local tag: $TAG" >&2
    exit 1
fi

if ! REMOTE_REFS="$(git ls-remote --tags origin "refs/tags/${TAG}" "refs/tags/${TAG}^{}")"; then
    echo "Unable to verify whether remote tag $TAG exists; refusing to publish." >&2
    exit 1
fi
if [ -n "$REMOTE_REFS" ]; then
    echo "Refusing to reuse existing remote tag: $TAG" >&2
    exit 1
fi

git tag -a "$TAG" -m "Release $TAG"
echo "Created tag: $TAG"

if [ "$NO_PUSH" = false ]; then
    git push origin "$TAG"
fi

echo ""
echo "Local package verified:"
echo "  $ZIP_PATH"
if [ "$NO_PUSH" = false ]; then
    echo "GitHub Actions will publish the immutable release for $TAG."
else
    echo "Tag was not pushed; review it and run: git push origin $TAG"
fi
