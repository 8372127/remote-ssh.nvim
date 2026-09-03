local M = {}

local defaults = {
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
    preview = {
        enabled = true,
        keymap = '',
        max_size = 100 * 1024 * 1024,
    },
}

local options = vim.deepcopy(defaults)

local function assert_positive_integer(name, value, maximum)
    assert(type(value) == 'number' and value > 0 and value % 1 == 0, name .. ' must be a positive integer')
    assert(not maximum or value <= maximum, name .. ' is too large')
end

function M.setup(user_options)
    user_options = user_options or {}
    assert(type(user_options) == 'table', 'remote-ssh setup options must be a table')
    for name in pairs(user_options) do
        assert(defaults[name] ~= nil, 'unknown remote-ssh setup option: ' .. tostring(name))
    end

    local candidate = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_options)
    assert(
        type(candidate.ssh_command) == 'string'
            and candidate.ssh_command ~= ''
            and not candidate.ssh_command:find('[%z\1-\31\127]'),
        'ssh_command must be a non-empty string without control characters'
    )
    assert(
        type(candidate.askpass_command) == 'string' and not candidate.askpass_command:find('[%z\1-\31\127]'),
        'askpass_command must be a string without control characters'
    )
    assert(
        type(candidate.curl_command) == 'string'
            and candidate.curl_command ~= ''
            and not candidate.curl_command:find('[%z\1-\31\127]'),
        'curl_command must be a non-empty string without control characters'
    )
    assert(
        type(candidate.remote_appname) == 'string'
            and candidate.remote_appname ~= '.'
            and candidate.remote_appname ~= '..'
            and candidate.remote_appname:match('^[%w._-]+$'),
        'remote_appname must be a safe directory name containing only letters, digits, dot, underscore, and hyphen'
    )
    assert_positive_integer('connect_timeout', candidate.connect_timeout)
    assert_positive_integer('startup_timeout', candidate.startup_timeout, 2147483)
    assert_positive_integer('server_alive_interval', candidate.server_alive_interval)
    assert_positive_integer('server_alive_count_max', candidate.server_alive_count_max)
    assert_positive_integer('log_limit', candidate.log_limit)
    assert(type(candidate.allow_external_ui) == 'boolean', 'allow_external_ui must be a boolean')
    assert(type(candidate.preview) == 'table', 'preview must be a table')
    for name in pairs(candidate.preview) do
        assert(defaults.preview[name] ~= nil, 'unknown remote-ssh preview option: ' .. tostring(name))
    end
    assert(type(candidate.preview.enabled) == 'boolean', 'preview.enabled must be a boolean')
    assert(
        candidate.preview.keymap == nil
            or (type(candidate.preview.keymap) == 'string' and not candidate.preview.keymap:find('[%z\1-\31\127]')),
        'preview.keymap must be a string without control characters or nil'
    )
    assert_positive_integer('preview.max_size', candidate.preview.max_size)
    options = candidate
end

function M.get()
    return vim.deepcopy(options)
end

return M
