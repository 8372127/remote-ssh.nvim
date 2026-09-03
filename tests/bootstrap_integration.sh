#!/bin/sh

set -u

bootstrap=$1
root=$(mktemp -d "${TMPDIR:-.}/remote-ssh-test.XXXXXX") || exit 1
trap 'rm -rf "$root"' EXIT HUP INT TERM
tool_path=
add_tool_dir() {
    tool_resolved=$(command -v "$1") || {
        printf 'required test command not found: %s\n' "$1" >&2
        exit 1
    }
    tool_dir=$(dirname "$tool_resolved")
    case ":$tool_path:" in
        *:"$tool_dir":*) ;;
        *) tool_path="${tool_path:+$tool_path:}$tool_dir" ;;
    esac
}
for tool in sh ps tr sed uname dirname tar; do
    add_tool_dir "$tool"
done

mkdir -p "$root/payload/nvim-test/bin" "$root/home" "$root/data"

cat > "$root/runner" <<'EOF'
#!/bin/sh
uname() {
    case "$1" in
        -s) printf '%s\n' Linux ;;
        -m) printf '%s\n' x86_64 ;;
        *) return 1 ;;
    esac
}
. "$REAL_BOOTSTRAP"
EOF

cat > "$root/payload/nvim-test/bin/nvim" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then
    printf '%s\n' 'NVIM v9.9.9'
    exit 0
fi
case "$*" in
    *vim.fn.api_info*)
    printf '%s\n' "${FAKE_NVIM_METADATA:-14:0:false:9:9:9}"
    exit 0
    ;;
esac
if [ -n "${FAKE_NVIM_SIGNAL_PREFIX:-}" ]; then
    printf '%s\n' "$$" > "$FAKE_NVIM_SIGNAL_PREFIX.pid"
    : > "$FAKE_NVIM_SIGNAL_PREFIX.started"
    trap 'printf terminated > "$FAKE_NVIM_SIGNAL_PREFIX.terminated"; exit 0' HUP INT TERM
    while :; do
        sleep 1
    done
fi
exit 42
EOF

chmod +x "$root/runner" "$root/payload/nvim-test/bin/nvim"
tar -czf "$root/archive.tar.gz" -C "$root/payload" nvim-test || exit 1

run_bootstrap() {
    cat "$root/archive.tar.gz" | \
        HOME="$root/home" \
        XDG_DATA_HOME="$root/data" \
        PATH="$tool_path" \
        REAL_BOOTSTRAP="$bootstrap" \
            sh "$root/runner" "$1" 9.9.9 14 nvim-remote "$root/$1.sock" 1 - 104857600 "$root/$1-bootstrap"
}

run_bootstrap token-one > "$root/one.out" 2> "$root/one.err" &
first=$!
run_bootstrap token-two > "$root/two.out" 2> "$root/two.err" &
second=$!

first_status=0
second_status=0
wait "$first" || first_status=$?
wait "$second" || second_status=$?
if [ "$first_status" -ne 42 ] || [ "$second_status" -ne 42 ]; then
    printf 'unexpected concurrent statuses: %s %s\n' "$first_status" "$second_status" >&2
    cat "$root/one.err" "$root/two.err" >&2
    exit 10
fi
[ "$(cat "$root/one.out" "$root/two.out" | grep -c '^NVIM_REMOTE_ASSET:')" -eq 1 ] || { printf 'expected one archive request\n' >&2; exit 12; }
[ -x "$root/data/nvim-remote/versions/v9.9.9/bin/nvim" ] || { printf 'installed binary missing\n' >&2; exit 13; }
[ ! -e "$root/data/nvim-remote/.install-v9.9.9.lock" ] || { printf 'install lock leaked\n' >&2; exit 14; }
[ ! -e "$root/data/nvim-remote/.install-v9.9.9.guard" ] || { printf 'install guard leaked\n' >&2; exit 15; }

