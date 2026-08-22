# remote-ssh.nvim

`remote-ssh.nvim` connects the current Neovim UI to a headless Neovim server
over SSH. It follows Neovim's native remote architecture: the editor, files,
plugins, LSP clients, and terminals run on the remote host while the UI remains
local.

The plugin is pure Lua, has no plugin dependencies, and keeps startup work off
Neovim's main loop. One persistent SSH process performs the remote bootstrap,
owns the tunnel, and tracks the remote Neovim lifetime.

## Requirements

Local:

- Neovim 0.12 or newer
- OpenSSH 8.7 or newer available as `ssh`
- `curl` when a remote Neovim release archive must be downloaded locally
- SSH key/agent authentication, or a graphical SSH askpass helper for passwords

Remote:

- glibc-based Linux or macOS on x86_64 or arm64
- POSIX `sh` plus `ps`, `tr`, `sed`, `uname`, `dirname`, and `tar`
- A writable `/tmp` and home directory

## Installation

With `vim.pack`:

```lua
vim.pack.add({
    { src = 'https://github.com/8372127/remote-ssh.nvim' },
})
```

With `lazy.nvim`:

```lua
{
    '8372127/remote-ssh.nvim',
    cmd = { 'RemoteSSHConnect', 'RemoteSSHCancel' },
    opts = {},
}
```

For local development, add this directory to `'runtimepath'`:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand('~/path/to/remote-ssh.nvim'))
require('remote-ssh').setup()
```

## Usage

Connect directly:

```vim
:RemoteSSHConnect ssh://user@example.com
:RemoteSSHConnect ssh://root@example.com:2222
```

Append `!` to request password or keyboard-interactive authentication:

```vim
:RemoteSSHConnect! ssh://user@example.com
```

Password mode opens a trusted system askpass window. The plugin never accepts
passwords in a URI, stores them, or places them in the SSH command line. It
uses a generated askpass helper where the platform provides a supported
graphical prompt, and otherwise detects common `ssh-askpass` programs.

Run `:RemoteSSHConnect` without an argument to select a concrete `Host` entry
declared directly in `~/.ssh/config`. SSH options such as `IdentityFile`,
`ProxyJump`, and host aliases remain the responsibility of OpenSSH.

The plugin reuses a stable Neovim 0.9 or newer from the remote `PATH` when the
local TUI's `api_level` is inside the remote Neovim's documented
`[api_compatible, api_level]` range. This follows Neovim's backwards-compatible
API contract while preserving `NVIM_APPNAME` isolation, which was introduced
in Neovim 0.9. Different patch versions with the same compatible API level do
not require another installation.

When no compatible remote Neovim exists, the first connection downloads the
remote platform's exact local Neovim version, streams it through the existing
SSH connection, and installs it. Downloads are cached under
`stdpath('cache')/remote-ssh/downloads`. Remote state is isolated with
`NVIM_APPNAME=nvim-remote`:

```text
~/.config/nvim-remote/
~/.local/share/nvim-remote/
```

If remote extraction or validation rejects a completed archive, the local
cache entry is discarded so the next connection downloads a fresh copy.

Quit the remote Neovim normally with `:qa`. The SSH process, temporary RPC
socket, and detached local supervisor then close automatically; the remote
installation and data remain for fast reconnects.

Cancel a connection that is still starting:

```vim
:RemoteSSHCancel
```

Run diagnostics with:

```vim
:checkhealth remote-ssh
```

Inspect the bounded in-memory log from the active or most recent connection:

```lua
vim.print(require('remote-ssh').logs())
```

## Configuration

```lua
require('remote-ssh').setup({
    ssh_command = 'ssh',
    curl_command = 'curl',
    askpass_command = '',
    connect_timeout = 15,
    startup_timeout = 120,
    server_alive_interval = 15,
    server_alive_count_max = 3,
    remote_appname = 'nvim-remote',
    log_limit = 200,
    allow_external_ui = false,
})
```

Set `askpass_command` to a trusted askpass executable to override automatic
detection. The default empty string uses a generated helper when available or
a detected system askpass program.

## Transport

Unix clients attach through a local Unix domain socket. Windows clients use a
random loopback TCP port because Win32 OpenSSH does not implement
`ControlMaster`. The port is only open for the lifetime of the SSH process and
forwards to a random, user-owned Unix socket on the remote host.

Neovim RPC does not currently authenticate TCP clients. On Windows, another
process running on the same machine could discover and connect to the random
loopback port. Use the plugin only on a trusted, single-user workstation.

The implementation deliberately uses a single SSH connection for platform
discovery, archive upload, remote installation, startup, and the RPC tunnel.
This avoids repeated password prompts and keeps the Windows path responsive.

One attached built-in Neovim TUI is the supported configuration and implements
the required `connect` UI event. External or multiple UI clients are blocked by
default because unsupported clients interpret
`:connect` as `:detach`. Set `allow_external_ui = true` only after confirming
that the client implements this event.

## Current Scope

- Remote configuration is not copied from the local machine.
- Remote plugins and development tools are managed on the remote host.
- Password mode requires a graphical askpass helper and an interactive desktop.
- Restricted servers that disable SSH forwarding are not supported.
- Reconnection to an existing remote process is not yet implemented.
- Pre-release Neovim builds are not installed automatically.
