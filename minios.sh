#!/usr/bin/env bash
# MiniOS kernel: boot the virtual disk, run the command loop, save on exit.

MINIOS_VERSION=1.0.0

if [[ -z ${BASH_VERSION:-} ]]; then
    printf 'MiniOS requires bash.\n' >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
export MINIOS_DISK=${MINIOS_DISK:-"$SCRIPT_DIR/minios.disk"}
DISK_FILE=$MINIOS_DISK

MINIOS_USER=user
MINIOS_HOST=minios
MINIOS_TMPOUT="${TMPDIR:-/tmp}/minios-out.$$"
HISTFILE=

if [[ -t 1 ]]; then COLOR=1; else COLOR=0; fi

source "$SCRIPT_DIR/lib/disk.sh" || exit 1
source "$SCRIPT_DIR/lib/vfs.sh" || exit 1
source "$SCRIPT_DIR/lib/commands.sh" || exit 1

if ! disk_load; then
    printf 'minios: unable to load virtual disk (%s)\n' "$DISK_FILE" >&2
    exit 1
fi

trap 'rm -f "$MINIOS_TMPOUT"' EXIT
trap 'printf "\n"; exit 0' INT TERM

CWD=/home/user
REBOOT=0

prompt_string() {
    local d=$CWD
    case $d in
        /home/user)   d='~' ;;
        /home/user/*) d="~${d#/home/user}" ;;
    esac
    if (( COLOR )); then
        printf '\033[1;32m%s@%s\033[0m:\033[1;34m%s\033[0m$ ' \
            "$MINIOS_USER" "$MINIOS_HOST" "$d"
    else
        printf '%s@%s:%s$ ' "$MINIOS_USER" "$MINIOS_HOST" "$d"
    fi
}

# Split a command line into TOKENS, honouring single quotes, double quotes
# and backslash escapes. Sets TOK_ERR on an unterminated quote.
tokenize() {
    local s=$1 i=0 n=${#1} ch
    local cur='' q='' started=0 escaped=0
    TOKENS=()
    TOK_ERR=0

    while (( i < n )); do
        ch=${s:i:1}
        if (( escaped )); then
            cur+=$ch
            started=1
            escaped=0
            i=$(( i + 1 ))
            continue
        fi
        if [[ $ch == '\' ]]; then
            if [[ -z $q || $q == '"' ]]; then
                escaped=1
            else
                cur+='\'
            fi
            started=1
            i=$(( i + 1 ))
            continue
        fi
        if [[ -z $q ]]; then
            case $ch in
                "'") q="'" ; started=1 ;;
                '"') q='"' ; started=1 ;;
                ' '|$'\t')
                    if (( started )); then
                        TOKENS+=("$cur")
                        cur=''
                        started=0
                    fi
                    ;;
                *) cur+=$ch; started=1 ;;
            esac
        elif [[ $q == "'" ]]; then
            if [[ $ch == "'" ]]; then q=''; else cur+=$ch; fi
        else
            if [[ $ch == '"' ]]; then q=''; else cur+=$ch; fi
        fi
        i=$(( i + 1 ))
    done

    if [[ -n $q || $escaped -eq 1 ]]; then
        TOK_ERR=1
        return 1
    fi
    (( started )) && TOKENS+=("$cur")
    return 0
}

# Remove > and >> from TOKENS and set REDIR_FILE / REDIR_APPEND.
parse_redirection() {
    REDIR_FILE=''
    REDIR_APPEND=0
    REDIR_ERR=0
    local out=() i t
    for (( i = 0; i < ${#TOKENS[@]}; i++ )); do
        t=${TOKENS[i]}
        if [[ $t == '>>' || $t == '>>'* ]]; then
            REDIR_APPEND=1
            if [[ ${#t} -gt 2 ]]; then
                REDIR_FILE=${t:2}
            elif (( i + 1 < ${#TOKENS[@]} )); then
                i=$(( i + 1 ))
                REDIR_FILE=${TOKENS[i]}
            else
                REDIR_ERR=1
            fi
        elif [[ $t == '>' || $t == '>'* ]]; then
            if [[ ${#t} -gt 1 ]]; then
                REDIR_FILE=${t:1}
            elif (( i + 1 < ${#TOKENS[@]} )); then
                i=$(( i + 1 ))
                REDIR_FILE=${TOKENS[i]}
            else
                REDIR_ERR=1
            fi
        else
            out+=("$t")
        fi
    done
    TOKENS=("${out[@]}")
    if [[ -n $REDIR_FILE ]]; then
        resolve_path "$REDIR_FILE" "$CWD"
        REDIR_FILE=$RESOLVED_PATH
    fi
    return 0
}

handle_line() {
    local input=$1
    # Trim surrounding whitespace without external tools.
    input=${input#"${input%%[![:space:]]*}"}
    input=${input%"${input##*[![:space:]]}"}
    [[ -z $input || ${input:0:1} == '#' ]] && return 0

    if ! tokenize "$input"; then
        printf 'minios: syntax error: unterminated quote\n'
        return 1
    fi
    (( ${#TOKENS[@]} == 0 )) && return 0

    parse_redirection
    if (( REDIR_ERR )); then
        printf 'minios: syntax error: expected a file after redirection\n'
        return 1
    fi

    local cmd=${TOKENS[0]}
    TOKENS=("${TOKENS[@]:1}")

    # Run in THIS shell so filesystem mutations persist. Output is captured
    # through a file rather than $(...) for the same reason.
    : > "$MINIOS_TMPOUT"
    cmd_dispatch "$cmd" "${TOKENS[@]}" > "$MINIOS_TMPOUT" 2>&1
    local status=$?

    local out=''
    IFS= read -r -d '' out < "$MINIOS_TMPOUT" || true

    if [[ -n $REDIR_FILE ]]; then
        if ! vfs_write_file "$REDIR_FILE" "$out" "$REDIR_APPEND"; then
            printf 'minios: cannot write to %s\n' "$REDIR_FILE"
            status=1
        fi
    elif [[ -n $out ]]; then
        printf '%s' "$out"
    fi

    (( DISK_DIRTY )) && disk_save
    return $status
}

cmd_banner
printf 'Persistent storage: %s\n' "$DISK_FILE"
printf "Type 'help' for commands, 'exit' to shut down.\n\n"

while :; do
    if [[ -t 0 ]]; then
        if ! IFS= read -e -r -p "$(prompt_string)" LINE; then
            printf '\n'
            break
        fi
    else
        if ! IFS= read -r LINE; then
            break
        fi
    fi

    [[ -n $LINE ]] && history -s "$LINE" 2>/dev/null || true

    handle_line "$LINE"
    rc=$?
    case $rc in
        2)  break ;;
        75) REBOOT=1; break ;;
    esac
done

disk_sync
rm -f "$MINIOS_TMPOUT"
trap - EXIT

if (( REBOOT )); then
    exec bash "$SCRIPT_DIR/minios.sh"
fi
exit 0