rm -rf "$root/data/nvim-remote/versions/v9.9.9"
mkdir "$root/data/nvim-remote/.install-v9.9.9.lock"
printf '%s\n' 99999999 > "$root/data/nvim-remote/.install-v9.9.9.lock/pid"
run_bootstrap token-three > "$root/three.out" 2> "$root/three.err"
third_status=$?
[ "$third_status" -eq 42 ] || { printf 'unexpected stale-lock status: %s\n' "$third_status" >&2; cat "$root/three.err" >&2; exit 16; }
grep -q '^NVIM_REMOTE_ASSET:token-three:' "$root/three.out" || { printf 'stale-lock recovery did not request an archive\n' >&2; exit 17; }
[ ! -e "$root/data/nvim-remote/.install-v9.9.9.lock" ] || { printf 'recovered lock leaked\n' >&2; exit 18; }
[ ! -e "$root/data/nvim-remote/.install-v9.9.9.guard" ] || { printf 'recovered guard leaked\n' >&2; exit 19; }

rm -rf "$root/data/nvim-remote/versions/v9.9.9"
mkdir "$root/data/nvim-remote/.install-v9.9.9.guard"
printf '%s\n' 99999999 > "$root/data/nvim-remote/.install-v9.9.9.guard/pid"
run_bootstrap token-four > "$root/four.out" 2> "$root/four.err"
fourth_status=$?
[ "$fourth_status" -eq 42 ] || { printf 'unexpected stale-guard status: %s\n' "$fourth_status" >&2; cat "$root/four.err" >&2; exit 42; }
grep -q '^NVIM_REMOTE_ASSET:token-four:' "$root/four.out" || { printf 'stale-guard recovery did not request an archive\n' >&2; exit 43; }
[ ! -e "$root/data/nvim-remote/.install-v9.9.9.lock" ] || { printf 'stale-guard recovery leaked lock\n' >&2; exit 44; }
[ ! -e "$root/data/nvim-remote/.install-v9.9.9.guard" ] || { printf 'stale guard was not recovered\n' >&2; exit 45; }

HOME="$root/home" \
XDG_DATA_HOME="$root/data" \
PATH="$root/payload/nvim-test/bin:$tool_path" \
REAL_BOOTSTRAP="$bootstrap" \
FAKE_NVIM_METADATA=14:0:false:0:12:1 \
    sh "$root/runner" token-compatible 9.9.9 14 nvim-compatible "$root/token-compatible.sock" 1 - 104857600 \
        "$root/token-compatible-bootstrap" > "$root/compatible.out" 2> "$root/compatible.err"
compatible_status=$?
[ "$compatible_status" -eq 42 ] || { printf 'unexpected compatible remote status: %s\n' "$compatible_status" >&2; cat "$root/compatible.err" >&2; exit 31; }
! grep -q '^NVIM_REMOTE_ASSET:' "$root/compatible.out" || { printf 'compatible remote requested an archive\n' >&2; exit 32; }
[ ! -e "$root/data/nvim-compatible/versions/v9.9.9" ] || { printf 'compatible remote installed a redundant copy\n' >&2; exit 33; }

HOME="$root/home" \
XDG_DATA_HOME="$root/data" \
PATH="$root/payload/nvim-test/bin:$tool_path" \
REAL_BOOTSTRAP="$bootstrap" \
FAKE_NVIM_METADATA=15:14:false:0:13:0 \
    sh "$root/runner" token-newer-compatible 9.9.9 14 nvim-newer-compatible "$root/token-newer-compatible.sock" 1 - 104857600 \
        "$root/token-newer-compatible-bootstrap" > "$root/newer-compatible.out" 2> "$root/newer-compatible.err"
