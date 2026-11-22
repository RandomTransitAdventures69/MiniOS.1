#!/usr/bin/env bash
# MiniOS launcher: ./run.sh

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)

if [[ ! -f "$SCRIPT_DIR/minios.sh" ]]; then
    printf 'run.sh: minios.sh not found in %s\n' "$SCRIPT_DIR" >&2
    exit 1
fi

# Fail early with a useful hint if the kernel was edited into a broken state.
if ! bash -n "$SCRIPT_DIR/minios.sh" 2>/dev/null; then
    printf 'run.sh: minios.sh has a syntax error; restore it with: git checkout -- minios.sh\n' >&2
    exit 1
fi

exec bash "$SCRIPT_DIR/minios.sh" "$@"
