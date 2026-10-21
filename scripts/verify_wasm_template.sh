#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: scripts/verify_wasm_template.sh <template.zip|template-directory>" >&2
    exit 1
fi

for command_name in brotli jq node unzip wasm-validate xxd; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required validation command: $command_name" >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SUPPORT_MATRIX="${PROJECT_DIR}/support-matrix.json"
if [ ! -s "$SUPPORT_MATRIX" ]; then
    echo "Missing support matrix: $SUPPORT_MATRIX" >&2
    exit 1
fi
EXPECTED_BRIDGE_ABI="$(jq -er '.bridgeAbi | select(type == "number" and . > 0 and (. % 1 == 0))' "$SUPPORT_MATRIX")"
EXPECTED_TEMPLATE_SCHEMA="$(jq -er '.templateSchema | select(type == "number" and . > 0 and (. % 1 == 0))' "$SUPPORT_MATRIX")"

INPUT_PATH="$1"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

if [ -d "$INPUT_PATH" ]; then
    PACKAGE_DIR="$INPUT_PATH"
else
    unzip -q "$INPUT_PATH" -d "$TEMP_DIR/package"
    PACKAGE_DIR="$TEMP_DIR/package"
fi

if [ -n "$(find "$PACKAGE_DIR" -type l -print -quit)" ]; then
    echo "Template bundle must not contain symbolic links" >&2
    exit 1
fi
EXPECTED_FILES="$(printf '%s\n' \
    GODOT_COPYRIGHT.txt godot.js godot.wasm.br template.json version.txt | LC_ALL=C sort)"
ACTUAL_FILES="$(
    cd "$PACKAGE_DIR"
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort
)"
if [ "$ACTUAL_FILES" != "$EXPECTED_FILES" ]; then
    echo "Template bundle must contain exactly the five contract files" >&2
    echo "Expected:" >&2
    printf '%s\n' "$EXPECTED_FILES" >&2
    echo "Actual:" >&2
    printf '%s\n' "${ACTUAL_FILES:-<none>}" >&2
    exit 1
fi

for required in template.json version.txt godot.js godot.wasm.br GODOT_COPYRIGHT.txt; do
    if [ ! -s "${PACKAGE_DIR}/${required}" ]; then
        echo "Template bundle is missing or has an empty $required" >&2
        exit 1
    fi
done

if ! jq -e \
    --argjson expected_schema "$EXPECTED_TEMPLATE_SCHEMA" \
    --argjson expected_bridge_abi "$EXPECTED_BRIDGE_ABI" \
    '
      (.schema == $expected_schema) and
      (.godot.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9A-Za-z]+$")) and
      (.godot.commit | type == "string" and test("^[0-9a-fA-F]{40}$")) and
      (.emscriptenVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$")) and
      (.revision | type == "number" and . > 0 and (. % 1 == 0)) and
      (.bridgeAbi == $expected_bridge_abi) and
      (.profile == "2d_full") and
      (.target == "release") and
      (.features.simd == false) and
      (.features.threads == false) and
      (.features.wasmExceptions == false) and
      (.features.javascriptEval == true) and
      (.artifacts["godot.js"].sha256 | type == "string" and test("^[0-9a-fA-F]{64}$")) and
      (.artifacts["godot.wasm.br"].sha256 | type == "string" and test("^[0-9a-fA-F]{64}$"))
    ' "${PACKAGE_DIR}/template.json" >/dev/null; then
    echo "::error::template.json failed the manifest contract" >&2
    jq . "${PACKAGE_DIR}/template.json" >&2 || true
    exit 1
fi

MANIFEST_VERSION="$(jq -r '.godot.version' "${PACKAGE_DIR}/template.json")"
FILE_VERSION="$(
    tr '-' '.' < "${PACKAGE_DIR}/version.txt" \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
)"
if [ "$MANIFEST_VERSION" != "$FILE_VERSION" ]; then
    echo "template.json and version.txt disagree" >&2
    exit 1
fi

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

for artifact in godot.js godot.wasm.br; do
    expected="$(jq -r --arg artifact "$artifact" '.artifacts[$artifact].sha256' "${PACKAGE_DIR}/template.json")"
    actual="$(sha256_file "${PACKAGE_DIR}/${artifact}")"
    if [ "$expected" != "$actual" ]; then
        echo "Checksum mismatch for $artifact" >&2
        exit 1
    fi
done

if ! node --check "${PACKAGE_DIR}/godot.js" 2>"${TEMP_DIR}/node-check.log"; then
    echo "::error::godot.js failed node --check: $(tr '\n' ' ' < "${TEMP_DIR}/node-check.log" | head -c 500)" >&2
    exit 1
fi

# The engine MUST carry the JavaScriptBridge implementation. In Godot 4.7 a
# build made with `javascript_eval=no` silently drops
# `js/libs/library_godot_javascript_singleton.js`, so `GodotJSWrapper` and the
# `godot_js_wrapper_*` helpers disappear and `JavaScriptBridge.get_interface()`
# can never find a registered interface.
if ! grep -q "GodotJSWrapper" "${PACKAGE_DIR}/godot.js"; then
    echo "::error::godot.js is missing GodotJSWrapper; rebuild the template with javascript_eval=yes" >&2
    exit 1
fi
# Check the JS side. With optimize=size Emscripten may minify wasm import names,
# so the stable proof that the bridge is linked lives in godot.js, not wasm.
if ! grep -q "godot_js_wrapper_interface_get" "${PACKAGE_DIR}/godot.js"; then
    echo "::error::godot.js has no godot_js_wrapper_interface_get; JavaScriptBridge is not linked" >&2
    exit 1
fi
# The eval implementation is injected by Emscripten only when the engine carries
# eval( at all, and its definition syntax varies between Emscripten releases.
# Anchor on the stable symbol name instead of the definition form.
if grep -q "eval(" "${PACKAGE_DIR}/godot.js" \
    && ! grep -q "_godot_js_eval" "${PACKAGE_DIR}/godot.js"; then
    echo "::error::godot.js contains eval( but no _godot_js_eval implementation; the TikTok eval strip cannot run" >&2
    exit 1
fi

brotli --decompress --force --output="${TEMP_DIR}/godot.wasm" "${PACKAGE_DIR}/godot.wasm.br"
if [ "$(xxd -p -l 4 "${TEMP_DIR}/godot.wasm")" != "0061736d" ]; then
    echo "::error::decompressed artifact is not a WebAssembly module" >&2
    exit 1
fi
# WABT disables threads and exception handling by default. Explicitly disable
# SIMD so the complete mini-game feature contract is enforced.
if ! wasm-validate --disable-simd "${TEMP_DIR}/godot.wasm" 2>"${TEMP_DIR}/wasm-validate.log"; then
    echo "::error::wasm-validate rejected godot.wasm: $(tr '\n' ' ' < "${TEMP_DIR}/wasm-validate.log" | head -c 500)" >&2
    exit 1
fi

echo "Template bundle is valid: Godot $MANIFEST_VERSION, bridge ABI $EXPECTED_BRIDGE_ABI"
