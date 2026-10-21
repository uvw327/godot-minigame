#!/usr/bin/env bash
set -euo pipefail

# Install a validated mini-game engine template bundle as the plugin's bundled
# engine pack, then re-sync every machine-readable identity that pins it.
#
# Usage:
#   scripts/install_engine_template.sh <bundle.zip> [--skip-site]
#
# The bundle must come from scripts/build_wasm_template.sh (or the CI
# "Build Mini-Game WASM Template" workflow). It is validated with the shared
# verifier before anything on disk is touched, so a partial or tampered zip
# can never replace the committed engine identity.
#
# This script only edits machine-readable files:
#   - addons/godot_mini_game/engine/{godot.js,godot.wasm.br,version.txt,template.json}
#   - addons/godot_mini_game/GODOT_COPYRIGHT.txt (beside THIRD_PARTY_NOTICES.md)
#   - support-matrix.json (the single bundled certification row)
#   - website/app/site-data.generated.ts (regenerated)
#
# Human-readable prose (README badge/table, docs/*, THIRD_PARTY_NOTICES.md) is
# intentionally left alone: run the checklist printed at the end, or follow
# docs/UPGRADE_ENGINE.md. HTML/docs are kept in lockstep with support-matrix by
# deferring them to the same change that installs the bundle.

export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="${PROJECT_DIR}/addons/godot_mini_game/engine"
COPYRIGHT_FILE="${PROJECT_DIR}/addons/godot_mini_game/GODOT_COPYRIGHT.txt"
SUPPORT_MATRIX="${PROJECT_DIR}/support-matrix.json"
SITE_GENERATOR="${PROJECT_DIR}/website/scripts/generate-site-data.mjs"

if [ "$#" -lt 1 ]; then
    echo "Usage: scripts/install_engine_template.sh <bundle.zip> [--skip-site]" >&2
    exit 1
fi

BUNDLE="$1"
shift
SKIP_SITE=0
for argument in "$@"; do
    case "$argument" in
        --skip-site) SKIP_SITE=1 ;;
        *)
            echo "Unknown argument: $argument" >&2
            exit 1
            ;;
    esac
done

for command_name in jq unzip node; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 1
    fi
done

if [ ! -s "$BUNDLE" ]; then
    echo "Bundle is missing or empty: $BUNDLE" >&2
    exit 1
fi
if [ ! -s "$SUPPORT_MATRIX" ]; then
    echo "Missing support matrix: $SUPPORT_MATRIX" >&2
    exit 1
fi

# 1. Validate the bundle with the same verifier CI uses. This enforces the
#    manifest schema, exact hashes, disabled WASM features, and the matrix ABI.
"${SCRIPT_DIR}/verify_wasm_template.sh" "$BUNDLE"

# 2. Stage and read the bundle identity.
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
unzip -q "$BUNDLE" -d "$TEMP_DIR/bundle"

VERSION="$(jq -er '.godot.version' "$TEMP_DIR/bundle/template.json")"
COMMIT="$(jq -er '.godot.commit' "$TEMP_DIR/bundle/template.json")"
EMSCRIPTEN_VERSION="$(jq -er '.emscriptenVersion' "$TEMP_DIR/bundle/template.json")"
REVISION="$(jq -er '.revision' "$TEMP_DIR/bundle/template.json")"
PROFILE="$(jq -er '.profile | select(type == "string" and test("^[a-z0-9][a-z0-9_-]*$"))' "$TEMP_DIR/bundle/template.json")"
TAG="$(printf '%s' "$VERSION" \
    | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)\.(.+)$/\1-\2/')"

# The engine cut must be one this repository knows how to build, otherwise the
# certified row would point at a profile nobody can reproduce.
if [ ! -s "${SCRIPT_DIR}/engine_profiles/${PROFILE}.py" ]; then
    echo "Bundle declares an unknown engine profile: ${PROFILE}" >&2
    echo "Expected an options file at scripts/engine_profiles/${PROFILE}.py" >&2
    exit 1
fi

if ! [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z]+$ ]]; then
    echo "Cannot derive an exact Godot tag from version: $VERSION" >&2
    exit 1
fi

# 3. Install the engine files (identity is taken verbatim from the bundle). The
#    bundled engine directory carries only the four runtime files; the Godot
#    copyright notice is distributed beside THIRD_PARTY_NOTICES.md.
for required in godot.js godot.wasm.br version.txt template.json; do
    if [ ! -s "$TEMP_DIR/bundle/$required" ]; then
        echo "Bundle is missing or has an empty $required" >&2
        exit 1
    fi
    cp "$TEMP_DIR/bundle/$required" "${ENGINE_DIR}/$required"
done
if [ ! -s "$TEMP_DIR/bundle/GODOT_COPYRIGHT.txt" ]; then
    echo "Bundle is missing or has an empty GODOT_COPYRIGHT.txt" >&2
    exit 1
fi
cp "$TEMP_DIR/bundle/GODOT_COPYRIGHT.txt" "$COPYRIGHT_FILE"

# 4. Re-point the single bundled certification row. Invalid or multiple bundled
#    rows are a hard error so the matrix can never drift silently.
BUNDLED_ROWS="$(jq -er '[.certified[] | select(.template.source == "bundled")] | length' "$SUPPORT_MATRIX")"
if [ "$BUNDLED_ROWS" != "1" ]; then
    echo "support-matrix.json must declare exactly one bundled row, found: $BUNDLED_ROWS" >&2
    exit 1
fi

MATRIX_TMP="$(mktemp "${PROJECT_DIR}/support-matrix.json.XXXXXX")"
jq \
    --arg version "$VERSION" \
    --arg tag "$TAG" \
    --arg commit "$COMMIT" \
    --arg emscripten "$EMSCRIPTEN_VERSION" \
    --arg profile "$PROFILE" \
    --argjson revision "$REVISION" \
    '
      .certified |= map(
        if (.template.source // "") == "bundled"
        then
          .godotVersion = $version
          | .godotTag = $tag
          | .godotCommit = $commit
          | .emscriptenVersion = $emscripten
          | .profile = $profile
          | .templateRevision = $revision
        else .
        end
      )
    ' "$SUPPORT_MATRIX" > "$MATRIX_TMP"
mv "$MATRIX_TMP" "$SUPPORT_MATRIX"

# 5. Regenerate the website release data so it stays derived, never hand-edited.
if [ "$SKIP_SITE" -eq 0 ]; then
    node "$SITE_GENERATOR"
fi

echo ""
echo "Installed bundled engine template:"
echo "  Godot        ${VERSION} (tag ${TAG})"
echo "  Commit       ${COMMIT}"
echo "  Emscripten   ${EMSCRIPTEN_VERSION}"
echo "  Profile      ${PROFILE}"
echo "  Revision     ${REVISION}"
echo ""
echo "Remaining manual steps (prose that cannot be machine-derived):"
echo "  1. README.md / README_zh.md: badge, and the Godot/commit + Emscripten table rows."
echo "  2. docs/USAGE.md / docs/USAGE_zh.md: certification table + build examples."
echo "  3. docs/ARCHITECTURE.md: version examples in the engine-bundle and store sections."
echo "  4. addons/godot_mini_game/THIRD_PARTY_NOTICES.md: bundled Godot version."
echo "  See docs/UPGRADE_ENGINE.md for the exact token checklist and a copy/paste sed command."
echo ""
echo "Then run: GODOT_BIN=<godot-${TAG%%-*}> ./scripts/test.sh"
