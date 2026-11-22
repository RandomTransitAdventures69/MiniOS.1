# MiniOS nana: a small full-screen text editor.
#
# It is deliberately built from bash builtins so it works with bash 3.2.
# The editor owns the terminal while it runs and restores the previous
# terminal settings and signal handlers when it exits.

NANA_UNDO_LIMIT=100

nana_restore_terminal() {
    [[ -n ${NANA_SAVED_STTY:-} ]] && stty "$NANA_SAVED_STTY" 2>/dev/null
    printf '\033[0m\033[?25h\033[H\033[J'
}

nana_restore_traps() {
    if [[ -n ${NANA_OLD_EXIT:-} ]]; then eval "$NANA_OLD_EXIT"; else trap - EXIT; fi
    if [[ -n ${NANA_OLD_INT:-} ]]; then eval "$NANA_OLD_INT"; else trap - INT; fi
    if [[ -n ${NANA_OLD_TERM:-} ]]; then eval "$NANA_OLD_TERM"; else trap - TERM; fi
}

# Split file content into NANA_LINES, preserving empty lines but treating a
# single trailing newline as a line terminator (not an extra blank line).
nana_load_file() {
    local content=''
    if vfs_find "$NANA_FILE" && [[ ${VFS_TYPE[VFS_IDX]} == f ]]; then
        content=${VFS_CONTENT[VFS_IDX]}
    fi

    NANA_LINES=()
    local rest=$content
    while [[ $rest == *$'\n'* ]]; do
        NANA_LINES+=("${rest%%$'\n'*}")
        rest=${rest#*$'\n'}
    done
    NANA_LINES+=("$rest")

    local n=${#NANA_LINES[@]}
    if [[ $content == *$'\n' && $n -gt 1 && -z ${NANA_LINES[n-1]} ]]; then
        unset "NANA_LINES[$(( n - 1 ))]"
    fi
    return 0
}

nana_save_file() {
    local content='' i n=${#NANA_LINES[@]}
    for (( i = 0; i < n; i++ )); do
        content+="${NANA_LINES[i]}"
        (( i < n - 1 )) && content+=$'\n'
    done
    content+=$'\n'

    if vfs_write_file "$NANA_FILE" "$content" 0; then
        NANA_DIRTY=0
        NANA_MSG='saved'
        return 0
    fi
    NANA_MSG='save failed'
    return 1
}

# --- undo / redo -----------------------------------------------------------

nana_serialize() {
    local s="$NANA_Y:$NANA_X:" i n=${#NANA_LINES[@]}
    for (( i = 0; i < n; i++ )); do
        str_escape "${NANA_LINES[i]}"
        s+=$ESC_RESULT
        (( i < n - 1 )) && s+=$'\t'
    done
    printf '%s' "$s"
}

nana_apply_snapshot() {
    local s=$1
    if [[ $s =~ ^([0-9]+):([0-9]+):(.*)$ ]]; then
        NANA_Y=${BASH_REMATCH[1]}
        NANA_X=${BASH_REMATCH[2]}
        s=${BASH_REMATCH[3]}
    fi
    NANA_LINES=()
    local part
    while [[ $s == *$'\t'* ]]; do
        part=${s%%$'\t'*}
        str_unescape "$part"
        NANA_LINES+=("$UNESC_RESULT")
        s=${s#*$'\t'}
    done
    str_unescape "$s"
    NANA_LINES+=("$UNESC_RESULT")
    nana_scroll
    return 0
}

nana_push_undo() {
    local snap=$(nana_serialize)
    if (( NANA_UNDO_P < ${#NANA_UNDO[@]} )); then
        NANA_UNDO=("${NANA_UNDO[@]:0:$NANA_UNDO_P}")
    fi
    NANA_UNDO+=("$snap")
    NANA_UNDO_P=${#NANA_UNDO[@]}
    NANA_REDO=()
    if (( NANA_UNDO_P > NANA_UNDO_LIMIT )); then
        NANA_UNDO=("${NANA_UNDO[@]:1}")
        NANA_UNDO_P=$NANA_UNDO_LIMIT
    fi
    return 0
}

nana_undo() {
    (( NANA_UNDO_P > 0 )) || { NANA_MSG='nothing to undo'; return 0; }
    NANA_REDO+=("$(nana_serialize)")
    NANA_UNDO_P=$(( NANA_UNDO_P - 1 ))
    nana_apply_snapshot "${NANA_UNDO[NANA_UNDO_P]}"
    NANA_DIRTY=1
    NANA_MSG='undo'
    return 0
}

nana_redo() {
    (( ${#NANA_REDO[@]} > 0 )) || { NANA_MSG='nothing to redo'; return 0; }
    local i=$((${#NANA_REDO[@]} - 1))
    local snap=${NANA_REDO[i]}
    unset "NANA_REDO[$i]"
    NANA_UNDO+=("$(nana_serialize)")
    NANA_UNDO_P=${#NANA_UNDO[@]}
    nana_apply_snapshot "$snap"
    NANA_DIRTY=1
    NANA_MSG='redo'
    return 0
}

# --- cursor and editing ----------------------------------------------------

nana_scroll() {
    local visible=$(( NANA_ROWS - 3 ))
    (( visible < 3 )) && visible=3
    (( NANA_TOP < 0 )) && NANA_TOP=0
    (( NANA_Y < NANA_TOP )) && NANA_TOP=$NANA_Y
    if (( NANA_Y >= NANA_TOP + visible )); then
        NANA_TOP=$(( NANA_Y - visible + 1 ))
    fi
    return 0
}

nana_clamp_x() {
    local len=${#NANA_LINES[NANA_Y]}
    (( NANA_X > len )) && NANA_X=$len
    (( NANA_X < 0 )) && NANA_X=0
    return 0
}

nana_move_up() {
    (( NANA_Y > 0 )) && NANA_Y=$(( NANA_Y - 1 ))
    nana_clamp_x
    nana_scroll
}

nana_move_down() {
    (( NANA_Y < ${#NANA_LINES[@]} - 1 )) && NANA_Y=$(( NANA_Y + 1 ))
    nana_clamp_x
    nana_scroll
}

nana_move_left() {
    (( NANA_X > 0 )) && NANA_X=$(( NANA_X - 1 ))
}

nana_move_right() {
    (( NANA_X < ${#NANA_LINES[NANA_Y]} )) && NANA_X=$(( NANA_X + 1 ))
}

nana_page_up() {
    local page=$(( NANA_ROWS - 3 ))
    (( page < 1 )) && page=1
    NANA_Y=$(( NANA_Y - page ))
    (( NANA_Y < 0 )) && NANA_Y=0
    nana_clamp_x
    nana_scroll
}

nana_page_down() {
    local page=$(( NANA_ROWS - 3 ))
    (( page < 1 )) && page=1
    NANA_Y=$(( NANA_Y + page ))
    (( NANA_Y > ${#NANA_LINES[@]} - 1 )) && NANA_Y=$((${#NANA_LINES[@]} - 1))
    nana_clamp_x
    nana_scroll
}

nana_insert_text() {
    local text=$1 line=${NANA_LINES[NANA_Y]}
    nana_push_undo
    NANA_LINES[NANA_Y]="${line:0:$NANA_X}$text${line:$NANA_X}"
    NANA_X=$(( NANA_X + ${#text} ))
    NANA_DIRTY=1
    return 0
}

nana_newline() {
    local line=${NANA_LINES[NANA_Y]}
    nana_push_undo
    local before=${line:0:$NANA_X} after=${line:$NANA_X}
    local n=${#NANA_LINES[@]} i
    for (( i = n; i > NANA_Y + 1; i-- )); do
        NANA_LINES[i]=${NANA_LINES[i-1]}
    done
    NANA_LINES[NANA_Y]=$before
    NANA_LINES[$(( NANA_Y + 1 ))]=$after
    NANA_Y=$(( NANA_Y + 1 ))
    NANA_X=0
    NANA_DIRTY=1
    nana_scroll
    return 0
}

nana_backspace() {
    local line=${NANA_LINES[NANA_Y]}
    if (( NANA_X > 0 )); then
        nana_push_undo
        NANA_LINES[NANA_Y]="${line:0:$(( NANA_X - 1 ))}${line:$NANA_X}"
        NANA_X=$(( NANA_X - 1 ))
        NANA_DIRTY=1
        return 0
    fi
    (( NANA_Y > 0 )) || return 0

    nana_push_undo
    local prev=${NANA_LINES[NANA_Y-1]}
    local px=${#prev}
    local n=${#NANA_LINES[@]} i
    NANA_LINES[NANA_Y-1]="$prev$line"
    for (( i = NANA_Y; i < n - 1; i++ )); do
        NANA_LINES[i]=${NANA_LINES[i+1]}
    done
    unset "NANA_LINES[$(( n - 1 ))]"
    NANA_Y=$(( NANA_Y - 1 ))
    NANA_X=$px
    NANA_DIRTY=1
    nana_scroll
    return 0
}

nana_delete_char() {
    local line=${NANA_LINES[NANA_Y]}
    if (( NANA_X < ${#line} )); then
        nana_push_undo
        NANA_LINES[NANA_Y]="${line:0:$NANA_X}${line:$(( NANA_X + 1 ))}"
        NANA_DIRTY=1
        return 0
    fi
    (( NANA_Y < ${#NANA_LINES[@]} - 1 )) || return 0

    nana_push_undo
    local n=${#NANA_LINES[@]} i
    NANA_LINES[NANA_Y]="$line${NANA_LINES[NANA_Y+1]}"
    for (( i = NANA_Y + 1; i < n - 1; i++ )); do
        NANA_LINES[i]=${NANA_LINES[i+1]}
    done
    unset "NANA_LINES[$(( n - 1 ))]"
    NANA_DIRTY=1
    return 0
}

nana_cut_to_eol() {
    local line=${NANA_LINES[NANA_Y]}
    [[ -z ${line:$NANA_X} ]] && return 0
    nana_push_undo
    NANA_KILL=${line:$NANA_X}
    NANA_LINES[NANA_Y]=${line:0:$NANA_X}
    NANA_DIRTY=1
    return 0
}

nana_paste() {
    [[ -z $NANA_KILL ]] && { NANA_MSG='nothing to paste'; return 0; }
    nana_insert_text "$NANA_KILL"
    return 0
}

nana_index_of() {
    local hay=$1 needle=$2 h=${#hay} n=${#needle} i
    (( n == 0 )) && { printf '0'; return 0; }
    for (( i = 0; i <= h - n; i++ )); do
        if [[ ${hay:i:n} == "$needle" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    printf '0'
    return 1
}

nana_find() {
    nana_prompt 'Find: '
    local q=$NANA_PROMPT_RESULT
    [[ -z $q ]] && return 0

    local n=${#NANA_LINES[@]} i line startcol off
    for (( i = NANA_Y; i < n; i++ )); do
        line=${NANA_LINES[i]}
        if (( i == NANA_Y )); then startcol=$(( NANA_X + 1 )); else startcol=0; fi
        (( startcol > ${#line} )) && continue
        off=$(nana_index_of "${line:$startcol}" "$q")
        NANA_Y=$i
        NANA_X=$(( startcol + off ))
        nana_scroll
        NANA_MSG="found: $q"
        return 0
    done

    # Wrap around to the top of the buffer.
    for (( i = 0; i < NANA_Y; i++ )); do
        line=${NANA_LINES[i]}
        off=$(nana_index_of "$line" "$q")
        NANA_Y=$i
        NANA_X=$off
        nana_scroll
        NANA_MSG="found: $q"
        return 0
    done
    NANA_MSG='not found'
    return 0
}

# --- screen ---------------------------------------------------------------

nana_render() {
    local visible=$(( NANA_ROWS - 3 ))
    (( visible < 3 )) && visible=3
    local maxlen=$(( NANA_COLS - 6 ))
    (( maxlen < 10 )) && maxlen=10

    printf '\033[H\033[J'
    local flag=''
    (( NANA_DIRTY )) && flag=' *modified*'
    printf '\033[7m%-*s\033[0m\n' "$NANA_COLS" " nana - $NANA_FILE$flag"

    local i idx line start
    for (( i = 0; i < visible; i++ )); do
        idx=$(( NANA_TOP + i ))
        if (( idx < ${#NANA_LINES[@]} )); then
            line=${NANA_LINES[idx]}
            start=0
            if (( idx == NANA_Y && NANA_X >= maxlen )); then
                start=$(( NANA_X - maxlen + 1 ))
            fi
            if (( ${#line} > start + maxlen )); then
                line=${line:start:maxlen}
            else
                line=${line:start}
            fi
            if (( idx == NANA_Y )); then
                printf '\033[7m%4d %s\033[0m\n' "$(( idx + 1 ))" "$line"
            else
                printf '%4d %s\n' "$(( idx + 1 ))" "$line"
            fi
        else
            printf '     ~\n'
        fi
    done

    local status=" Ln $(( NANA_Y + 1 ))/${#NANA_LINES[@]}  Col $(( NANA_X + 1 ))"
    [[ -n $NANA_MSG ]] && status="$status  | $NANA_MSG"
    printf '\033[7m%-*s\033[0m\n' "$NANA_COLS" "$status"
    printf '%.*s\n' "$NANA_COLS" \
        ' ^S Save  ^X Exit  ^Z Undo  ^Y Redo  ^W Find  ^K Cut  ^V Paste  ^G Help  Arrows Move'

    start=0
    if (( NANA_X >= maxlen )); then start=$(( NANA_X - maxlen + 1 )); fi
    printf '\033[%d;%dH' "$(( 2 + NANA_Y - NANA_TOP ))" "$(( 6 + NANA_X - start ))"
    return 0
}

nana_help_screen() {
    printf '\033[H\033[J'
    cat <<'HELP'
  nana - MiniOS text editor
  ------------------------------------------------------------
  Arrows / ^P ^N ^B ^F   move the cursor
  Home / End / ^A / ^E   start / end of line
  PgUp / PgDn             move one screen
  Enter                   split line
  Backspace / Delete      delete backwards / forwards
  ^S                      save
  ^X                      exit (asks before discarding changes)
  ^Z / ^Y                 undo / redo
  ^K / ^V                 cut to end of line / paste
  ^W                      find (wraps around)
  ^G                      this help
  ------------------------------------------------------------
HELP
    printf 'Press any key to return...'
    nana_get_key
    return 0
}

nana_prompt() {
    stty "$NANA_SAVED_STTY" 2>/dev/null
    printf '\033[%d;1H\033[K%s' "$(( NANA_ROWS - 1 ))" "$1"
    IFS= read -r NANA_PROMPT_RESULT
    stty -echo -icanon -isig -ixon -ixoff min 1 time 0 2>/dev/null
    return 0
}

# Read one key into NANA_KEY. Escape sequences are decoded into NANA_KEY as
# well (\033[A for up, and so on). "-d ''" is required on bash 3.2 so a
# newline is returned as data instead of terminating the read.
nana_get_key() {
    local c='' c2 c3 c4
    # bash 3.2's "read -n1" can fail with EAGAIN on this tty when several
    # keystrokes arrive at once. Reading a single byte from a pipe avoids it.
    IFS= read -r -d '' c < <(dd bs=1 count=1 2>/dev/null) || true
    [[ -n $c ]] || { NANA_KEY=''; return 1; }
    NANA_KEY=$c
    if [[ $NANA_KEY != $'\033' ]]; then
        return 0
    fi

    if IFS= read -r -s -n 1 -d '' -t 0.1 c2 2>/dev/null; then c=$c2; fi
    if [[ $c == '[' || $c == 'O' ]]; then
        if IFS= read -r -s -n 1 -d '' -t 0.1 c3 2>/dev/null; then c+=$c3; fi
        if [[ ${c:1:1} =~ [0-9] ]]; then
            if IFS= read -r -s -n 1 -d '' -t 0.1 c4 2>/dev/null; then c+=$c4; fi
        fi
    fi
    NANA_KEY=$'\033'"$c"
    return 0
}

cmd_nana() {
    if (( $# > 1 )); then
        minios_err 'usage: nana [file]'
        return 1
    fi
    local raw=${1:-untitled.txt}
    resolve_path "$raw" "$CWD"
    NANA_FILE=$RESOLVED_PATH

    if vfs_find "$NANA_FILE" && [[ ${VFS_TYPE[VFS_IDX]} == d ]]; then
        minios_err "nana: '$raw' is a directory"
        return 1
    fi

    nana_load_file "$NANA_FILE"
    NANA_Y=0
    NANA_X=0
    NANA_TOP=0
    NANA_DIRTY=0
    NANA_MSG=''
    NANA_KILL=''
    NANA_UNDO=()
    NANA_UNDO_P=0
    NANA_REDO=()

    local size=''
    size=$(stty size 2>/dev/null) || size=''
    NANA_ROWS=${size%% *}
    NANA_COLS=${size##* }
    [[ ${NANA_ROWS:-} =~ ^[0-9]+$ ]] || NANA_ROWS=24
    [[ ${NANA_COLS:-} =~ ^[0-9]+$ ]] || NANA_COLS=80
    (( NANA_ROWS > 5 )) || NANA_ROWS=24
    (( NANA_COLS > 20 )) || NANA_COLS=80

    NANA_SAVED_STTY=$(stty -g 2>/dev/null)
    NANA_OLD_EXIT=$(trap -p EXIT)
    NANA_OLD_INT=$(trap -p INT)
    NANA_OLD_TERM=$(trap -p TERM)
    stty -echo -icanon -isig -ixon -ixoff min 1 time 0 2>/dev/null
    trap nana_restore_terminal EXIT INT TERM

    nana_render
    while nana_get_key; do
        NANA_MSG=''
        case $NANA_KEY in
            $'\003'|$'\030')   # ^C / ^X
                if (( NANA_DIRTY )); then
                    nana_prompt 'Save changes? (Y/N/C): '
                    case $NANA_PROMPT_RESULT in
                        [Yy]*) nana_save_file ;;
                        [Nn]*) ;;
                        *) NANA_MSG='cancelled'; nana_render; continue ;;
                    esac
                fi
                break
                ;;
            $'\023') nana_save_file ;;                       # ^S
            $'\032') nana_undo ;;                            # ^Z
            $'\031') nana_redo ;;                            # ^Y
            $'\013') nana_cut_to_eol ;;                      # ^K
            $'\026') nana_paste ;;                           # ^V
            $'\027') nana_find ;;                            # ^W
            $'\007') nana_help_screen; nana_render; continue ;; # ^G
            $'\033[A'|$'\020') nana_move_up ;;
            $'\033[B'|$'\016') nana_move_down ;;
            $'\033[C'|$'\006') nana_move_right ;;
            $'\033[D'|$'\002') nana_move_left ;;
            $'\033[H'|$'\001') NANA_X=0 ;;
            $'\033[F'|$'\005') NANA_X=${#NANA_LINES[NANA_Y]} ;;
            $'\033[5~') nana_page_up ;;
            $'\033[6~') nana_page_down ;;
            $'\177'|$'\010') nana_backspace ;;
            $'\004') nana_delete_char ;;
            $'\r'|$'\n') nana_newline ;;
            *)
                if (( ${#NANA_KEY} == 1 )) && [[ $NANA_KEY != $'\033' ]]; then
                    nana_insert_text "$NANA_KEY"
                fi
                ;;
        esac
        nana_render
    done

    nana_restore_terminal
    nana_restore_traps
    return 0
}
