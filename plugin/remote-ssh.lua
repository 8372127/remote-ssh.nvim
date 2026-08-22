if vim.g.loaded_remote_ssh == 1 then
    return
end
vim.g.loaded_remote_ssh = 1

require('remote-ssh')._load()
