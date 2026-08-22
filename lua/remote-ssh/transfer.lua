local M = {}

local allowed_assets = {
    ['nvim-linux-x86_64.tar.gz'] = true,
    ['nvim-linux-arm64.tar.gz'] = true,
    ['nvim-macos-x86_64.tar.gz'] = true,
    ['nvim-macos-arm64.tar.gz'] = true,
}

local function unlink(path)
    if path then
        vim.uv.fs_unlink(path)
    end
end

local function close_file(handle)
    if handle.file then
        vim.uv.fs_close(handle.file)
        handle.file = nil
    end
end

local function fail(handle, message)
    if handle.cancelled or handle.finished then
        return
    end
    handle.finished = true
    close_file(handle)
    unlink(handle.partial_path)
    handle.callbacks.on_error(message)
end

local function stream(handle, path)
    handle.callbacks.on_status('Uploading ' .. handle.asset .. ' to the remote host')
    vim.uv.fs_open(path, 'r', tonumber('0400', 8), function(open_error, file)
        if open_error then
            fail(handle, 'Unable to open the local Neovim archive: ' .. open_error)
            return
        end
        if handle.cancelled then
            vim.uv.fs_close(file)
            return
        end

        handle.file = file
        local offset = 0
        local function read_next()
            vim.uv.fs_read(file, 256 * 1024, offset, function(read_error, data)
                if handle.cancelled then
                    close_file(handle)
                    return
                end
                if read_error then
                    fail(handle, 'Unable to read the local Neovim archive: ' .. read_error)
                    return
                end
                if not data or data == '' then
                    close_file(handle)
                    local ok, write_error = pcall(handle.process.write, handle.process, nil)
                    if not ok then
                        fail(handle, 'Unable to finish the Neovim archive upload: ' .. tostring(write_error))
                        return
                    end
                    handle.finished = true
                    handle.callbacks.on_complete()
                    return
                end

                local ok, write_error = pcall(handle.process.write, handle.process, data)
                if not ok then
                    fail(handle, 'Unable to upload the Neovim archive: ' .. tostring(write_error))
                    return
                end
                offset = offset + #data
                read_next()
            end)
        end
        read_next()
    end)
end

function M.provide(process, version, asset, session_token, curl_command, callbacks)
    assert(allowed_assets[asset], 'unsupported Neovim release asset: ' .. tostring(asset))

    local handle = {
        asset = asset,
        callbacks = callbacks,
        process = process,
    }
    local directory = vim.fs.joinpath(vim.fn.stdpath('cache'), 'remote-ssh', 'downloads', 'v' .. version)
    vim.fn.mkdir(directory, 'p', tonumber('0700', 8))
    local archive_path = vim.fs.joinpath(directory, asset)
    handle.archive_path = archive_path
    local stat = vim.uv.fs_stat(archive_path)
    if stat and stat.type == 'file' and stat.size > 0 then
        stream(handle, archive_path)
        return handle
    end

    if vim.fn.executable(curl_command) ~= 1 then
        fail(handle, curl_command .. ' is required locally to download remote Neovim')
        return handle
    end

    local partial_path = archive_path .. '.partial-' .. session_token
    unlink(partial_path)
    handle.partial_path = partial_path
    callbacks.on_status('Downloading ' .. asset .. ' on the local machine')
    handle.download = vim.system({
        curl_command,
        '--disable',
        '--fail',
        '--location',
        '--proto',
        '=https',
        '--proto-redir',
        '=https',
        '--silent',
        '--show-error',
        'https://github.com/neovim/neovim/releases/download/v' .. version .. '/' .. asset,
        '--output',
        partial_path,
    }, { text = true }, function(result)
        handle.download = nil
        if handle.cancelled then
            unlink(partial_path)
            return
        end
        if result.code ~= 0 then
            fail(handle, 'Local Neovim download failed: ' .. vim.trim(result.stderr or ('curl exit ' .. result.code)))
            return
        end

        local renamed, rename_error = vim.uv.fs_rename(partial_path, archive_path)
        if not renamed then
            local existing = vim.uv.fs_stat(archive_path)
            if not existing or existing.type ~= 'file' or existing.size == 0 then
                fail(handle, 'Unable to cache the local Neovim archive: ' .. tostring(rename_error))
                return
            end
            unlink(partial_path)
        end
        handle.partial_path = nil
        stream(handle, archive_path)
    end)
    return handle
end

function M.cancel(handle)
    if not handle or handle.cancelled then
        return
    end
    handle.cancelled = true
    if handle.download then
        pcall(handle.download.kill, handle.download, 15)
        handle.download = nil
    end
    close_file(handle)
    unlink(handle.partial_path)
end

function M.invalidate(handle)
    if handle and handle.finished then
        unlink(handle.archive_path)
    end
end

function M.is_allowed(asset)
    return allowed_assets[asset] == true
end

return M
