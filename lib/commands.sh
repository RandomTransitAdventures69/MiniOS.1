# MiniOS commands. Every command runs in the main shell (never in a
# subshell), so filesystem changes are never lost.

minios_err() {
    printf 'minios: %s\n' "$*"
}

# Direct children, sorted by name, in VFS_CHILDREN.
sorted_children() {
    vfs_children "$1"
    if (( ${#VFS_CHILDREN[@]} > 0 )); then
        local s=$(printf '%s\n' "${VFS_CHILDREN[@]}" | LC_ALL=C sort)
        VFS_CHILDREN=()
        while IFS= read -r p; do
            VFS_CHILDREN+=("$p")
        done <<< "$s"
    fi
}

cmd_help() {
    if (( $# > 0 )); then
        case $1 in
            ls)     printf 'ls [-l] [-a] [path]      list directory contents\n' ;;
            cd)     printf 'cd [path]                change directory ("~" is home)\n' ;;
            mkdir)  printf 'mkdir [-p] <dir>...      create directories\n' ;;
            touch)  printf 'touch <file>...          create empty files\n' ;;
            write)  printf 'write <file> [text]      write text to a file\n' ;;
            append) printf 'append <file> [text]     append text to a file\n' ;;
            cat)    printf 'cat <file>...            print file contents\n' ;;
            rm)     printf 'rm [-r] <path>...        remove files or directories\n' ;;
            mv)     printf 'mv <src> <dst>           move or rename\n' ;;
            cp)     printf 'cp [-r] <src> <dst>      copy files or directories\n' ;;
            tree)   printf 'tree [path]              show a directory tree\n' ;;
            *)      printf 'help: no entry for %s\n' "$1" ;;
        esac
        return 0
    fi

    printf 'MiniOS command reference\n'
    printf '  %-12s %s\n' \
        'help'       'show this list (help <cmd> for detail)' \
        'ls'         'list files [-l long] [-a all]' \
        'cd'         'change directory' \
        'pwd'        'print working directory' \
        'mkdir'      'create a directory [-p for parents]' \
        'touch'      'create an empty file' \
        'write'      'write text to a file' \
        'append'     'append text to a file' \
        'cat'        'print a file' \
        'rm'         'remove a file [-r for directories]' \
        'mv'         'move / rename' \
        'cp'         'copy [-r for directories]' \
        'tree'       'show the directory tree' \
        'stat'       'show node information' \
        'echo'       'print text (>, >> write to a file)' \
        'df'         'show virtual disk usage' \
        'history'    'show command history' \
        'date'       'show date and time' \
        'whoami'     'print current user' \
        'uname'      'print system information' \
        'ver'        'print MiniOS version' \
        'banner'     'print the boot banner' \
        'save'       'force a disk sync' \
        'clear'      'clear the screen' \
        'reboot'     'restart MiniOS' \
        'exit'       'shut down MiniOS'
    return 0
}

cmd_pwd() {
    printf '%s\n' "$CWD"
}

cmd_ls() {
    local long=0 all=0 target='' arg
    for arg in "$@"; do
        case $arg in
            -l) long=1 ;;
            -a) all=1 ;;
            -*) minios_err "ls: invalid option '$arg'"; return 1 ;;
            *)
                [[ -z $target ]] || { minios_err 'ls: too many arguments'; return 1; }
                target=$arg
                ;;
        esac
    done

    resolve_path "${target:-.}" "$CWD"
    local path=$RESOLVED_PATH
    vfs_find "$path" || { minios_err "ls: '$target': no such file or directory"; return 1; }

    if [[ ${VFS_TYPE[VFS_IDX]} == f ]]; then
        printf '%s\n' "${path##*/}"
        return 0
    fi

    sorted_children "$path"
    local p name idx line
    for p in "${VFS_CHILDREN[@]}"; do
        name=${p##*/}
        [[ $name == .* ]] && (( ! all )) && continue
        vfs_find "$p"; idx=$VFS_IDX
        if (( long )); then
            if [[ ${VFS_TYPE[idx]} == d ]]; then
                printf 'd       -  %s\n' "$name"
            else
                printf 'f  %6s  %s\n' "${#VFS_CONTENT[idx]}" "$name"
            fi
        else
            printf '%s\n' "$name"
        fi
    done
    return 0
}

