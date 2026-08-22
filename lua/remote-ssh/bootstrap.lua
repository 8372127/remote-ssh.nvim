local M = {}

function M.script()
    return [=[
set -eu

token=$1
version=$2
local_api_level=$3
appname=$4
socket=$5
bootstrap_file=$6

rm -f "$bootstrap_file"

umask 077
main_pid=$$
connection_parent=
watchdog=

stop_watchdog() {
    if [ -n "$watchdog" ] && kill -0 "$watchdog" 2>/dev/null; then
        kill "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
    fi
    watchdog=
}

start_watchdog() {
    [ -z "$watchdog" ] || return 0
    connection_parent=$(ps -o ppid= -p "$main_pid" 2>/dev/null | tr -d '[:space:]')
    case "$connection_parent" in
        ''|*[!0-9]*) return 0 ;;
    esac

    (
        while [ "$(ps -o ppid= -p "$main_pid" 2>/dev/null | tr -d '[:space:]')" = "$connection_parent" ]; do
            sleep 1
        done
        kill -TERM "$main_pid" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    watchdog=$!
}

data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
remote_root="$data_home/$appname"
install_dir="$remote_root/versions/v$version"
nvim_bin="$install_dir/bin/nvim"

version_of() {
    "$1" --version 2>/dev/null | sed -n '1{s/^NVIM v//;p;}'
}

is_expected() {
    [ -x "$1" ] && [ "$(version_of "$1")" = "$version" ]
}

api_metadata_of() {
    NVIM_APPNAME="$appname" "$1" --headless --clean -u NONE -i NONE \
        --cmd "lua local v=vim.fn.api_info().version; io.stdout:write(string.format('%d:%d:%s:%d:%d:%d\\n', v.api_level, v.api_compatible, tostring(v.api_prerelease), v.major, v.minor, v.patch))" \
        --cmd 'qa!' 2>/dev/null
}

is_compatible() {
    [ -x "$1" ] || return 1
    metadata=$(api_metadata_of "$1") || return 1
    old_ifs=$IFS
    IFS=:
    # shellcheck disable=SC2086
    set -- $metadata
    IFS=$old_ifs
    [ "$#" -eq 6 ] || return 1

    remote_api_level=$1
    remote_api_compatible=$2
    remote_api_prerelease=$3
    remote_major=$4
    remote_minor=$5
    remote_patch=$6
    for value in "$remote_api_level" "$remote_api_compatible" "$remote_major" "$remote_minor" "$remote_patch"; do
        case "$value" in
            ''|*[!0-9]*) return 1 ;;
        esac
    done
    [ "$remote_api_prerelease" = false ] || return 1

    if [ "$remote_major" -eq 0 ] && [ "$remote_minor" -lt 9 ]; then
        return 1
    fi
    [ "$remote_api_compatible" -le "$local_api_level" ] \
        && [ "$local_api_level" -le "$remote_api_level" ]
}

if command -v nvim >/dev/null 2>&1 && is_compatible "$(command -v nvim)"; then
    nvim_bin=$(command -v nvim)
elif ! is_expected "$nvim_bin"; then
    os=$(uname -s)
    arch=$(uname -m)
    case "$os/$arch" in
        Linux/x86_64|Linux/amd64) asset=nvim-linux-x86_64.tar.gz ;;
        Linux/aarch64|Linux/arm64) asset=nvim-linux-arm64.tar.gz ;;
        Darwin/x86_64|Darwin/amd64) asset=nvim-macos-x86_64.tar.gz ;;
        Darwin/arm64|Darwin/aarch64) asset=nvim-macos-arm64.tar.gz ;;
        *) printf 'unsupported remote platform: %s/%s\n' "$os" "$arch" >&2; exit 70 ;;
    esac

    command -v tar >/dev/null 2>&1 || {
        printf 'tar is required to install remote Neovim\n' >&2
        exit 69
    }

    start_watchdog

    mkdir -p "$remote_root/versions"
    lock="$remote_root/.install-v$version.lock"
    guard="$remote_root/.install-v$version.guard"
    lock_owned=0
    guard_owned=0
    stage=
    old=

    release_guard() {
        if [ "$guard_owned" -eq 1 ]; then
            rm -rf "$guard" || true
            guard_owned=0
        fi
    }

    acquire_guard() {
        guard_attempt=0
        while ! mkdir "$guard" 2>/dev/null; do
            guard_attempt=$((guard_attempt + 1))
            guard_pid=$(cat "$guard/pid" 2>/dev/null || true)
            case "$guard_pid" in
                ''|*[!0-9]*)
                    if [ "$guard_attempt" -ge 30 ]; then
                        rm -rf "$guard"
                        guard_attempt=0
                        continue
                    fi
                    ;;
                *)
                    if ! kill -0 "$guard_pid" 2>/dev/null; then
                        rm -rf "$guard"
                        guard_attempt=0
                        continue
                    fi
                    ;;
            esac
            if [ "$guard_attempt" -ge 300 ]; then
                printf 'timed out waiting for remote Neovim installation guard: %s\n' "$guard" >&2
                exit 73
            fi
            sleep 0.1
        done
        guard_owned=1
        printf '%s\n' "$$" > "$guard/pid"
        printf '%s\n' "$token" > "$guard/token"
    }

    cleanup_install() {
        if [ -n "$old" ] && [ -d "$old" ]; then
            if [ ! -e "$install_dir" ]; then
                mv "$old" "$install_dir" 2>/dev/null || true
            else
                rm -rf "$old" || true
            fi
            old=
        fi
        [ -z "$stage" ] || rm -rf "$stage" || true
        if [ "$lock_owned" -eq 1 ]; then
            rm -rf "$lock" || true
            lock_owned=0
        fi
        release_guard
    }

    abort_install() {
        status=$1
        trap - EXIT HUP INT TERM
        cleanup_install
        stop_watchdog
        exit "$status"
    }

    trap 'cleanup_install; stop_watchdog' EXIT
    trap 'abort_install 129' HUP
    trap 'abort_install 130' INT
    trap 'abort_install 143' TERM

    invalid_lock_attempt=0
    while [ "$lock_owned" -eq 0 ]; do
        acquire_guard
        if mkdir "$lock" 2>/dev/null; then
            lock_owned=1
            printf '%s\n' "$$" > "$lock/pid"
            printf '%s\n' "$token" > "$lock/token"
            release_guard
            break
        fi
        if is_expected "$nvim_bin"; then
            release_guard
            break
        fi
        lock_pid=$(cat "$lock/pid" 2>/dev/null || true)
        case "$lock_pid" in
            ''|*[!0-9]*)
                invalid_lock_attempt=$((invalid_lock_attempt + 1))
                if [ "$invalid_lock_attempt" -ge 300 ]; then
                    printf 'remote Neovim installation lock has no valid owner: %s\n' "$lock" >&2
                    exit 73
                fi
                ;;
            *)
                invalid_lock_attempt=0
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    rm -rf "$lock"
                    release_guard
                    continue
                fi
                ;;
        esac
        release_guard
        sleep 0.1
    done

    if [ "$lock_owned" -eq 1 ]; then
        stage="$remote_root/.install-v$version-$token"
        old="$remote_root/.old-v$version-$token"
        if ! is_expected "$nvim_bin"; then
            rm -rf "$stage" "$old"
            mkdir -p "$stage/root"
            printf 'NVIM_REMOTE_ASSET:%s:%s\n' "$token" "$asset"
            cat > "$stage/archive.tar.gz"
            TAR_OPTIONS='' GZIP='' BZIP2='' XZ_OPT='' \
                tar -xzf "$stage/archive.tar.gz" --strip-components=1 -C "$stage/root"
            if ! is_expected "$stage/root/bin/nvim"; then
                printf 'downloaded Neovim archive failed version validation\n' >&2
                exit 75
            fi

            if [ -e "$install_dir" ]; then
                mv "$install_dir" "$old"
            fi
            if ! mv "$stage/root" "$install_dir"; then
                if [ -d "$old" ]; then
                    mv "$old" "$install_dir" 2>/dev/null || true
                fi
                exit 74
            fi
            rm -rf "$old" || true
            old=
        fi

        trap - EXIT HUP INT TERM
        cleanup_install
    fi
    nvim_bin="$install_dir/bin/nvim"
