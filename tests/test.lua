local function equal(expected, actual, message)
    if not vim.deep_equal(expected, actual) then
        error(('%s\nexpected: %s\nactual:   %s'):format(message, vim.inspect(expected), vim.inspect(actual)))
    end
end

local function fails(callback, pattern)
    local ok, message = pcall(callback)
    assert(not ok, 'expected callback to fail')
    assert(tostring(message):match(pattern), ('expected error matching %q, got %q'):format(pattern, message))
end

local askpass = require('remote-ssh.askpass')
local transfer = require('remote-ssh.transfer')
local uri = require('remote-ssh.uri')

equal({ target = 'example.com', display = 'example.com' }, uri.parse('example.com'), 'parses SSH aliases')
equal({
    user = 'dev',
    host = 'example.com',
    port = 2222,
    target = 'dev@example.com',
    display = 'ssh://dev@example.com:2222',
}, uri.parse('ssh://dev@example.com:2222'), 'parses SSH URIs')
equal({
    user = nil,
    host = '2001:db8::1',
    port = 22,
    target = '2001:db8::1',
    display = 'ssh://[2001:db8::1]:22',
}, uri.parse('ssh://[2001:db8::1]:22'), 'parses bracketed IPv6 URIs')

fails(function()
    uri.parse('ssh://example.com/project')
end, 'remote paths')
fails(function()
    uri.parse('ssh://example.com:70000')
end, 'between 1 and 65535')
fails(function()
    uri.parse('ssh://2001:db8::1')
end, 'enclosed in brackets')
fails(function()
    uri.parse('-oProxyCommand=bad')
end, 'hyphen')
fails(function()
    uri.parse('ssh://bad%escape@example.com')
end, 'percent escape')
equal('user%@example.com', uri.parse('ssh://user%25@example.com').target, 'decodes escaped percent signs')
equal('host', uri.parse('SSH://host').host, 'accepts case-insensitive SSH URI schemes')
fails(function()
    uri.parse('ssh://user:password@example.com')
end, 'passwords')
fails(function()
    uri.parse('ssh://example%3Acom')
end, 'enclosed in brackets')

local resolved_askpass = askpass.resolve(vim.v.progpath)
equal(vim.v.progpath, resolved_askpass, 'accepts an explicit executable askpass helper')
equal({
    SSH_ASKPASS = vim.v.progpath,
    SSH_ASKPASS_REQUIRE = 'force',
}, askpass.environment(vim.v.progpath), 'creates a minimal askpass environment')
local missing_askpass, missing_askpass_error = askpass.resolve('remote-ssh-missing-askpass')
equal(nil, missing_askpass, 'rejects a missing configured askpass helper')
assert(missing_askpass_error:find('not executable', 1, true), 'explains a missing configured askpass helper')
if vim.fn.has('win32') == 1 or vim.fn.has('macunix') == 1 then
    local generated_askpass, generated_askpass_error = askpass._generated_askpass()
    assert(generated_askpass, generated_askpass_error)
    assert(generated_askpass:match('remote%-ssh%-askpass'), 'creates a remote-ssh askpass helper')
    local original_ssh_askpass = vim.env.SSH_ASKPASS
    vim.env.SSH_ASKPASS = nil
    equal(generated_askpass, askpass.resolve(''), 'prefers the generated remote-ssh askpass helper by default')
    vim.env.SSH_ASKPASS = original_ssh_askpass
end

local hosts = require('remote-ssh.hosts')
equal(
    { 'alpha', 'beta', 'delta' },
    hosts._parse({
        'Host alpha beta # comment',
        'host=delta',
        'Host *.internal !blocked wildcard?',
        'Host -invalid alpha',
    }),
    'parses concrete SSH host aliases'
)