newer_compatible_status=$?
[ "$newer_compatible_status" -eq 42 ] || { printf 'unexpected newer compatible status: %s\n' "$newer_compatible_status" >&2; cat "$root/newer-compatible.err" >&2; exit 38; }
! grep -q '^NVIM_REMOTE_ASSET:' "$root/newer-compatible.out" || { printf 'newer compatible remote requested an archive\n' >&2; exit 39; }

cat "$root/archive.tar.gz" | \
    HOME="$root/home" \
    XDG_DATA_HOME="$root/data" \
    PATH="$root/payload/nvim-test/bin:$tool_path" \
    REAL_BOOTSTRAP="$bootstrap" \
    FAKE_NVIM_METADATA=14:0:false:0:11:9 \
        sh "$root/runner" token-pre-floor 9.9.9 14 nvim-pre-floor "$root/token-pre-floor.sock" 1 - 104857600 \
            "$root/token-pre-floor-bootstrap" > "$root/pre-floor.out" 2> "$root/pre-floor.err"
pre_floor_status=$?
[ "$pre_floor_status" -eq 42 ] || { printf 'unexpected pre-floor status: %s\n' "$pre_floor_status" >&2; cat "$root/pre-floor.err" >&2; exit 46; }
grep -q '^NVIM_REMOTE_ASSET:token-pre-floor:' "$root/pre-floor.out" || { printf 'pre-0.12 compatible-looking remote was reused\n' >&2; exit 47; }

cat "$root/archive.tar.gz" | \
    HOME="$root/home" \
    XDG_DATA_HOME="$root/data" \
    PATH="$root/payload/nvim-test/bin:$tool_path" \
    REAL_BOOTSTRAP="$bootstrap" \
    FAKE_NVIM_METADATA=13:0:false:0:11:4 \
        sh "$root/runner" token-older-api 9.9.9 14 nvim-older-api "$root/token-older-api.sock" 1 - 104857600 \
            "$root/token-older-api-bootstrap" > "$root/older-api.out" 2> "$root/older-api.err"
older_api_status=$?
[ "$older_api_status" -eq 42 ] || { printf 'unexpected older API status: %s\n' "$older_api_status" >&2; cat "$root/older-api.err" >&2; exit 40; }
grep -q '^NVIM_REMOTE_ASSET:token-older-api:' "$root/older-api.out" || { printf 'older API remote was reused\n' >&2; exit 41; }

cat "$root/archive.tar.gz" | \
    HOME="$root/home" \
    XDG_DATA_HOME="$root/data" \
    PATH="$root/payload/nvim-test/bin:$tool_path" \
    REAL_BOOTSTRAP="$bootstrap" \
    FAKE_NVIM_METADATA=6:0:false:0:8:3 \
        sh "$root/runner" token-too-old 9.9.9 14 nvim-too-old "$root/token-too-old.sock" 1 - 104857600 \
            "$root/token-too-old-bootstrap" > "$root/too-old.out" 2> "$root/too-old.err"
too_old_status=$?
[ "$too_old_status" -eq 42 ] || { printf 'unexpected old remote status: %s\n' "$too_old_status" >&2; cat "$root/too-old.err" >&2; exit 34; }
grep -q '^NVIM_REMOTE_ASSET:token-too-old:' "$root/too-old.out" || { printf 'pre-0.12 remote was reused\n' >&2; exit 35; }

cat "$root/archive.tar.gz" | \
    HOME="$root/home" \
    XDG_DATA_HOME="$root/data" \
    PATH="$root/payload/nvim-test/bin:$tool_path" \
    REAL_BOOTSTRAP="$bootstrap" \
    FAKE_NVIM_METADATA=14:0:true:0:12:0 \
        sh "$root/runner" token-prerelease 9.9.9 14 nvim-prerelease "$root/token-prerelease.sock" 1 - 104857600 \
            "$root/token-prerelease-bootstrap" > "$root/prerelease.out" 2> "$root/prerelease.err"