cmd_cd() {
    local target=${1:-/home/user}
    resolve_path "$target" "$CWD"
    local path=$RESOLVED_PATH
    vfs_find "$path" || {
        minios_err "cd: '$target': no such file or directory"
        return 1
    }
    [[ ${VFS_TYPE[VFS_IDX]} == d ]] || {
        minios_err "cd: '$target': not a directory"
        return 1
    }
    CWD=$path
    return 0
}

cmd_mkdir() {
    local parents=0 arg
    local args=()
    for arg in "$@"; do
        case $arg in
            -p|--parents) parents=1 ;;
            -*) minios_err "mkdir: invalid option '$arg'"; return 1 ;;
            *) args+=("$arg") ;;
        esac
    done
    (( ${#args[@]} > 0 )) || { minios_err 'mkdir: missing operand'; return 1; }

    local path
    for arg in "${args[@]}"; do
        resolve_path "$arg" "$CWD"; path=$RESOLVED_PATH
        if vfs_find "$path"; then
            [[ ${VFS_TYPE[VFS_IDX]} == d ]] || {
                minios_err "mkdir: '$arg': file exists"
                return 1
            }
            if (( ! parents )); then
                minios_err "mkdir: '$arg': directory exists"
                return 1
            fi
            continue
        fi

        if (( parents )); then
            vfs_mkdir_p "$path" || {
                minios_err "mkdir: '$arg': a parent is not a directory"
                return 1
            }
        else
            vfs_split_path "$path"
            vfs_find "$VFS_PARENT_RESULT" || {
                minios_err "mkdir: '$arg': no such directory"
                return 1
            }
            [[ ${VFS_TYPE[VFS_IDX]} == d ]] || {
                minios_err "mkdir: '$arg': parent is not a directory"
                return 1
            }
            vfs_add_node "$path" d ''
            DISK_DIRTY=1
        fi
    done
    return 0
}

cmd_touch() {
    (( $# > 0 )) || { minios_err 'touch: missing operand'; return 1; }
    local arg path
    for arg in "$@"; do
        resolve_path "$arg" "$CWD"; path=$RESOLVED_PATH
        if vfs_find "$path"; then
            [[ ${VFS_TYPE[VFS_IDX]} == d ]] && {
                minios_err "touch: '$arg': is a directory"
                return 1
            }
            continue
        fi
        vfs_split_path "$path"
        vfs_find "$VFS_PARENT_RESULT" || {
            minios_err "touch: '$arg': no such directory"
            return 1
        }
        [[ ${VFS_TYPE[VFS_IDX]} == d ]] || {
            minios_err "touch: '$arg': parent is not a directory"
            return 1
        }
        vfs_add_node "$path" f ''
        DISK_DIRTY=1
    done
    return 0
}

cmd_write() {
    (( $# > 0 )) || { minios_err 'write: missing file operand'; return 1; }
    local raw=$1; shift
    resolve_path "$raw" "$CWD"
    if ! vfs_write_file "$RESOLVED_PATH" "$*" 0; then
        minios_err "write: cannot write '$raw'"
        return 1
    fi
    return 0
}

cmd_append() {
    (( $# > 0 )) || { minios_err 'append: missing file operand'; return 1; }
    local raw=$1; shift
    resolve_path "$raw" "$CWD"
    if ! vfs_write_file "$RESOLVED_PATH" "$*" 1; then
        minios_err "append: cannot write '$raw'"
        return 1
    fi
    return 0
}

cmd_cat() {
    (( $# > 0 )) || { minios_err 'cat: missing file operand'; return 1; }
    local raw path
    for raw in "$@"; do
        resolve_path "$raw" "$CWD"; path=$RESOLVED_PATH
        vfs_find "$path" || {
            minios_err "cat: '$raw': no such file"
            return 1
        }
        [[ ${VFS_TYPE[VFS_IDX]} == f ]] || {
            minios_err "cat: '$raw': is a directory"
            return 1
        }
        printf '%s' "${VFS_CONTENT[VFS_IDX]}"
    done
    return 0
}

cmd_rm() {
    local recursive=0 force=0 arg
    local args=()
    for arg in "$@"; do
        case $arg in
            -r|-R|--recursive) recursive=1 ;;
            -f|--force) force=1 ;;
            -*) minios_err "rm: invalid option '$arg'"; return 1 ;;
            *) args+=("$arg") ;;
        esac
    done
    (( ${#args[@]} > 0 )) || { minios_err 'rm: missing operand'; return 1; }

    local raw path rc
    for raw in "${args[@]}"; do
        resolve_path "$raw" "$CWD"; path=$RESOLVED_PATH
        vfs_remove "$path" "$recursive"; rc=$?
        case $rc in
            0) ;;
            1) (( force )) || minios_err "rm: '$raw': no such file or directory" ;;
            2) minios_err "rm: '$raw': is a directory (use -r)" ;;
            3) minios_err "rm: cannot remove root" ;;
        esac
        if (( rc != 0 && ! force )); then return 1; fi
    done
    return 0
}

cmd_mv() {
    (( $# == 2 )) || { minios_err 'usage: mv <src> <dst>'; return 1; }
    local src_raw=$1 dst_raw=$2
    resolve_path "$src_raw" "$CWD"; local src=$RESOLVED_PATH
    resolve_path "$dst_raw" "$CWD"; local dst=$RESOLVED_PATH

    vfs_move "$src" "$dst"
    case $? in
        0) return 0 ;;
        1) minios_err "mv: '$src_raw': no such file" ;;
        2) minios_err 'mv: cannot move a directory into itself' ;;
        3) minios_err "mv: '$dst_raw': destination exists" ;;
    esac
    return 1
}

cmd_cp() {
    local recursive=0
    if [[ ${1:-} == -r || ${1:-} == -R || ${1:-} == --recursive ]]; then
        recursive=1; shift
    fi
    (( $# == 2 )) || { minios_err 'usage: cp [-r] <src> <dst>'; return 1; }
    local src_raw=$1 dst_raw=$2
    resolve_path "$src_raw" "$CWD"; local src=$RESOLVED_PATH
    resolve_path "$dst_raw" "$CWD"; local dst=$RESOLVED_PATH

    vfs_copy "$src" "$dst" "$recursive"
    case $? in
        0) return 0 ;;
        1) minios_err "cp: '$src_raw': no such file" ;;
        2) minios_err "cp: '$src_raw': is a directory (use -r)" ;;
        3) minios_err "cp: '$dst_raw': destination exists" ;;
    esac
    return 1
}

tree_rec() {
    local path=$1 prefix=$2 p name branch
    sorted_children "$path"
    # Snapshot: recursive calls reuse the global VFS_CHILDREN array.
    local kids=("${VFS_CHILDREN[@]}")
    local count=${#kids[@]} i
    for (( i = 0; i < count; i++ )); do
        p=${kids[i]}
        name=${p##*/}
        if (( i == count - 1 )); then branch='`-- '; else branch='|-- '; fi
        printf '%s%s%s\n' "$prefix" "$branch" "$name"
        vfs_find "$p"
        if [[ ${VFS_TYPE[VFS_IDX]} == d ]]; then
            if (( i == count - 1 )); then
                tree_rec "$p" "$prefix    "
            else
                tree_rec "$p" "$prefix|   "
            fi
        fi
    done
}

cmd_tree() {
    local target=${1:-.}
    resolve_path "$target" "$CWD"
    local path=$RESOLVED_PATH
    vfs_find "$path" || {
        minios_err "tree: '$target': no such file or directory"
        return 1
    }
    [[ ${VFS_TYPE[VFS_IDX]} == d ]] || {
        minios_err "tree: '$target': not a directory"
        return 1
    }
    printf '%s\n' "$path"
    tree_rec "$path" ''
    return 0
}

cmd_stat() {
    (( $# == 1 )) || { minios_err 'usage: stat <path>'; return 1; }
    resolve_path "$1" "$CWD"
    local path=$RESOLVED_PATH
    vfs_find "$path" || {
        minios_err "stat: '$1': no such file"
        return 1
    }
    local idx=$VFS_IDX type=${VFS_TYPE[VFS_IDX]}
    vfs_split_path "$path"
    printf 'Path:   %s\n' "$path"
    printf 'Type:   %s\n' "$([[ $type == d ]] && printf directory || printf file)"
    printf 'Parent: %s\n' "$VFS_PARENT_RESULT"
    if [[ $type == f ]]; then
        printf 'Size:   %s bytes\n' "${#VFS_CONTENT[idx]}"
    fi
    return 0
}

cmd_df() {
    vfs_used_bytes
    printf 'MiniOS virtual disk: %s\n' "$DISK_FILE"
    printf 'Nodes:   %s (%s files, %s dirs)\n' \
        "$(( VFS_FILE_COUNT + VFS_DIR_COUNT ))" "$VFS_FILE_COUNT" "$VFS_DIR_COUNT"
    printf 'Used:    %s bytes\n' "$VFS_USED"
    return 0
}

cmd_echo() {
    local nl=1
    if [[ ${1:-} == -n ]]; then nl=0; shift; fi
    if (( nl )); then printf '%s\n' "$*"; else printf '%s' "$*"; fi
    return 0
}

cmd_history() {
    history
    return 0
}

cmd_date() {
    date '+%a %b %e %H:%M:%S %Z %Y'
    return 0
}

cmd_whoami() {
    printf '%s\n' "$MINIOS_USER"
    return 0
}

cmd_uname() {
    printf 'MiniOS %s / bash %s / %s\n' "$MINIOS_VERSION" "${BASH_VERSION%%(*}" "$(uname -s)"
    return 0
}

cmd_ver() {
    printf 'MiniOS %s\n' "$MINIOS_VERSION"
    return 0
}

cmd_banner() {
    cat <<'BANNER'
 __  __ ___ _   _  ___  ___  _   _  _____
|  \/  |_ _| \ | |/ __|/ _ \| | | |/ ____|
| |\/| || ||  \| | (__| (_) | |_| | (___
| |  | || || |\  |\___|\___/ \__, |\___ \
|_|  |_|___|_| \_||____/\___/   |_| ____/  v1.0
BANNER
    return 0
}

cmd_save() {
    disk_save || { minios_err 'could not write disk'; return 1; }
    printf 'disk saved\n'
    return 0
}

cmd_clear() {
    printf '\033[2J\033[H'
    return 0
}

cmd_exit() {
    return 2
}

cmd_reboot() {
    return 75
}

cmd_dispatch() {
    local cmd=$1; shift
    case $cmd in
        help|--help|-h|'?')   cmd_help "$@" ;;
        pwd)        cmd_pwd "$@" ;;
        ls|dir)     cmd_ls "$@" ;;
        cd)         cmd_cd "$@" ;;
        mkdir)      cmd_mkdir "$@" ;;
        touch)      cmd_touch "$@" ;;
        write)      cmd_write "$@" ;;
        append)     cmd_append "$@" ;;
        cat|type)   cmd_cat "$@" ;;
        rm|del)     cmd_rm "$@" ;;
        mv|move)    cmd_mv "$@" ;;
        cp|copy)    cmd_cp "$@" ;;
        tree)       cmd_tree "$@" ;;
        stat)       cmd_stat "$@" ;;
        df|mem)     cmd_df "$@" ;;
        echo)       cmd_echo "$@" ;;
        history)    cmd_history "$@" ;;
        date|time)  cmd_date "$@" ;;
        whoami)     cmd_whoami "$@" ;;
        uname)      cmd_uname "$@" ;;
        ver|version) cmd_ver "$@" ;;
        banner)     cmd_banner "$@" ;;
        save|sync)  cmd_save "$@" ;;
        clear|cls)  cmd_clear "$@" ;;
        exit|quit|shutdown|halt) cmd_exit "$@" ;;
        reboot)     cmd_reboot "$@" ;;
        '')
            ;;
        *)
            minios_err "$cmd: command not found (type 'help')"
            return 1
            ;;
    esac
    return $?
}
