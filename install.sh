#!/usr/bin/env bash
# MiniOS installer: make every project file executable.
# Usage: ./install.sh   (or, if the bit was lost: bash install.sh)

ROOT=$(cd "$(dirname "$0")" && pwd -P) || {
    printf 'install: cannot locate the install directory\n' >&2
    exit 1
}

if [[ ! -f "$ROOT/run.sh" || ! -f "$ROOT/minios.sh" ]]; then
    printf 'install: run.sh/minios.sh not found in %s\n' "$ROOT" >&2
    exit 1
fi

# Everything in the project tree except Git metadata gets the execute bit.
# -exec ... + keeps this fast and handles spaces in path names safely.
if ! find "$ROOT" -path "$ROOT/.git" -prune -o -type f -exec chmod +x {} +; then
    printf 'install: failed to set executable permissions\n' >&2
    exit 1
fi

FAILED=0
for f in install.sh run.sh minios.sh lib/disk.sh lib/vfs.sh lib/commands.sh tests/smoke.sh; do
    if [[ ! -x "$ROOT/$f" ]]; then
        printf 'install: %s is not executable\n' "$f" >&2
        FAILED=1
    fi
done
(( FAILED )) && exit 1

COUNT=$(find "$ROOT" -path "$ROOT/.git" -prune -o -type f -print | wc -l | tr -d ' ')
printf 'MiniOS installed: %s files are now executable.\n' "$COUNT"
printf 'Start it with: cd %s && ./run.sh\n' "$ROOT"
exit 0
