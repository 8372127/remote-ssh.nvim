local M = {}

local function config_path()
    return vim.fs.normalize(vim.fn.expand('~/.ssh/config'))
end

local function parse(lines)
    local seen = {}
    local hosts = {}
    for _, line in ipairs(lines) do
        local value = line:match('^%s*[Hh][Oo][Ss][Tt]%s*=%s*(.+)$') or line:match('^%s*[Hh][Oo][Ss][Tt]%s+(.+)$')
        if value then
            value = value:gsub('%s+#.*$', '')
            for host in value:gmatch('%S+') do
                if host:sub(1, 1) ~= '-' and not host:find('[*?!]') and not seen[host] then
                    seen[host] = true
                    hosts[#hosts + 1] = host
                end
            end
        end
    end

    table.sort(hosts)
    return hosts
end

function M.list()
    local path = config_path()
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end
    return parse(vim.fn.readfile(path))
end

M._parse = parse

function M.complete(arg_lead)
    local matches = {}
    for _, host in ipairs(M.list()) do
        local uri = 'ssh://' .. host
        if uri:sub(1, #arg_lead) == arg_lead or host:sub(1, #arg_lead) == arg_lead then
            matches[#matches + 1] = uri
        end
    end
    return matches
end

return M
