# MiniOS.1

MiniOS is a tiny operating system that runs inside your terminal. It has its
own virtual filesystem, a command shell with quoting and redirection, and it
keeps everything on a persistent virtual disk between runs.

It is written in portable Bash (works with the Bash 3.2 that ships on macOS)
and has no Python or other language dependencies.

## Install

```bash
./install.sh
```

Makes every project file executable. This is only needed if the execute bits
were lost (for example after unzipping); a normal `git clone` already keeps
`install.sh` and `run.sh` executable. If `./install.sh` itself is not
executable, run `bash install.sh` once to repair it.

## Run

```bash
./run.sh
```

Type `help` for the command list, and `exit` to shut down. `reboot` restarts
MiniOS without losing data.

## Persistent storage

All files live in a single virtual disk file named `minios.disk` next to
`run.sh`. It is created automatically on first boot with the original
`minios_fs.json` layout (`/home/user`, `/bin`, `/tmp` and a welcome readme),
and is re-written atomically after every change, so data survives crashes and
reboots.

Set `MINIOS_DISK` to use a different location:

```bash
MINIOS_DISK=/path/to/my.disk ./run.sh
```

## Commands

| Command | Description |
| --- | --- |
| `help [cmd]` | list commands / show detail for one |
| `pwd` | print working directory |
| `ls [-l] [-a] [path]` | list directory contents |
| `cd [path]` | change directory (`~` means `/home/user`) |
| `mkdir [-p] <dir>...` | create directories |
| `touch <file>...` | create empty files |
| `write <file> [text]` | write text to a file |
| `append <file> [text]` | append text to a file |
| `cat <file>...` | print file contents |
| `rm [-r] <path>...` | remove files or directories |
| `mv <src> <dst>` | move or rename |
| `cp [-r] <src> <dst>` | copy files or directories |
| `tree [path]` | show a directory tree |
| `stat <path>` | show node information |
| `echo [text]` | print text; `>` / `>>` write to a file |
| `df` | show virtual disk usage |
| `history` | show command history |
| `date`, `whoami`, `uname`, `ver` | system information |
| `banner`, `clear` | display helpers |
| `save` | force a disk sync |
| `reboot` | restart MiniOS |
| `exit` | shut down MiniOS |

## Examples

```text
user@minios:~$ mkdir -p ~/projects/notes
user@minios:~$ cd ~/projects
user@minios:~$ echo "hello from MiniOS" > hello.txt
user@minios:~$ echo "second line" >> hello.txt
user@minios:~$ cat hello.txt
hello from MiniOS
second line
user@minios:~$ write "my file.txt" "quoted names work too"
user@minios:~$ tree ~
```

Paths understand `.`, `..`, extra slashes and `~`. Quoted arguments,
backslash escapes, `>` and `>>` are all handled by the shell.

## Tests

```bash
./tests/smoke.sh
```

The smoke test uses a temporary disk, exercises the filesystem and checks
that data is still present after a separate process restarts MiniOS.

## Layout

```text
install.sh          makes all project files executable
run.sh              launcher
minios.sh           kernel: boot, tokenizer, command loop, persistence hook
lib/disk.sh         disk load/save and escaping
lib/vfs.sh          virtual filesystem operations
lib/commands.sh     command implementations
minios_fs.json      original filesystem description from MiniOS.1
tests/smoke.sh      automated tests
```
