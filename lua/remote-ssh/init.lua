local config = require('remote-ssh.config')
local hosts = require('remote-ssh.hosts')
local session = require('remote-ssh.session')

local M = {}

local commands_created = false

local function choose_host(password_authentication)
    local available = hosts.list()
    if #available == 0 then
        vim.ui.input({ prompt = 'SSH destination: ', default = 'ssh://' }, function(value)
            if value and vim.trim(value) ~= '' then
                session.connect(value, { password = password_authentication })
            end
        end)
        return
    end

    vim.ui.select(available, { prompt = 'Remote SSH host:' }, function(host)
        if host then
            session.connect('ssh://' .. host, { password = password_authentication })
        end
    end)
end

local function create_commands()
    if commands_created then
        return
    end
    commands_created = true

    vim.api.nvim_create_user_command('RemoteSSHConnect', function(command)
        if command.args == '' then
            choose_host(command.bang)
        else
            session.connect(command.args, { password = command.bang })
        end
    end, {
        nargs = '?',
        bang = true,
        desc = 'Connect the current UI to a Neovim server over SSH',
        complete = function(arg_lead)
            return hosts.complete(arg_lead)
        end,
    })

    vim.api.nvim_create_user_command('RemoteSSHCancel', function()
        session.cancel()
    end, {
        desc = 'Cancel a pending Remote SSH connection',
    })
end

function M.setup(options)
    config.setup(options)
    create_commands()
end

function M.connect(destination, options)
    session.connect(destination, options)
end

function M.cancel()
    session.cancel()
end

function M.logs()
    return session.logs()
end

function M._load()
    create_commands()
end

return M