prerelease_status=$?
[ "$prerelease_status" -eq 42 ] || { printf 'unexpected prerelease remote status: %s\n' "$prerelease_status" >&2; cat "$root/prerelease.err" >&2; exit 36; }
grep -q '^NVIM_REMOTE_ASSET:token-prerelease:' "$root/prerelease.out" || { printf 'prerelease remote was reused\n' >&2; exit 37; }

signal_test=1
case "$(uname -s)" in
    Windows_NT*|MINGW*|MSYS*) signal_test=0 ;;
esac
if [ "$signal_test" -eq 1 ]; then
        archive_fifo="$root/archive-fifo"
        mkfifo "$archive_fifo"
        sleep 100 > "$archive_fifo" &
        archive_writer=$!
        HOME="$root/home" \
        XDG_DATA_HOME="$root/data" \
        PATH="$tool_path" \
        REAL_BOOTSTRAP="$bootstrap" \
            sh "$root/runner" token-archive-signal 9.9.8 14 nvim-cancel "$root/token-archive-signal.sock" 1 - 104857600 \
                "$root/token-archive-signal-bootstrap" < "$archive_fifo" > "$root/archive-signal.out" &
        archive_signal_parent=$!

        archive_signal_attempt=0
        while ! grep -q '^NVIM_REMOTE_ASSET:' "$root/archive-signal.out" 2>/dev/null; do
            archive_signal_attempt=$((archive_signal_attempt + 1))
            if [ "$archive_signal_attempt" -ge 100 ]; then
                kill "$archive_signal_parent" "$archive_writer" 2>/dev/null || true
                printf 'signal test archive receiver did not start\n' >&2
                exit 25
            fi
            sleep 0.05
        done

        kill "$archive_writer" 2>/dev/null || true
        wait "$archive_writer" 2>/dev/null || true
        archive_signal_status=0
        wait "$archive_signal_parent" || archive_signal_status=$?
        [ "$archive_signal_status" -ne 0 ] || { printf 'truncated archive unexpectedly succeeded\n' >&2; exit 26; }
        [ ! -e "$root/data/nvim-cancel/.install-v9.9.8.lock" ] || { printf 'cancelled install lock leaked\n' >&2; exit 29; }
        [ ! -e "$root/data/nvim-cancel/.install-v9.9.8.guard" ] || { printf 'cancelled install guard leaked\n' >&2; exit 30; }

        signal_prefix="$root/signal-child"
        HOME="$root/home" \
        XDG_DATA_HOME="$root/data" \
        PATH="$tool_path" \
        REAL_BOOTSTRAP="$bootstrap" \
        FAKE_NVIM_SIGNAL_PREFIX="$signal_prefix" \
            sh "$root/runner" token-signal 9.9.9 14 nvim-remote "$root/token-signal.sock" 1 - 104857600 "$root/token-signal-bootstrap" &
        signal_parent=$!

        signal_attempt=0
        while [ ! -e "$signal_prefix.started" ]; do
            signal_attempt=$((signal_attempt + 1))
            if [ "$signal_attempt" -ge 100 ]; then
                kill "$signal_parent" 2>/dev/null || true
                printf 'signal test child did not start\n' >&2
                exit 20
            fi
            sleep 0.05
        done

        signal_child=$(cat "$signal_prefix.pid")
        kill -TERM "$signal_parent"
        signal_status=0
        wait "$signal_parent" || signal_status=$?
        [ "$signal_status" -eq 143 ] || { printf 'unexpected signal exit status: %s\n' "$signal_status" >&2; exit 21; }
        [ -e "$signal_prefix.terminated" ] || { printf 'remote Neovim did not receive termination\n' >&2; exit 22; }
        if kill -0 "$signal_child" 2>/dev/null; then
            printf 'remote Neovim process leaked after termination\n' >&2
            exit 23
        fi
        [ ! -e "$root/token-signal.sock" ] || { printf 'remote RPC socket leaked after termination\n' >&2; exit 24; }
fi

exit 0
