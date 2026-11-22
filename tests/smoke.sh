#!/usr/bin/env bash
# Automated smoke test for MiniOS. Uses an isolated virtual disk.

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minios-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

DISK=$TMP/disk
OUT=$TMP/output
FAIL=0

check() {
    if grep -Fq -- "$2" "$OUT"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s (missing: %s)\n' "$1" "$2"
        FAIL=1
    fi
}

check_absent() {
    if grep -Fq -- "$2" "$OUT"; then
        printf 'FAIL %s (unexpected: %s)\n' "$1" "$2"
        FAIL=1
    else
        printf 'ok   %s\n' "$1"
    fi
}

cat > "$TMP/commands1" <<'COMMANDS'
write /home/user/t.txt "alpha beta"
cat /home/user/t.txt
append /home/user/t.txt " gamma"
cat /home/user/t.txt
echo "one" > /home/user/r.txt
echo "two" >> /home/user/r.txt
cat /home/user/r.txt
mkdir -p /a/b/c
touch /a/b/c/f
ls /a/b
tree /a
mv /a/b/c/f /a/b/g
cp /a/b/g /a/h
rm -r /a/b
ls /a
cd /a
pwd
cd ../..
pwd
write /home/user/esc.txt "a|b\\c'd\"e"
cat /home/user/esc.txt
stat /home/user/t.txt
df
save
exit
COMMANDS

MINIOS_DISK="$DISK" bash "$ROOT/run.sh" < "$TMP/commands1" > "$OUT" 2>&1

check 'banner boots'                ' ___  ___'
check 'write stores text'           'alpha beta'
check 'append adds text'            'alpha beta gamma'
check 'redirection writes file'     'one'
check 'redirection appends file'    'two'
check 'mkdir -p creates tree'       '-- c'
check 'tree lists nested file'      '-- f'
check 'mv renames file'             'g'
check 'rm -r removes directory'     'h'
check 'cd .. normalizes path'       '/home/user'
check 'escapes survive disk'        'a|b\c'"'"'d"e'
check 'stat reports file type'      'Type:   file'
check 'df reports usage'            'MiniOS virtual disk:'
check_absent 'no runtime errors'    'minios: '

# A separate process must see the same files (real persistence).
cat > "$TMP/commands2" <<'COMMANDS'
cat /home/user/esc.txt
cat /home/user/r.txt
ls /a
cat /home/user/t.txt
exit
COMMANDS

MINIOS_DISK="$DISK" bash "$ROOT/run.sh" < "$TMP/commands2" > "$OUT" 2>&1

check 'persisted escaped content'   'a|b\c'"'"'d"e'
check 'persisted appended file'     'one'
check 'persisted second line'       'two'
check 'persisted directory /a'      'h'
check 'persisted write file'        'alpha beta gamma'
check_absent 'clean reboot of disk' 'minios: '

if (( FAIL )); then
    printf '\nSMOKE TEST FAILED\n'
    exit 1
fi
printf '\nAll smoke tests passed.\n'
