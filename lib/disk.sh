# MiniOS persistence layer.
#
# The virtual disk is a single plain-text file (minios.disk by default).
# One record per line, fields separated by a real TAB character:
#
#   D<TAB><escaped-path>
#   F<TAB><escaped-path><TAB><escaped-content>
#
# Escapes (so any byte except NUL can live on one line):
#   \  -> \\     newline -> \n     CR -> \r     TAB -> \t     | -> \p
#
# Everything is written to a temporary file and then moved into place, so an
# interrupted write can never corrupt the previous disk.

# --- string escaping -------------------------------------------------------

str_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    s=${s//'|'/\\p}
    ESC_RESULT=$s
}

str_unescape() {
    local s=$1 out='' i=0 n=${#1} ch
    while (( i < n )); do
        ch=${s:i:1}
        if [[ $ch == '\' ]]; then
            i=$(( i + 1 ))
            if (( i < n )); then
                ch=${s:i:1}
                case $ch in
                    n)  out+=$'\n' ;;
                    r)  out+=$'\r' ;;
                    t)  out+=$'\t' ;;
                    p)  out+='|' ;;
                    '\') out+='\' ;;
                    *)  out+=$ch ;;
                esac
            else
                out+='\'
            fi
        else
            out+=$ch
        fi
        i=$(( i + 1 ))
    done
    UNESC_RESULT=$out
}

# --- disk I/O --------------------------------------------------------------

disk_load() {
    VFS_PATH=()
    VFS_TYPE=()
    VFS_CONTENT=()
    DISK_DIRTY=0

    if [[ ! -f $DISK_FILE ]]; then
        vfs_seed_defaults
        disk_save || return 1
        return 0
    fi

    local line kind raw_path raw_content path content
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        [[ ${line:0:1} == '#' ]] && continue

        raw_path=''
        raw_content=''
        IFS=$'\t' read -r kind raw_path raw_content <<< "$line"

        # A node needs a type and an absolute path.
        [[ ${#raw_path} -gt 0 && ${raw_path:0:1} == '/' ]] || continue
        str_unescape "$raw_path"; path=$UNESC_RESULT

        case $kind in
            D)
                vfs_add_node "$path" d '' >/dev/null
                ;;
            F)
                str_unescape "$raw_content"; content=$UNESC_RESULT
                vfs_add_node "$path" f "$content" >/dev/null
                ;;
            *)
                # Unknown record type: ignore it (forward compatible).
                ;;
        esac
    done < "$DISK_FILE"

    # A disk with no root record is unusable; rebuild the default one.
    if ! vfs_find /; then
        vfs_seed_defaults
        DISK_DIRTY=1
    fi
    return 0
}

disk_save() {
    local tmp="${DISK_FILE}.tmp.$$"
    local i ep ec

    {
        printf '# MiniOS virtual disk v1 -- generated file, do not edit by hand\n'
        for (( i = 0; i < ${#VFS_PATH[@]}; i++ )); do
            str_escape "${VFS_PATH[i]}"; ep=$ESC_RESULT
            if [[ ${VFS_TYPE[i]} == d ]]; then
                printf 'D\t%s\n' "$ep"
            else
                str_escape "${VFS_CONTENT[i]}"; ec=$ESC_RESULT
                printf 'F\t%s\t%s\n' "$ep" "$ec"
            fi
        done
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    if ! mv -f "$tmp" "$DISK_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    DISK_DIRTY=0
    return 0
}

disk_sync() {
    (( DISK_DIRTY )) && disk_save
    return 0
}

disk_mark_dirty() {
    DISK_DIRTY=1
}
