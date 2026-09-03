local M = {}

local allowed_extensions = {
    aac = true,
    apng = true,
    avi = true,
    bmp = true,
    flac = true,
    gif = true,
    jpeg = true,
    jpg = true,
    m4a = true,
    m4v = true,
    mkv = true,
    mov = true,
    mp3 = true,
    mp4 = true,
    oga = true,
    ogg = true,
    ogv = true,
    pdf = true,
    png = true,
    wav = true,
    webm = true,
    webp = true,
}

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = 'remote-ssh' })
end

local function safe_name(path)
    local name = tostring(path or ''):gsub('\\', '/'):match('([^/]+)$') or 'preview'
    name = name:gsub('[%z\1-\31\127/\\:*?"<>|]', '_')
    if name == '' or name == '.' or name == '..' then
        name = 'preview'
    end
    return name:sub(1, 160)
end

local function extension(path)
    return tostring(path or ''):match('%.([^.\\/]+)$')
end

local function cache_key(request)
    return vim.fn.sha256(table.concat({
        tostring(request.path),
        tostring(request.size),
        tostring(request.mtime_sec or 0),
        tostring(request.mtime_nsec or 0),
    }, '\n'))
end

local function preview_directory(session)
    local display = session.destination and session.destination.display or 'unknown'
    return vim.fs.joinpath(vim.fn.stdpath('cache'), 'remote-ssh', 'previews', vim.fn.sha256(display))
end

local function notify_remote_decision(session, id, cached)
    if not session.rpc_channel then
        return
    end
    pcall(vim.rpcnotify, session.rpc_channel, 'nvim_call_function', 'RemoteSSHPreviewDecision', { id, cached == true })
end

local function close(handle)
    if handle and handle.file then
        vim.uv.fs_close(handle.file)
        handle.file = nil
    end
end

local function unlink(path)
    if path then
        vim.uv.fs_unlink(path)
    end
end

local function fail(session, id, message)
    local handle = session.previews and session.previews[id]
    if handle then
        close(handle)
        if not handle.cached then
            unlink(handle.local_path)
        end
        session.previews[id] = nil
    end
    notify(message, vim.log.levels.ERROR)
end

local function write_all(file, bytes, offset)
    local written_total = 0
    while written_total < #bytes do
        local written, write_error = vim.uv.fs_write(file, bytes:sub(written_total + 1), offset + written_total)
        if not written then
            return nil, write_error
        end
        if written <= 0 then
            return nil, 'short write'
        end
        written_total = written_total + written
    end
    return written_total
end

function M.start(session, payload)
    local options = session.preview_options
    if not options or not options.enabled then
        notify('Remote preview is disabled', vim.log.levels.WARN)
        return
    end

    local ok, request = pcall(vim.json.decode, payload)
    if not ok or type(request) ~= 'table' then
        notify('Remote preview request was malformed', vim.log.levels.ERROR)
        return
    end

    local id = request.id
    local path = request.path
    local size = request.size
    if type(id) ~= 'string' or not id:match('^[%w._-]+$') or type(path) ~= 'string' or type(size) ~= 'number' then
        notify('Remote preview request was invalid', vim.log.levels.ERROR)
        return
    end
    if size < 0 or size % 1 ~= 0 then
        notify('Remote preview reported an invalid file size', vim.log.levels.ERROR)
        return
    end
    if size > options.max_size then
        notify(('Remote preview is too large: %d bytes'):format(size), vim.log.levels.ERROR)
        return
    end

    local ext = extension(path)
    if not ext or not allowed_extensions[ext:lower()] then
        notify('Remote preview is not enabled for this file type', vim.log.levels.WARN)
        return
    end

    session.previews = session.previews or {}
    if session.previews[id] then
        fail(session, id, 'Remote preview id was reused')
        return
    end

    local directory = preview_directory(session)
    vim.fn.mkdir(directory, 'p', tonumber('0700', 8))
    local local_path = vim.fs.joinpath(directory, cache_key(request) .. '-' .. safe_name(path))
    local cached = vim.uv.fs_stat(local_path)
    if cached and cached.type == 'file' and cached.size == size then
        session.previews[id] = {
            cached = true,
            local_path = local_path,
        }
        notify_remote_decision(session, id, true)
        local ok, result = pcall(vim.ui.open, local_path)
        if not ok then
            fail(session, id, 'Unable to open cached preview file: ' .. tostring(result))
        end
    end
    if session.previews[id] then
        return
    end

    unlink(local_path)

    local file, open_error = vim.uv.fs_open(local_path, 'w', tonumber('0600', 8))
    if not file then
        notify('Unable to create local preview file: ' .. tostring(open_error), vim.log.levels.ERROR)
        return
    end

    session.previews[id] = {
        file = file,
        local_path = local_path,
        path = path,
        size = size,
        written = 0,
    }
    notify_remote_decision(session, id, false)
end

function M.data(session, id, bytes)
    local handle = session.previews and session.previews[id]
    if not handle then
        return
    end
    if handle.cached then
        return
    end

    if type(bytes) ~= 'string' then
        fail(session, id, 'Remote preview sent invalid data')
        return
    end
    if handle.written + #bytes > handle.size then
        fail(session, id, 'Remote preview exceeded the reported file size')
        return
    end

    local written, write_error = write_all(handle.file, bytes, handle.written)
    if not written then
        fail(session, id, 'Unable to write local preview file: ' .. tostring(write_error))
        return
    end
    handle.written = handle.written + written
end

function M.finish(session, id)
    local handle = session.previews and session.previews[id]
    if not handle then
        return
    end
    if handle.cached then
        session.previews[id] = nil
        return
    end

    close(handle)
    session.previews[id] = nil
    if handle.written ~= handle.size then
        unlink(handle.local_path)
        notify('Remote preview ended before the full file was received', vim.log.levels.ERROR)
        return
    end

    local ok, result = pcall(vim.ui.open, handle.local_path)
    if not ok then
        notify('Unable to open local preview file: ' .. tostring(result), vim.log.levels.ERROR)
    end
end

function M.remote_error(session, payload)
    local ok, request = pcall(vim.json.decode, payload)
    if ok and type(request) == 'table' and type(request.id) == 'string' then
        fail(session, request.id, tostring(request.message or 'Remote preview failed'))
    else
        notify('Remote preview failed', vim.log.levels.ERROR)
    end
end

function M.cancel_all(session)
    if not session.previews then
        return
    end
    for id, handle in pairs(session.previews) do
        close(handle)
        if not handle.cached then
            unlink(handle.local_path)
        end
        session.previews[id] = nil
    end
end

return M
