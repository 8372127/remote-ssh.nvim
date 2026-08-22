local M = {}

local function decode(value)
    local cursor = 1
    while true do
        local position = value:find('%', cursor, true)
        if not position then
            break
        end
        assert(value:sub(position + 1, position + 2):match('^%x%x$'), 'invalid percent escape in SSH URI')
        cursor = position + 3
    end

    local decoded = value:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return decoded
end

local function validate_component(name, value)
    assert(value ~= '', name .. ' must not be empty')
    assert(not value:find('[%z\1-\32\127]'), name .. ' contains control characters')
    assert(not value:find('%s'), name .. ' must not contain whitespace')
end

local function parse_authority(authority)
    local user
    local host_port = authority
    local at = authority:match('^.*()@')
    if at then
        user = decode(authority:sub(1, at - 1))
        host_port = authority:sub(at + 1)
        validate_component('SSH user', user)
        assert(not user:find('@', 1, true), 'SSH user must not contain @')
        assert(not user:find(':', 1, true), 'SSH URI passwords are not supported')
    end

    local host
    local port
    local bracketed = false
    if host_port:sub(1, 1) == '[' then
        bracketed = true
        local close = host_port:find(']', 2, true)
        assert(close, 'unterminated IPv6 address in SSH URI')
        host = host_port:sub(2, close - 1)
        local suffix = host_port:sub(close + 1)
        if suffix ~= '' then
            assert(suffix:sub(1, 1) == ':', 'invalid SSH URI authority')
            port = suffix:sub(2)
        end
    else
        local first_colon = host_port:find(':', 1, true)
        local last_colon = host_port:match('^.*():')
        if first_colon then
            assert(first_colon == last_colon, 'IPv6 addresses in SSH URIs must be enclosed in brackets')
            host = host_port:sub(1, first_colon - 1)
            port = host_port:sub(first_colon + 1)
        else
            host = host_port
        end
    end

    host = decode(host)
    validate_component('SSH host', host)
    if not bracketed then
        assert(not host:find(':', 1, true), 'IPv6 addresses in SSH URIs must be enclosed in brackets')
    end
    assert(host:sub(1, 1) ~= '-', 'SSH host must not begin with a hyphen')
    assert(not host:find('@', 1, true), 'SSH host must not contain @')

    if port then
        assert(port:match('^%d+$'), 'SSH port must be numeric')
        port = tonumber(port)
        assert(port >= 1 and port <= 65535, 'SSH port must be between 1 and 65535')
    end

    return {
        user = user,
        host = host,
        port = port,
        target = (user and (user .. '@') or '') .. host,
    }
end

function M.parse(input)
    assert(type(input) == 'string', 'SSH destination must be a string')
    input = vim.trim(input)
    assert(input ~= '', 'SSH destination must not be empty')

    if input:sub(1, 6):lower() ~= 'ssh://' then
        validate_component('SSH destination', input)
        assert(input:sub(1, 1) ~= '-', 'SSH destination must not begin with a hyphen')
        return { target = input, display = input }
    end

    local authority, remainder = input:match('^[sS][sS][hH]://([^/%?#]+)(.*)$')
    assert(authority, 'invalid SSH URI')
    assert(remainder == '' or remainder == '/', 'remote paths, queries, and fragments are not supported')

    local result = parse_authority(authority)
    result.display = input
    return result
end

return M