local script = require('remote-ssh.bootstrap').script()
local wrapper = require('remote-ssh.bootstrap').wrapper()
assert(script:find('NVIM_REMOTE_READY', 1, true), 'bootstrap emits a readiness marker')
assert(script:find('NVIM_REMOTE_ASSET', 1, true), 'bootstrap requests a local release archive')
assert(script:find('vim.fn.api_info().version', 1, true), 'bootstrap reads official API compatibility metadata')
assert(script:find('remote_minor" -lt 9', 1, true), 'bootstrap requires NVIM_APPNAME support')
assert(script:find('remote_api_prerelease" = false', 1, true), 'bootstrap rejects unstable remote APIs')
assert(script:find('remote_api_compatible" -le "$local_api_level', 1, true), 'bootstrap checks the remote API floor')
assert(script:find('local_api_level" -le "$remote_api_level', 1, true), 'bootstrap checks the remote API ceiling')
assert(script:find('nvim-linux-x86_64.tar.gz', 1, true), 'bootstrap supports Linux x86_64')
assert(script:find('nvim-macos-arm64.tar.gz', 1, true), 'bootstrap supports macOS arm64')
assert(script:find('trap cleanup EXIT', 1, true), 'bootstrap cleans up the remote process on exit')
assert(script:find("trap 'abort 143' TERM", 1, true), 'bootstrap exits after signal cleanup')
assert(script:find('cat > "$stage/archive.tar.gz"', 1, true), 'bootstrap receives the release archive over SSH')
assert(script:find('TAR_OPTIONS=', 1, true), 'bootstrap ignores remote tar options')
assert(script:find('.guard', 1, true), 'bootstrap serializes stale-lock recovery')
assert(script:find('guard_pid=', 1, true), 'bootstrap recovers guards owned by dead processes')
assert(script:find('rm -rf "$old"', 1, true), 'bootstrap removes replaced installation backups')
assert(script:find('connection_parent=', 1, true), 'bootstrap monitors the SSH parent process')
assert(wrapper:find('NVIM_REMOTE_SCRIPT_END', 1, true), 'wrapper frames the bootstrap script')
assert(transfer.is_allowed('nvim-linux-x86_64.tar.gz'), 'allows a known Neovim release asset')
assert(not transfer.is_allowed('../archive.tar.gz'), 'rejects unsafe release asset names')
local invalid_archive = vim.fn.tempname()
vim.fn.writefile({ 'invalid archive' }, invalid_archive, 'b')
transfer.invalidate({ archive_path = invalid_archive, finished = true })
equal(0, vim.fn.filereadable(invalid_archive), 'invalidates a completed cached archive')
if vim.fn.executable('sh') == 1 then
    local shell_output = vim.fn.system({ 'sh', '-n' }, script)
    assert(vim.v.shell_error == 0, 'bootstrap shell syntax is invalid: ' .. shell_output)
    if vim.fn.executable('tar') == 1 then
        local bootstrap_path = vim.fn.tempname():gsub('\\', '/')
        vim.fn.writefile(vim.split(script, '\n', { plain = true }), bootstrap_path, 'b')
        local integration_output = vim.fn.system({ 'sh', 'tests/bootstrap_integration.sh', bootstrap_path })
        vim.fn.delete(bootstrap_path)
        assert(vim.v.shell_error == 0, 'bootstrap integration test failed: ' .. integration_output)
    end
end

require('remote-ssh').setup()
assert(vim.fn.exists(':RemoteSSHConnect') == 2, ':RemoteSSHConnect exists')
assert(vim.fn.exists(':RemoteSSHCancel') == 2, ':RemoteSSHCancel exists')

