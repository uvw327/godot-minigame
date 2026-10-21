#!/usr/bin/env bash
set -euo pipefail

# Build one immutable, exact-version mini-game WASM template bundle.
#
# Usage:
#   scripts/build_wasm_template.sh [godot_tag] [emsdk_version] [output_dir]
#
# Optional environment variables:
#   GODOT_MINIGAME_BUILD_DIR  Persistent compiler/source cache.
#   TEMPLATE_REVISION         Bundle revision (default: 3).
#   BUILD_PROFILE             Engine profile name (default: 2d_full). The
#                             matching options file must live in
#                             scripts/engine_profiles/<name>.py.
#   GODOT_SOURCE_DIR          Use an existing Godot checkout instead of
#                             cloning one. The checkout must be a pristine Git
#                             worktree at exactly GODOT_TAG.
#
# The build invariants (platform, target, arch, threads, javascript_eval, ...)
# live here so the local build and the CI workflow cannot drift apart.  What a
# profile changes is the engine cut, and it lives in
# scripts/engine_profiles/<profile>.py.

export TZ=UTC

GODOT_TAG="${1:-4.7.2-stable}"
EMSDK_VERSION="${2:-4.0.11}"
TEMPLATE_REVISION="${TEMPLATE_REVISION:-3}"
BUILD_PROFILE="${BUILD_PROFILE:-2d_full}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SUPPORT_MATRIX="${PROJECT_DIR}/support-matrix.json"
PROFILE_DIR="${SCRIPT_DIR}/engine_profiles"
PROFILE_FILE="${PROFILE_DIR}/${BUILD_PROFILE}.py"
BUILD_ROOT="${GODOT_MINIGAME_BUILD_DIR:-${PROJECT_DIR}/build_wasm}"
SOURCE_DIR="${GODOT_SOURCE_DIR:-${BUILD_ROOT}/godot-${GODOT_TAG}}"
EMSDK_DIR="${BUILD_ROOT}/emsdk"
CANONICAL_VERSION="${GODOT_TAG//-/.}"

