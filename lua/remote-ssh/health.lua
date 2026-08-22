local askpass = require('remote-ssh.askpass')
local config = require('remote-ssh.config')

local M = {}

local function has_single_builtin_tui()
    local uis = vim.api.nvim_list_uis()
    if #uis ~= 1 then
        return false
    end
    local channel = vim.api.nvim_get_chan_info(uis[1].chan)
    return channel.client and channel.client.name == 'nvim-tui'
end

function M.check()
    vim.health.start('remote-ssh')

    if vim.fn.has('nvim-0.12') == 1 then
        vim.health.ok('Neovim 0.12 or newer')
    else
        vim.health.error('Neovim 0.12 or newer is required')
    end

    if vim.fn.exists(':connect') == 2 then
        vim.health.ok(':connect is available')
    else
        vim.health.error(':connect is unavailable in this Neovim build')
    end

    if has_single_builtin_tui() then
        vim.health.ok('The built-in TUI supports the connect event')
    elseif config.get().allow_external_ui then
        vim.health.warn('An external UI is allowed; verify that it implements the connect event')
    else
        vim.health.warn('No built-in TUI is attached; external UIs are blocked by default')
    end

    local ssh_command = config.get().ssh_command
    if vim.fn.executable(ssh_command) == 1 then
        vim.health.ok(ssh_command .. ' is executable')
        local ok, result = pcall(function()
            return vim.system({ ssh_command, '-V' }, { text = true }):wait(5000)
        end)
        if ok and result then
            local output = (result.stdout or '') .. (result.stderr or '')
            local major, minor = output:match('OpenSSH.-_(%d+)%.(%d+)')
            if major then
                major, minor = tonumber(major), tonumber(minor)
                if major > 8 or (major == 8 and minor >= 7) then
                    vim.health.ok(('OpenSSH %d.%d supports required command-line options'):format(major, minor))
                else
                    vim.health.error('OpenSSH 8.7 or newer is required')
                end
            else
                vim.health.warn('Unable to determine the OpenSSH version')
            end
        else
            vim.health.warn('Unable to execute the OpenSSH version check')
        end
    else
        vim.health.error(ssh_command .. ' was not found in PATH')
    end

    local curl_command = config.get().curl_command
    if vim.fn.executable(curl_command) == 1 then
        vim.health.ok(curl_command .. ' is available for local Neovim downloads')
    else
        vim.health.warn(curl_command .. ' is required when the remote host lacks an API-compatible Neovim')
    end

    local askpass_path, askpass_error = askpass.resolve(config.get().askpass_command)
    if askpass_path then
        vim.health.ok('Password authentication askpass helper: ' .. askpass_path)
    else
        vim.health.warn(askpass_error .. '; key authentication remains available')
    end

    if vim.fn.has('win32') == 1 then
        vim.health.info('Windows uses one persistent SSH process and does not require ControlMaster')
        vim.health.warn('Windows exposes the unauthenticated RPC tunnel on a random loopback TCP port')
    else
        vim.health.info('Unix clients use a local Unix domain socket for RPC')
    end

    vim.health.info('Remote hosts require POSIX sh, ps, tr, tar, and a writable /tmp')
end

return M
