# MiniOS virtual filesystem.
#
# The whole tree lives in three parallel indexed arrays (bash 3.2 has no
# associative arrays). Every path is absolute and normalized. Node 0 is "/".

vfs_add_node() {
    VFS_PATH+=("$1")
    VFS_TYPE+=("$2")
    VFS_CONTENT+=("$3")
    VFS_ADD_IDX=$(( ${#VFS_PATH[@]} - 1 ))
}

vfs_seed_defaults() {
    VFS_PATH=()
    VFS_TYPE=()
    VFS_CONTENT=()

    vfs_add_node / d ''
    vfs_mkdir_p /home/user
    vfs_mkdir_p /bin
    vfs_mkdir_p /tmp
    vfs_write_file /home/user/readme.txt \
        $'Welcome to MiniOS!\nType \'help\' for commands.\n' 0
    DISK_DIRTY=1
}

# Resolve a raw path against a base directory into RESOLVED_PATH.
# Handles absolute paths, ".", "..", repeated slashes and a leading "~".
resolve_path() {
    local raw=$1 base=${2:-/} abs part
    case $raw in
        /*)      abs=$raw ;;
        '~')     abs=/home/user ;;
        '~/'*)   abs="/home/user/${raw:2}" ;;
        *)       abs="$base/$raw" ;;
    esac

    local parts=()
    IFS='/' read -r -a parts <<< "$abs"

    local out=()
    for part in "${parts[@]}"; do
        case $part in
            ''|'.') ;;
            '..')
                if (( ${#out[@]} > 0 )); then
                    unset "out[$((${#out[@]} - 1))]"
                fi
                ;;
            *) out+=("$part") ;;
        esac
    done

    if (( ${#out[@]} == 0 )); then
        RESOLVED_PATH=/
    else
        RESOLVED_PATH="/$(vfs_join / "${out[@]}")"
    fi
}

vfs_join() {
    local sep=$1; shift
    local out='' item first=1
    for item in "$@"; do
        if (( first )); then
            out=$item
            first=0
        else
            out+="$sep$item"
        fi
    done
    printf '%s' "$out"
}

vfs_find() {
    VFS_IDX=-1
    local i
    for (( i = 0; i < ${#VFS_PATH[@]}; i++ )); do
        if [[ ${VFS_PATH[i]} == "$1" ]]; then
            VFS_IDX=$i
            return 0
        fi
    done
    return 1
}

vfs_split_path() {
    local p=$1
    if [[ $p == / ]]; then
        VFS_PARENT_RESULT=/
        VFS_BASE_RESULT=/
        return 0
    fi
    VFS_BASE_RESULT=${p##*/}
    VFS_PARENT_RESULT=${p%/*}
    [[ -z $VFS_PARENT_RESULT ]] && VFS_PARENT_RESULT=/
    return 0
}

# mkdir -p semantics. Returns 1 if any component is an existing file.
vfs_mkdir_p() {
    local target=$1 cur='' part
    local parts=()
    IFS='/' read -r -a parts <<< "$target"
    for part in "${parts[@]}"; do
        [[ -z $part ]] && continue
        cur+="/$part"
        if ! vfs_find "$cur"; then
            vfs_add_node "$cur" d ''
            DISK_DIRTY=1
        elif [[ ${VFS_TYPE[VFS_IDX]} != d ]]; then
            return 1
        fi
    done
    return 0
}

vfs_write_file() {
    local path=$1 content=$2 append=${3:-0}
    if vfs_find "$path"; then
        [[ ${VFS_TYPE[VFS_IDX]} == d ]] && return 1
        if (( append )); then
            VFS_CONTENT[$VFS_IDX]="${VFS_CONTENT[$VFS_IDX]}$content"
        else
            VFS_CONTENT[$VFS_IDX]=$content
        fi
    else
        vfs_split_path "$path"
        vfs_find "$VFS_PARENT_RESULT" || return 1
        [[ ${VFS_TYPE[VFS_IDX]} == d ]] || return 1
        vfs_add_node "$path" f "$content"
    fi
    DISK_DIRTY=1
    return 0
}

# Returns 2 for "directory without -r", 3 for "root cannot be removed".
vfs_remove() {
    local path=$1 recursive=${2:-0}
    vfs_find "$path" || return 1
    local type=${VFS_TYPE[VFS_IDX]}

    if [[ $type == d ]]; then
        (( recursive )) || return 2
        [[ $path == / ]] && return 3
    fi

    local prefix=$path
    [[ $prefix == / ]] || prefix="$path/"
    local i victims=' '
    for (( i = 0; i < ${#VFS_PATH[@]}; i++ )); do
        if [[ ${VFS_PATH[i]} == "$prefix"* ]]; then
            victims+="$i "
        fi
    done

    vfs_remove_indices "$victims"
    DISK_DIRTY=1
    return 0
}

vfs_remove_indices() {
    local victims=$1 i
    local np=() nt=() nc=()
    for (( i = 0; i < ${#VFS_PATH[@]}; i++ )); do
        [[ " $victims " == *" $i "* ]] && continue
        np+=("${VFS_PATH[i]}")
        nt+=("${VFS_TYPE[i]}")
        nc+=("${VFS_CONTENT[i]}")
    done
    VFS_PATH=("${np[@]}")
    VFS_TYPE=("${nt[@]}")
    VFS_CONTENT=("${nc[@]}")
    return 0
}

# Direct children (absolute paths) of a directory into VFS_CHILDREN.
vfs_children() {
    local target=$1 prefix i rest
    if [[ $target == / ]]; then prefix=/; else prefix="$target/"; fi
    VFS_CHILDREN=()
    for (( i = 0; i < ${#VFS_PATH[@]}; i++ )); do
        [[ ${VFS_PATH[i]} == "$prefix"* ]] || continue
        rest=${VFS_PATH[i]#$prefix}
        [[ -z $rest || $rest == */* ]] && continue
        VFS_CHILDREN+=("${VFS_PATH[i]}")
    done
    return 0
}

# Returns 2 for "cannot move a directory into itself", 3 for "exists".
vfs_move() {
    local src=$1 dst=$2
    vfs_find "$src" || return 1
    local type=${VFS_TYPE[VFS_IDX]}

    if vfs_find "$dst" && [[ ${VFS_TYPE[VFS_IDX]} == d ]]; then
        vfs_split_path "$src"
        dst="$dst/${VFS_BASE_RESULT}"
    fi
    [[ $dst == "$src" ]] && return 0
    [[ $type == d && $dst == "$src/"* ]] && return 2

    vfs_split_path "$dst"
    vfs_find "$VFS_PARENT_RESULT" || return 1
    [[ ${VFS_TYPE[VFS_IDX]} == d ]] || return 1
    vfs_find "$dst" && return 3

    local i
    for (( i = 0; i < ${#VFS_PATH[@]}; i++ )); do
        if [[ ${VFS_PATH[i]} == "$src" ]]; then
            VFS_PATH[i]=$dst
        elif [[ ${VFS_PATH[i]} == "$src/"* ]]; then
            VFS_PATH[i]="$dst${VFS_PATH[i]#$src}"
        fi
    done
    DISK_DIRTY=1
    return 0
}

# Returns 2 for "directory needs -r", 3 for "destination exists".
vfs_copy() {
    local src=$1 dst=$2 recursive=${3:-0}
    vfs_find "$src" || return 1
    local type=${VFS_TYPE[VFS_IDX]}
    [[ $type == d && $recursive -eq 0 ]] && return 2

    if vfs_find "$dst" && [[ ${VFS_TYPE[VFS_IDX]} == d ]]; then
        vfs_split_path "$src"
        dst="$dst/${VFS_BASE_RESULT}"
    fi
    [[ $dst == "$src" ]] && return 3
    [[ $type == d && $dst == "$src/"* ]] && return 2

    vfs_split_path "$dst"
    vfs_find "$VFS_PARENT_RESULT" || return 1
    [[ ${VFS_TYPE[VFS_IDX]} == d ]] || return 1
    vfs_find "$dst" && return 3

    vfs_find "$src"
    local src_i=$VFS_IDX prefix="$src/" count=${#VFS_PATH[@]}
    local i rest
    vfs_add_node "$dst" "${VFS_TYPE[src_i]}" "${VFS_CONTENT[src_i]}"
    if [[ ${VFS_TYPE[src_i]} == d ]]; then
        for (( i = 0; i < count; i++ )); do
            [[ ${VFS_PATH[i]} == "$prefix"* ]] || continue
            rest=${VFS_PATH[i]#$prefix}
            vfs_add_node "$dst/$rest" "${VFS_TYPE[i]}" "${VFS_CONTENT[i]}"
        done
    fi
    DISK_DIRTY=1
    return 0
}

vfs_used_bytes() {
    VFS_USED=0
    VFS_FILE_COUNT=0
    VFS_DIR_COUNT=0
    local i
    for (( i = 0; i < ${#VFS_PATH[@]}; i++ )); do
        if [[ ${VFS_TYPE[i]} == f ]]; then
            VFS_USED=$(( VFS_USED + ${#VFS_CONTENT[i]} ))
            VFS_FILE_COUNT=$(( VFS_FILE_COUNT + 1 ))
        else
            VFS_DIR_COUNT=$(( VFS_DIR_COUNT + 1 ))
        fi
    done
}
