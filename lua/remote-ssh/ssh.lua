local M = {}

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.allocate_endpoint(session_token)
    if vim.fn.has('win32') == 1 then
        local socket = assert(vim.uv.new_tcp())
        assert(socket:bind('127.0.0.1', 0))
        local address = assert(socket:getsockname())
        socket:close()
        return {
            address = '127.0.0.1:' .. address.port,
            forward = '127.0.0.1:' .. address.port,
        }
    end

    local directory = vim.fs.joinpath(vim.fn.stdpath('run'), 'remote-ssh')
    local path = vim.fs.joinpath(directory, session_token .. '.sock')
    if #path >= 90 then
        path = vim.fs.joinpath('/tmp', 'nvim-rs-' .. session_token .. '.sock')
    else
        vim.fn.mkdir(directory, 'p', tonumber('0700', 8))
    end
    vim.uv.fs_unlink(path)
    return {
        address = path,
        forward = path,
        cleanup_path = path,
    }
end

function M.command(context)
    local options = context.options
    local arguments = {
        options.ssh_command,
        '-T',
    }

    if context.password_authentication then
        vim.list_extend(arguments, {
            '-o',
            'BatchMode=no',
            '-o',
            'PreferredAuthentications=keyboard-interactive,password',
            '-o',
            'KbdInteractiveAuthentication=yes',
            '-o',
            'PasswordAuthentication=yes',
            '-o',
            'NumberOfPasswordPrompts=3',
        })
    else
        vim.list_extend(arguments, { '-o', 'BatchMode=yes' })
    end

    vim.list_extend(arguments, {
        '-o',
        'RemoteCommand=none',
        '-o',
        'SessionType=default',
        '-o',
        'StdinNull=no',
        '-o',
        'ForkAfterAuthentication=no',
        '-o',
        'ControlMaster=no',
        '-o',
        'ControlPath=none',
        '-o',
        'ControlPersist=no',
        '-o',
        'ClearAllForwardings=no',
        '-o',
        'StreamLocalBindMask=0177',
        '-o',
        'ExitOnForwardFailure=yes',
        '-o',
        'ConnectTimeout=' .. options.connect_timeout,
        '-o',
        'ServerAliveInterval=' .. options.server_alive_interval,
        '-o',
        'ServerAliveCountMax=' .. options.server_alive_count_max,
        '-L',
        context.endpoint.forward .. ':' .. context.remote_socket,
    })

    if context.destination.port then
        arguments[#arguments + 1] = '-p'
        arguments[#arguments + 1] = tostring(context.destination.port)
    end

    arguments[#arguments + 1] = '--'
    arguments[#arguments + 1] = context.destination.target
    arguments[#arguments + 1] = 'sh'
    arguments[#arguments + 1] = '-c'
    arguments[#arguments + 1] = shell_quote(context.bootstrap_wrapper)
    arguments[#arguments + 1] = 'sh'
    arguments[#arguments + 1] = context.session_token
    arguments[#arguments + 1] = context.version
    arguments[#arguments + 1] = tostring(context.api_level)
    arguments[#arguments + 1] = options.remote_appname
    arguments[#arguments + 1] = context.remote_socket
    return arguments
end

return M