fi

start_watchdog
abort_before_server() {
    status=$1
    trap - EXIT HUP INT TERM
    stop_watchdog
    exit "$status"
}
trap stop_watchdog EXIT
trap 'abort_before_server 129' HUP
trap 'abort_before_server 130' INT
trap 'abort_before_server 143' TERM

[ -x "$nvim_bin" ] || {
    printf 'remote Neovim executable was not found after installation\n' >&2
    exit 71
}

mkdir -p "$(dirname "$socket")"
rm -f "$socket"
child=
cleanup() {
    if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
        kill "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    rm -f "$socket"
    stop_watchdog
}

abort() {
    status=$1
    trap - EXIT HUP INT TERM
    cleanup
    exit "$status"
}

trap cleanup EXIT
trap 'abort 129' HUP
trap 'abort 130' INT
trap 'abort 143' TERM

unset VIMRUNTIME
NVIM_APPNAME="$appname" "$nvim_bin" --headless --listen "$socket" &
child=$!

attempt=0
while [ ! -S "$socket" ]; do
    if ! kill -0 "$child" 2>/dev/null; then
        wait "$child"
        exit $?
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 200 ]; then
        printf 'remote Neovim did not create its RPC socket\n' >&2
        exit 72
    fi
    sleep 0.05
done

printf 'NVIM_REMOTE_READY:%s\n' "$token"
wait "$child"
]=]
end

function M.wrapper()
    return [=[
bootstrap_file=${TMPDIR:-/tmp}/nvim-remote-bootstrap-$1.sh
umask 077
: > "$bootstrap_file" || exit 74
bootstrap_complete=0
while IFS= read -r bootstrap_line; do
    if [ "$bootstrap_line" = "NVIM_REMOTE_SCRIPT_END:$1" ]; then
        bootstrap_complete=1
        break
    fi
    printf '%s\n' "$bootstrap_line" >> "$bootstrap_file"
done
if [ "$bootstrap_complete" -ne 1 ]; then
    rm -f "$bootstrap_file"
    printf 'incomplete remote bootstrap payload\n' >&2
    exit 76
fi
exec sh "$bootstrap_file" "$@" "$bootstrap_file"
]=]
end

function M.payload(session_token)
    return M.script() .. '\nNVIM_REMOTE_SCRIPT_END:' .. session_token .. '\n'
end

return M
