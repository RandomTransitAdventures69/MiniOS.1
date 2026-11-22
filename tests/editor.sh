#!/usr/bin/env bash
# Run the nana editor test if expect is available.

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

if ! command -v expect >/dev/null 2>&1; then
    printf 'skip: editor test needs expect (install it and rerun)\n'
    exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/minios-editor-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

expect "$ROOT/tests/editor.exp" "$ROOT" "$TMP/disk"