fails(function()
    require('remote-ssh').setup({ remote_appname = 'invalid app name' })
end, 'remote_appname')
fails(function()
    require('remote-ssh').setup({ remote_appname = '..' })
end, 'remote_appname')
fails(function()
    require('remote-ssh').setup({ startup_timeout = 2147484 })
end, 'too large')
fails(function()
    require('remote-ssh').setup({ unknown_option = true })
end, 'unknown remote%-ssh setup option')
fails(function()
    require('remote-ssh').setup({ ssh_command = 'ssh\ncommand' })
end, 'control characters')
fails(function()
    require('remote-ssh').setup({ askpass_command = 'askpass\ncommand' })
end, 'askpass_command')
fails(function()
    require('remote-ssh').setup({ curl_command = 'curl\ncommand' })
end, 'curl_command')
equal('nvim-remote', require('remote-ssh.config').get().remote_appname, 'invalid setup does not change options')
local options_copy = require('remote-ssh.config').get()
options_copy.remote_appname = 'mutated'
equal('nvim-remote', require('remote-ssh.config').get().remote_appname, 'configuration snapshots are immutable')

local original_system = vim.system
local original_cmd = vim.cmd
local original_notify = vim.notify
local notifications = {}

vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
end

local blocked_system_calls = 0
vim.system = function()
    blocked_system_calls = blocked_system_calls + 1
    error('vim.system must not run for a blocked UI')
