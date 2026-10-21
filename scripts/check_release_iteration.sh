#!/usr/bin/env bash
set -euo pipefail

# Validate the release iteration encoded in <tag> against the tags that already
# exist on origin. Reads `git ls-remote --tags` output on stdin.
#
# Usage:
#   git ls-remote --refs --tags origin 'refs/tags/v4.7.2-stable.mod.*' \
#     | scripts/check_release_iteration.sh v4.7.2-stable.mod.2
#
# Rules (docs/SLIM_GODOT_ENGINE.md 3.1 and 3.2):
#   v<GodotTag>.mod.<N>                -> <N> must be highest_mod + 1
#   v<GodotTag>.mod.<N>-engine.<e>.<M> -> <N> must already exist, <M> must be the
#                                         next cut for that baseline (highest + 1)
#
# Everything is fail-closed: an unreadable listing, a tag namespace that holds
# no readable baseline, or an out-of-sequence iteration aborts the release.

if [ "$#" -ne 1 ]; then
    echo "Usage: scripts/check_release_iteration.sh <tag> < remote-tags.txt" >&2
    exit 1
fi

TAG="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TAG_FACTS="$("${SCRIPT_DIR}/validate_release_tag.sh" "$TAG")" || exit 1

GODOT_TAG=""
ITERATION=""
ENGINE_NAME=""
ENGINE_ITERATION=""
while IFS='=' read -r key value; do
    case "$key" in
        godot_tag) GODOT_TAG="$value" ;;
        iteration) ITERATION="$value" ;;
        engine_name) ENGINE_NAME="$value" ;;
        engine_iteration) ENGINE_ITERATION="$value" ;;
    esac
done <<<"$TAG_FACTS"

if [ -z "$GODOT_TAG" ] || [ -z "$ITERATION" ]; then
    echo "Unable to derive the release identity from $TAG." >&2
    exit 1
fi

# Dots and plus signs in a Godot tag are literal, not regex metacharacters.
GODOT_TAG_RE="${GODOT_TAG//./\\.}"
GODOT_TAG_RE="${GODOT_TAG_RE//+/\\+}"

base_mod_tag="v${GODOT_TAG}.mod.${ITERATION}"
base_mod_exists=false
highest_mod_iteration=0
highest_engine_iteration=0
saw_tag=false

while read -r _ref name; do
    [ -n "${name:-}" ] || continue
    # `git ls-remote` prints full refnames, and peeled entries unless --refs is
    # used. Both forms must be understood.
    name="${name#refs/tags/}"
    name="${name%^\{\}}"
    saw_tag=true

    if [ "$name" = "$base_mod_tag" ]; then
        base_mod_exists=true
    fi

    if [[ "$name" =~ ^v${GODOT_TAG_RE}\.mod\.([0-9]+)$ ]]; then
        candidate="${BASH_REMATCH[1]}"
        if [ "$candidate" -gt "$highest_mod_iteration" ]; then
            highest_mod_iteration="$candidate"
        fi
        continue
    fi

    if [ -n "$ENGINE_NAME" ] \
        && [[ "$name" =~ ^v${GODOT_TAG_RE}\.mod\.${ITERATION}-engine\.${ENGINE_NAME}\.([0-9]+)$ ]]; then
        candidate="${BASH_REMATCH[1]}"
        if [ "$candidate" -gt "$highest_engine_iteration" ]; then
            highest_engine_iteration="$candidate"
        fi
    fi
done

if [ -n "$ENGINE_NAME" ]; then
    # An engine release is a new cut on an already published mod tag, so `<N>`
    # names that existing tag instead of the next mod iteration. Only `<M>` has
    # to be the next cut for this baseline (docs/SLIM_GODOT_ENGINE.md 3.2).
    if [ "$base_mod_exists" != true ]; then
        echo "Base mod tag ${base_mod_tag} does not exist on origin." >&2
        echo "An engine release must build on an already published mod tag." >&2
        exit 1
    fi
    expected_engine_iteration=$((highest_engine_iteration + 1))
    if [ "$ENGINE_ITERATION" != "$expected_engine_iteration" ]; then
        echo "Engine iteration mismatch for ${ENGINE_NAME}:" >&2
        echo "  tag:      $TAG" >&2
        echo "  expected: -engine.${ENGINE_NAME}.${expected_engine_iteration}" >&2
        echo "  existing: -engine.${ENGINE_NAME}.${highest_engine_iteration}" >&2
        echo "The engine iteration increments on every cut and resets on a new mod baseline." >&2
        exit 1
    fi
else
    # The listing is filtered to this Godot tag, so a non-empty listing with no
    # readable baseline means the parser no longer understands the namespace.
    # Refuse to publish rather than silently treating it as the first release.
    if [ "$saw_tag" = true ] && [ "$highest_mod_iteration" -eq 0 ]; then
        echo "Refusing to publish: tags matching v${GODOT_TAG}.mod.* exist," >&2
        echo "but none of them is a readable mod baseline." >&2
        exit 1
    fi
    expected_iteration=$((highest_mod_iteration + 1))
    if [ "$ITERATION" != "$expected_iteration" ]; then
        echo "Iteration mismatch for Godot ${GODOT_TAG}:" >&2
        echo "  tag:      $TAG" >&2
        echo "  expected: mod.${expected_iteration}" >&2
        echo "  existing: mod.${highest_mod_iteration}" >&2
        echo "The mod iteration increments on every release and resets on a Godot upgrade." >&2
        exit 1
    fi
fi

echo "iteration_ok"
