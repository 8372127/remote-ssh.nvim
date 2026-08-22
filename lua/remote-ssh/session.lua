local askpass = require('remote-ssh.askpass')
local bootstrap = require('remote-ssh.bootstrap')
local config = require('remote-ssh.config')
local ssh = require('remote-ssh.ssh')
local transfer = require('remote-ssh.transfer')
local uri = require('remote-ssh.uri')

local M = {}

local active
local latest_token
local last_logs = {}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = 'remote-ssh' })
end

local function has_single_builtin_tui()
    local uis = vim.api.nvim_list_uis()
    if #uis ~= 1 then
        return false
    end
    local channel = vim.api.nvim_get_chan_info(uis[1].chan)
    return channel.client and channel.client.name == 'nvim-tui'
end

local function token()
    local ok, bytes = pcall(vim.uv.random, 16)
    if ok and type(bytes) == 'string' then
        return (bytes:gsub('.', function(char)
            return string.format('%02x', string.byte(char))
        end))
    end

    return vim.fn.sha256(table.concat({ vim.uv.hrtime(), vim.fn.getpid(), math.random() }, ':')):sub(1, 32)
end

local function append_log(session, source, data)
    if not data or data == '' then
        return
    end

    data = data:gsub('[%z\1-\8\11\12\14-\31\127]', '?')
    for line in data:gmatch('[^\r\n]+') do
        session.logs[#session.logs + 1] = source .. ': ' .. line
    end

    while #session.logs > session.log_limit do
        table.remove(session.logs, 1)
    end
end

local function cancel_transfer(session)
    if not session.transfer then
        return
    end
    transfer.cancel(session.transfer)
    session.transfer = nil
end

local function terminate(session)
    cancel_transfer(session)
    if session.process then
        pcall(session.process.kill, session.process, 15)
    end
end

local function invalidate_asset(session)
    if session.transfer then
        transfer.invalidate(session.transfer)
    end
end

local function cleanup(session)
    cancel_transfer(session)
    if session.timer then
        session.timer:stop()
        session.timer:close()
        session.timer = nil
    end
    if session.leave_autocmd then
        pcall(vim.api.nvim_del_autocmd, session.leave_autocmd)
        session.leave_autocmd = nil
    end
    if session.endpoint.cleanup_path then
        vim.uv.fs_unlink(session.endpoint.cleanup_path)
    end
    if latest_token == session.token then
        last_logs = vim.deepcopy(session.logs)
    end
    if active == session then
        active = nil
    end
end

local function failure_message(session, result)
    local lines = {}
    local first = math.max(1, #session.logs - 5)
    for index = first, #session.logs do
        lines[#lines + 1] = session.logs[index]
    end
    local detail = table.concat(lines, '\n')
    local code = result and result.code or 'unknown'
    return ('Connection to %s failed (exit %s)%s'):format(
        session.destination.display,
        code,
        detail ~= '' and ('\n' .. detail) or ''
    )
end

local function fail_startup(session, message)
    if active ~= session or session.state ~= 'starting' then
        return
    end
    session.state = 'failed'
    invalidate_asset(session)
    terminate(session)
    cleanup(session)
    notify(message, vim.log.levels.ERROR)
end

local function provide_asset(session, version_string, asset)
    if not transfer.is_allowed(asset) then
        fail_startup(session, 'Remote host requested an unsupported Neovim asset: ' .. tostring(asset))
        return
    end

    local ok, handle_or_error =
        pcall(transfer.provide, session.process, version_string, asset, session.token, session.curl_command, {
            on_status = function(message)
                vim.schedule(function()
                    if active == session and session.state == 'starting' then
                        notify(message)
                    end
                end)
            end,
            on_error = function(message)
                vim.schedule(function()
                    fail_startup(session, message)
                end)
            end,
            on_complete = function()
                append_log(session, 'local', 'Neovim archive upload completed')
            end,
        })
    if not ok then
        fail_startup(session, 'Unable to prepare the local Neovim archive: ' .. tostring(handle_or_error))
        return
    end
    session.transfer = handle_or_error
end

local function attach(session)
    if active ~= session or session.state ~= 'starting' then
        return
    end

    session.state = 'attached'
    if session.timer then
        session.timer:stop()
        session.timer:close()
        session.timer = nil
    end

    notify('Connected to ' .. session.destination.display)
    local ok, error_message = pcall(vim.cmd, {
        cmd = 'connect',
        args = { session.endpoint.address },
    })
    if not ok then
        session.state = 'failed'
        terminate(session)
        cleanup(session)
        notify('Unable to attach the local UI: ' .. tostring(error_message), vim.log.levels.ERROR)
    end
end

function M.connect(input, connect_options)
    if active then
        notify('A Remote SSH session is already starting or active', vim.log.levels.WARN)
        return
    end

    if vim.fn.has('nvim-0.12') ~= 1 or vim.fn.exists(':connect') ~= 2 then
        notify('Remote SSH requires Neovim 0.12 or newer with :connect support', vim.log.levels.ERROR)
        return
    end

    local ok, destination = pcall(uri.parse, input)
    if not ok then
        notify(destination, vim.log.levels.ERROR)
        return
    end

    connect_options = connect_options or {}
    if
        type(connect_options) ~= 'table'
        or (connect_options.password ~= nil and type(connect_options.password) ~= 'boolean')
    then
        notify('Connection options must contain a boolean password field', vim.log.levels.ERROR)
        return
    end
    local password_authentication = connect_options.password == true

    local options = config.get()
    local environment
    if password_authentication then
        local helper, askpass_error = askpass.resolve(options.askpass_command)
        if not helper then
            notify(askpass_error, vim.log.levels.ERROR)
            return
        end
        environment = askpass.environment(helper)
    end
    local builtin_tui = has_single_builtin_tui()
    if not options.allow_external_ui and not builtin_tui then
        notify(
            'Remote SSH requires one built-in TUI; set allow_external_ui=true only if the active UI implements connect',
            vim.log.levels.ERROR
        )
        return
    end

    local version = vim.version()
    if version.api_prerelease then
        notify('Pre-release Neovim builds are not supported for automatic remote installation', vim.log.levels.ERROR)
        return
    end

    local session_token = token()
    local endpoint_ok, endpoint = pcall(ssh.allocate_endpoint, session_token)
    if not endpoint_ok then
        notify('Unable to allocate a local RPC endpoint: ' .. tostring(endpoint), vim.log.levels.ERROR)
        return
    end

    local version_string = ('%d.%d.%d'):format(version.major, version.minor, version.patch)
    local remote_socket = '/tmp/nvim-remote-' .. session_token .. '.sock'
    local arguments = ssh.command({
        api_level = version.api_level,
        bootstrap_wrapper = bootstrap.wrapper(),
        destination = destination,
        endpoint = endpoint,
        options = options,
        password_authentication = password_authentication,
        remote_socket = remote_socket,
        session_token = session_token,
        version = version_string,
    })
    local script = bootstrap.payload(session_token)
    local marker = 'NVIM_REMOTE_READY:' .. session_token
    local asset_marker = 'NVIM_REMOTE_ASSET:' .. session_token .. ':'
    local stdout_buffer = ''

    local session = {
        curl_command = options.curl_command,
        destination = destination,
        endpoint = endpoint,
        log_limit = options.log_limit,
        logs = {},
        state = 'starting',
        builtin_tui = builtin_tui,
        token = session_token,
    }
    active = session
    latest_token = session_token

    notify('Connecting to ' .. destination.display)

    session.timer = assert(vim.uv.new_timer())
    session.timer:start(
        options.startup_timeout * 1000,
        0,
        vim.schedule_wrap(function()
            if active ~= session or session.state ~= 'starting' then
                return
            end
            session.state = 'failed'
            terminate(session)
            cleanup(session)
            notify('Remote startup timed out after ' .. options.startup_timeout .. ' seconds', vim.log.levels.ERROR)
        end)
    )

    local system_ok, process_or_error = pcall(vim.system, arguments, {
        stdin = true,
        env = environment,
        text = true,
        stdout = function(error_message, data)
            if error_message then
                append_log(session, 'stdout', error_message)
            end
            append_log(session, 'stdout', data)
            stdout_buffer = stdout_buffer .. (data or '')
            local asset_start = stdout_buffer:find(asset_marker, 1, true)
            if session.state == 'starting' and not session.asset_requested and asset_start then
                local asset_end = stdout_buffer:find('\n', asset_start + #asset_marker, true)
                if asset_end then
                    local asset = stdout_buffer:sub(asset_start + #asset_marker, asset_end - 1):gsub('\r$', '')
                    session.asset_requested = true
                    vim.schedule(function()
                        if active == session and session.state == 'starting' then
                            provide_asset(session, version_string, asset)
                        end
                    end)
                end
            end
            if session.state == 'starting' and stdout_buffer:find(marker, 1, true) then
                vim.schedule(function()
                    attach(session)
                end)
            elseif #stdout_buffer > 4096 then
                stdout_buffer = stdout_buffer:sub(-2048)
            end
        end,
        stderr = function(error_message, data)
            if error_message then
                append_log(session, 'stderr', error_message)
            end
            append_log(session, 'stderr', data)
        end,
    }, function(result)
        vim.schedule(function()
            local was_attached = session.state == 'attached'
            if session.state == 'starting' then
                session.state = 'failed'
                invalidate_asset(session)
                notify(failure_message(session, result), vim.log.levels.ERROR)
            end
            cleanup(session)
            if was_attached and result.code ~= 0 then
                notify(failure_message(session, result), vim.log.levels.ERROR)
            end
            if was_attached and session.builtin_tui then
                vim.defer_fn(function()
                    if not active and #vim.api.nvim_list_uis() == 0 then
                        pcall(vim.cmd, { cmd = 'quitall', bang = true })
                    end
                end, 100)
            end
        end)
    end)

    if not system_ok then
        session.state = 'failed'
        cleanup(session)
        notify('Unable to start SSH: ' .. tostring(process_or_error), vim.log.levels.ERROR)
        return
    end

    session.process = process_or_error
    local write_ok, write_error = pcall(session.process.write, session.process, script)
    if not write_ok then
        fail_startup(session, 'Unable to send the remote bootstrap: ' .. tostring(write_error))
        return
    end
    session.leave_autocmd = vim.api.nvim_create_autocmd('VimLeavePre', {
        once = true,
        desc = 'Terminate the active Remote SSH connection',
        callback = function()
            terminate(session)
        end,
    })
end

function M.cancel()
    if not active or active.state ~= 'starting' then
        notify('No pending Remote SSH connection', vim.log.levels.INFO)
        return
    end

    active.state = 'cancelled'
    terminate(active)
    cleanup(active)
    notify('Remote SSH connection cancelled')
end

function M.logs()
    return vim.deepcopy(active and active.logs or last_logs)
end

return M