if ! [[ "$GODOT_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z]+$ ]]; then
    echo "Godot tag must be exact, for example 4.7.2-stable: $GODOT_TAG" >&2
    exit 1
fi
if ! [[ "$EMSDK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    echo "Emscripten SDK version must be exact, for example 4.0.11: $EMSDK_VERSION" >&2
    exit 1
fi
if ! [[ "$TEMPLATE_REVISION" =~ ^[1-9][0-9]*$ ]]; then
    echo "TEMPLATE_REVISION must be a positive integer" >&2
    exit 1
fi
if ! [[ "$BUILD_PROFILE" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "BUILD_PROFILE must be a lowercase engine profile name: $BUILD_PROFILE" >&2
    exit 1
fi
if [ ! -s "$PROFILE_FILE" ]; then
    echo "Missing engine profile options file: $PROFILE_FILE" >&2
    echo "Known profiles:" >&2
    find "$PROFILE_DIR" -maxdepth 1 -name '*.py' -printf '  %f\n' 2>/dev/null || true
    exit 1
fi

for command_name in git python3 scons brotli jq node zip unzip wasm-validate xxd; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 1
    fi
done

if [ ! -s "$SUPPORT_MATRIX" ]; then
    echo "Missing support matrix: $SUPPORT_MATRIX" >&2
    exit 1
fi
BRIDGE_ABI="$(jq -er '.bridgeAbi | select(type == "number" and . > 0 and (. % 1 == 0))' "$SUPPORT_MATRIX")"
TEMPLATE_SCHEMA="$(jq -er '.templateSchema | select(type == "number" and . > 0 and (. % 1 == 0))' "$SUPPORT_MATRIX")"
OUTPUT_DIR="${3:-${BUILD_ROOT}/output/${GODOT_TAG}/emsdk-${EMSDK_VERSION}/${BUILD_PROFILE}/release/abi-${BRIDGE_ABI}/r${TEMPLATE_REVISION}}"

mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

if command -v emcc >/dev/null 2>&1; then
    echo "Using the Emscripten toolchain already on PATH"
else
    if [ ! -d "$EMSDK_DIR/.git" ]; then
        git clone https://github.com/emscripten-core/emsdk.git "$EMSDK_DIR"
    fi
    "${EMSDK_DIR}/emsdk" install "$EMSDK_VERSION"
    "${EMSDK_DIR}/emsdk" activate "$EMSDK_VERSION"
    source "${EMSDK_DIR}/emsdk_env.sh" >/dev/null
fi

if [ -n "${GODOT_SOURCE_DIR:-}" ]; then
    if [ ! -d "$SOURCE_DIR/.git" ]; then
        echo "GODOT_SOURCE_DIR is not a Git checkout: $SOURCE_DIR" >&2
        exit 1
    fi
    echo "Using the provided Godot checkout: $SOURCE_DIR"
elif [ ! -d "$SOURCE_DIR/.git" ]; then
    git clone --depth 1 --branch "$GODOT_TAG" https://github.com/godotengine/godot.git "$SOURCE_DIR"
fi

ACTUAL_TAG="$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)"
if [ "$ACTUAL_TAG" != "$GODOT_TAG" ]; then
    echo "Cached source is not the requested exact tag: ${ACTUAL_TAG:-unknown}" >&2
    echo "Choose a new GODOT_MINIGAME_BUILD_DIR instead of reusing the wrong source." >&2
    exit 1
fi
SOURCE_STATUS="$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)"
if [ -n "$SOURCE_STATUS" ]; then
    echo "Cached Godot source contains local changes or untracked files:" >&2
    printf '%s\n' "$SOURCE_STATUS" >&2
    echo "Choose a clean GODOT_MINIGAME_BUILD_DIR; the build will not guess which files are safe." >&2
    exit 1
fi
GODOT_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"

DETECT_PY="${SOURCE_DIR}/platform/web/detect.py"
DETECT_BACKUP=""
PACKAGE_DIR=""
cleanup() {
    status=$?
    if [ -n "$DETECT_BACKUP" ] && [ -f "$DETECT_BACKUP" ]; then
        cp "$DETECT_BACKUP" "$DETECT_PY"
        rm -f "$DETECT_BACKUP"
    fi
    if [ -n "$PACKAGE_DIR" ] && [ -d "$PACKAGE_DIR" ]; then
        rm -rf "$PACKAGE_DIR"
    fi
    exit "$status"
}
trap cleanup EXIT

DETECT_BACKUP="$(mktemp "${BUILD_ROOT}/detect.py.XXXXXX")"
cp "$DETECT_PY" "$DETECT_BACKUP"
if grep -q "SUPPORT_LONGJMP='emscripten'" "$DETECT_PY"; then
    EXPECTED_SOURCE_CHANGE=""
elif grep -q "SUPPORT_LONGJMP='wasm'" "$DETECT_PY"; then
    PATCHED_DETECT="$(mktemp "${BUILD_ROOT}/detect-patched.py.XXXXXX")"
    sed "s/SUPPORT_LONGJMP='wasm'/SUPPORT_LONGJMP='emscripten'/g" "$DETECT_PY" > "$PATCHED_DETECT"
    cp "$PATCHED_DETECT" "$DETECT_PY"
    rm -f "$PATCHED_DETECT"
    EXPECTED_SOURCE_CHANGE="platform/web/detect.py"
else
    echo "Godot source has an unknown SUPPORT_LONGJMP configuration" >&2
    exit 1
fi
if ! grep -q "SUPPORT_LONGJMP='emscripten'" "$DETECT_PY"; then
    echo "Unable to enforce Emscripten longjmp mode" >&2
    exit 1
fi
CHANGED_FILES="$(git -C "$SOURCE_DIR" diff --name-only)"
if [ "$CHANGED_FILES" != "$EXPECTED_SOURCE_CHANGE" ]; then
    echo "Unexpected tracked source changes after applying the build patch:" >&2
    printf '%s\n' "${CHANGED_FILES:-<none>}" >&2
    exit 1
fi

# javascript_eval=yes is mandatory. In Godot 4.7 the flag also gates
# `js/libs/library_godot_javascript_singleton.js` (GodotJSWrapper), so
# disabling it compiles JavaScriptBridge out entirely and
# `JavaScriptBridge.get_interface()` silently returns null. TikTok, which
# forbids eval, is handled at export time by exporter.gd, which rewrites
# `_godot_js_eval` into a disabled stub.
(
    cd "$SOURCE_DIR"
    scons platform=web target=template_release \
        arch=wasm32 \
        optimize=size \
        wasm_simd=no \
        threads=no \
        dlink_enabled=no \
        javascript_eval=yes \
        profile="$PROFILE_FILE" \
        -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
)

# Godot 4.7 splits the Web build into `<stem>.engine.js` (the Engine class),
# `<stem>.js` (the raw Emscripten module), and `<stem>.wrapped.js` (both
# concatenated). The wrapped file is what Godot installs as the Web template's
# `godot.js`, so it is the single template entry point we bundle.
shopt -s nullglob
JS_CANDIDATES=("${SOURCE_DIR}"/bin/godot.web.template_release.wasm32*.wrapped.js)
WASM_CANDIDATES=("${SOURCE_DIR}"/bin/godot.web.template_release.wasm32*.wasm)
shopt -u nullglob
if [ "${#JS_CANDIDATES[@]}" -ne 1 ] || [ "${#WASM_CANDIDATES[@]}" -ne 1 ]; then
    echo "Expected exactly one JavaScript artifact and one WASM artifact." >&2
    printf 'JavaScript candidates (%s):\n' "${#JS_CANDIDATES[@]}" >&2
    printf '  %s\n' "${JS_CANDIDATES[@]:-<none>}" >&2
    printf 'WASM candidates (%s):\n' "${#WASM_CANDIDATES[@]}" >&2
    printf '  %s\n' "${WASM_CANDIDATES[@]:-<none>}" >&2
    echo "Remove stale build outputs or use a clean GODOT_MINIGAME_BUILD_DIR." >&2
    exit 1
fi
JS_FILE="${JS_CANDIDATES[0]}"
WASM_FILE="${WASM_CANDIDATES[0]}"
if [ ! -s "$JS_FILE" ] || [ ! -s "$WASM_FILE" ]; then
    echo "Godot build did not produce non-empty JavaScript and WASM artifacts" >&2
    exit 1
fi
if [ "${JS_FILE%.wrapped.js}" != "${WASM_FILE%.wasm}" ]; then
    echo "JavaScript and WASM artifact stems do not match:" >&2
    echo "  $JS_FILE" >&2
    echo "  $WASM_FILE" >&2
    exit 1
fi

# Fail before packaging when a rebuilt engine no longer matches the exact
# strings exporter.gd rewrites in `_patch_godot_js()` (including the TikTok
# eval strip), instead of shipping a template that cannot be exported.
node "${SCRIPT_DIR}/locate_godot_js_anchors.mjs" "$JS_FILE"

if [ ! -s "${SOURCE_DIR}/COPYRIGHT.txt" ]; then
    echo "Godot source is missing COPYRIGHT.txt: ${SOURCE_DIR}/COPYRIGHT.txt" >&2
    exit 1
fi
PACKAGE_DIR="$(mktemp -d "${BUILD_ROOT}/template-package.XXXXXX")"
cp "$JS_FILE" "${PACKAGE_DIR}/godot.js"
cp "${SOURCE_DIR}/COPYRIGHT.txt" "${PACKAGE_DIR}/GODOT_COPYRIGHT.txt"
brotli --quality=11 --force --output="${PACKAGE_DIR}/godot.wasm.br" "$WASM_FILE"
printf '%s\n' "$CANONICAL_VERSION" > "${PACKAGE_DIR}/version.txt"

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

write_sha256() {
    file_path="$1"
    file_dir="$(dirname "$file_path")"
    file_name="$(basename "$file_path")"
    (
        cd "$file_dir"
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$file_name"
        else
            sha256sum "$file_name"
        fi
    ) > "${file_path}.sha256"
}

JS_SHA="$(sha256_file "${PACKAGE_DIR}/godot.js")"
WASM_SHA="$(sha256_file "${PACKAGE_DIR}/godot.wasm.br")"

jq -n \
    --arg version "$CANONICAL_VERSION" \
    --arg commit "$GODOT_COMMIT" \
    --arg emscripten "$EMSDK_VERSION" \
    --arg profile "$BUILD_PROFILE" \
    --arg js_sha "$JS_SHA" \
    --arg wasm_sha "$WASM_SHA" \
    --argjson schema "$TEMPLATE_SCHEMA" \
    --argjson revision "$TEMPLATE_REVISION" \
    --argjson bridge_abi "$BRIDGE_ABI" \
    '{
      schema: $schema,
      godot: {version: $version, commit: $commit},
      emscriptenVersion: $emscripten,
      profile: $profile,
      target: "release",
      revision: $revision,
      bridgeAbi: $bridge_abi,
      features: {
        simd: false,
        threads: false,
        wasmExceptions: false,
        javascriptEval: true
      },
      artifacts: {
        "godot.js": {sha256: $js_sha},
        "godot.wasm.br": {sha256: $wasm_sha}
      }
    }' > "${PACKAGE_DIR}/template.json"

# Normalize ZIP entry timestamps and keep the member order fixed so rebuilds
# of identical artifacts produce identical bundle bytes.
find "$PACKAGE_DIR" -type f -exec chmod 0644 {} +
find "$PACKAGE_DIR" -type f -exec touch -t 198001010000 {} +
PROFILE_TAG="${BUILD_PROFILE//_/-}"
BUNDLE_NAME="godot_minigame_template_${GODOT_TAG}_emsdk-${EMSDK_VERSION}_${PROFILE_TAG}_release_abi-${BRIDGE_ABI}_r${TEMPLATE_REVISION}.zip"
BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}"
rm -f "$BUNDLE_PATH" "${BUNDLE_PATH}.sha256"
(
    cd "$PACKAGE_DIR"
    zip -X -9 "$BUNDLE_PATH" godot.js godot.wasm.br version.txt template.json GODOT_COPYRIGHT.txt
)

write_sha256 "$BUNDLE_PATH"
"${SCRIPT_DIR}/verify_wasm_template.sh" "$BUNDLE_PATH" "$BUILD_PROFILE"
(
    cd "$OUTPUT_DIR"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c "${BUNDLE_NAME}.sha256"
    else
        sha256sum -c "${BUNDLE_NAME}.sha256"
    fi
)

echo "Validated template bundle: $BUNDLE_PATH"
echo "Godot source commit: $GODOT_COMMIT"
echo "Engine profile: $BUILD_PROFILE"