end
require('remote-ssh').connect('blocked-ui.invalid')
equal(0, blocked_system_calls, 'blocks unsupported UIs before starting SSH')
assert(notifications[#notifications].message:find('requires one built-in TUI', 1, true))

require('remote-ssh').setup({ allow_external_ui = true })

local pending = {}
local system_arguments
local attach_commands = {}
local kills = 0
local transfer_requests = {}
local original_transfer_provide = transfer.provide
local original_transfer_cancel = transfer.cancel
local original_transfer_invalidate = transfer.invalidate
local invalidated_transfers = 0

transfer.provide = function(process, version, asset, session_token, curl_command, callbacks)
    local handle = {}
    transfer_requests[#transfer_requests + 1] = {
        asset = asset,
        curl_command = curl_command,
        session_token = session_token,
        version = version,
    }
    callbacks.on_status('fake transfer')
    process:write('fake archive')
    process:write(nil)
    callbacks.on_complete()
    return handle
end

transfer.cancel = function(handle)
    if handle then
        handle.cancelled = true
    end
end

transfer.invalidate = function(handle)
    if handle then
        invalidated_transfers = invalidated_transfers + 1
    end
end

vim.system = function(arguments, options, on_exit)
    system_arguments = arguments
    local request = { arguments = arguments, options = options, on_exit = on_exit, writes = {} }
    pending[#pending + 1] = request
    return {
        kill = function()
            kills = kills + 1
        end,
        write = function(_, data)
            request.writes[#request.writes + 1] = data == nil and '<EOF>' or data
        end,
    }
end

vim.cmd = function(command)
    attach_commands[#attach_commands + 1] = command
end

require('remote-ssh').connect('ssh://dev@example.com:2222')
local request = pending[#pending]
local separator_index
for index, argument in ipairs(request.arguments) do
    if argument == '--' then
        separator_index = index
    end
end
local session_token = assert(request.arguments[separator_index + 6])
equal(tostring(vim.version().api_level), request.arguments[separator_index + 8], 'passes the local API level')
assert(request.writes[1]:find('NVIM_REMOTE_SCRIPT_END:' .. session_token, 1, true), 'sends a framed bootstrap')
equal(true, request.options.stdin, 'keeps SSH stdin open for archive streaming')
request.options.stdout(nil, 'noise\nNVIM_REMOTE_ASSET:' .. session_token .. ':nvim-linux-')
request.options.stdout(nil, 'x86_64.tar.gz\nNVIM_REMOTE_')
assert(
    vim.wait(1000, function()
        return #transfer_requests == 1
    end),
    'starts a local archive transfer after the remote asset request'
)
equal('nvim-linux-x86_64.tar.gz', transfer_requests[1].asset, 'accepts only the requested known asset')
equal('curl', transfer_requests[1].curl_command, 'uses the configured local curl command')
equal('fake archive', request.writes[2], 'streams the local archive over the existing SSH stdin')
equal('<EOF>', request.writes[3], 'closes SSH stdin after the archive upload')
request.options.stdout(nil, 'READY:' .. session_token .. '\nNVIM_REMOTE_READY:' .. session_token .. '\n')
assert(
    vim.wait(1000, function()
        return #attach_commands == 1
    end),
    'connection state machine attaches after the readiness marker'
)
equal('connect', attach_commands[1].cmd, 'uses the native :connect command')
equal('-p', system_arguments[separator_index - 2], 'passes an explicit SSH port')
equal('2222', system_arguments[separator_index - 1], 'passes the SSH port value')
assert(system_arguments[separator_index + 1] == 'dev@example.com', 'passes the SSH destination as one argument')
assert(vim.tbl_contains(system_arguments, 'ClearAllForwardings=no'), 'protects forwarding from conflicting SSH config')
assert(vim.tbl_contains(system_arguments, 'StreamLocalBindMask=0177'), 'uses private local stream-socket permissions')
assert(vim.tbl_contains(system_arguments, 'RemoteCommand=none'), 'disables conflicting configured remote commands')
assert(vim.tbl_contains(system_arguments, 'SessionType=default'), 'enables the remote bootstrap command')
assert(vim.tbl_contains(system_arguments, 'StdinNull=no'), 'keeps stdin available for the bootstrap script')
assert(vim.tbl_contains(system_arguments, 'ControlMaster=no'), 'owns the SSH process lifecycle')
assert(vim.tbl_contains(system_arguments, 'BatchMode=yes'), 'uses non-interactive authentication by default')
equal(nil, request.options.env, 'default authentication does not install an askpass environment')
request.on_exit({ code = 0, signal = 0 })
vim.wait(20)

require('remote-ssh').setup({
    allow_external_ui = true,
    askpass_command = vim.v.progpath,
})
vim.api.nvim_cmd({
    cmd = 'RemoteSSHConnect',
    args = { 'ssh://password-test.invalid' },
    bang = true,
}, {})
request = pending[#pending]
assert(vim.tbl_contains(request.arguments, 'BatchMode=no'), 'command bang enables interactive authentication')
assert(
    vim.tbl_contains(request.arguments, 'PreferredAuthentications=keyboard-interactive,password'),
    'password mode requests keyboard-interactive and password authentication'
)
assert(vim.tbl_contains(request.arguments, 'PasswordAuthentication=yes'), 'password mode enables SSH passwords')
assert(
    vim.tbl_contains(request.arguments, 'KbdInteractiveAuthentication=yes'),
    'password mode enables challenge prompts'
)
equal(vim.v.progpath, request.options.env.SSH_ASKPASS, 'password mode selects the configured askpass helper')
equal('force', request.options.env.SSH_ASKPASS_REQUIRE, 'password mode forces askpass away from the TUI')
request.on_exit({ code = 255, signal = 0 })
vim.wait(20)

require('remote-ssh').connect('ssh://corrupt-cache.invalid')
request = pending[#pending]
local corrupt_cache_token = request.arguments[#request.arguments - 4]
request.options.stdout(nil, 'NVIM_REMOTE_ASSET:' .. corrupt_cache_token .. ':nvim-linux-x86_64.tar.gz\n')
assert(
    vim.wait(1000, function()
        return #transfer_requests >= 2
    end),
    'completes the simulated cached archive upload'
)
local invalidations_before_remote_failure = invalidated_transfers
request.on_exit({ code = 75, signal = 0 })
assert(
    vim.wait(1000, function()
        return invalidated_transfers == invalidations_before_remote_failure + 1
    end),
    'invalidates a completed archive when remote installation fails'
)

require('remote-ssh').setup({
    allow_external_ui = true,
    askpass_command = 'remote-ssh-missing-askpass',
})
local requests_before_missing_askpass = #pending
require('remote-ssh').connect('ssh://missing-askpass.invalid', { password = true })
equal(requests_before_missing_askpass, #pending, 'does not start SSH without an executable askpass helper')
assert(notifications[#notifications].message:find('not executable', 1, true), 'reports an invalid askpass helper')
require('remote-ssh').setup({ allow_external_ui = true })

local lifecycle_kills_before = kills
require('remote-ssh').connect('ssh://lifecycle-test.invalid')
vim.api.nvim_exec_autocmds('VimLeavePre', {})
assert(kills == lifecycle_kills_before + 1, 'VimLeavePre terminates the owned SSH process')
require('remote-ssh').cancel()

require('remote-ssh').connect('ssh://failure-test.invalid')
request = pending[#pending]
request.options.stderr(nil, '\27[31mremote failure')
request.on_exit({ code = 255, signal = 0 })
assert(
    vim.wait(1000, function()
        return notifications[#notifications] and notifications[#notifications].message:find('exit 255', 1, true)
    end),
    'failed SSH process reports its exit status'
)
assert(
    not notifications[#notifications].message:find('\27', 1, true),
    'remote errors do not expose terminal control bytes'
)
assert(
    table.concat(require('remote-ssh').logs(), '\n'):find('remote failure', 1, true),
    'retains diagnostic logs after a failed connection'
)
local attaches_before = #attach_commands
request.options.stdout(nil, 'NVIM_REMOTE_READY:' .. request.arguments[#request.arguments - 4] .. '\n')
vim.wait(20)
equal(attaches_before, #attach_commands, 'ignores readiness after the SSH process exits')

require('remote-ssh').connect('ssh://cancel-one.invalid')
local cancelled_request = pending[#pending]
require('remote-ssh').cancel()
require('remote-ssh').connect('ssh://cancel-two.invalid')
local reconnect_request = pending[#pending]
cancelled_request.on_exit({ code = 143, signal = 15 })
local reconnect_token = reconnect_request.arguments[#reconnect_request.arguments - 4]
reconnect_request.options.stdout(nil, 'NVIM_REMOTE_READY:' .. reconnect_token .. '\n')
assert(
    vim.wait(1000, function()
        return #attach_commands == attaches_before + 1
    end),
    'a cancelled process exit cannot clear a newer connection'
)
reconnect_request.on_exit({ code = 0, signal = 0 })
vim.wait(20)

vim.cmd = function(command)
    if command.cmd == 'connect' then
        error('simulated attach failure')
    end
end
local kills_before_attach_failure = kills
require('remote-ssh').connect('ssh://attach-failure.invalid')
request = pending[#pending]
local attach_failure_token = request.arguments[#request.arguments - 4]
request.options.stdout(nil, 'NVIM_REMOTE_READY:' .. attach_failure_token .. '\n')
assert(
    vim.wait(1000, function()
        return kills == kills_before_attach_failure + 1
    end),
    'terminates SSH when the local UI cannot attach'
)
request.on_exit({ code = 143, signal = 15 })
vim.wait(20)

vim.cmd = function(command)
    attach_commands[#attach_commands + 1] = command
end
require('remote-ssh').setup({ allow_external_ui = true, startup_timeout = 1 })
local kills_before_timeout = kills
require('remote-ssh').connect('ssh://timeout.invalid')
request = pending[#pending]
assert(
    vim.wait(1500, function()
        return notifications[#notifications]
            and notifications[#notifications].message:find('startup timed out', 1, true)
    end),
    'startup timeout reports a failure'
)
equal(kills_before_timeout + 1, kills, 'startup timeout terminates SSH')
request.on_exit({ code = 143, signal = 15 })
require('remote-ssh').setup({ allow_external_ui = true })

vim.system = original_system
vim.cmd = original_cmd
vim.notify = original_notify
transfer.provide = original_transfer_provide
transfer.cancel = original_transfer_cancel
transfer.invalidate = original_transfer_invalidate

print('remote-ssh tests passed')
