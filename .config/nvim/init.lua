-- import keymaps and general settings
require('keymaps')
require('set')

-- bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
    vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable", -- latest stable release
        lazypath,
    })
end
vim.opt.rtp:prepend(lazypath)
require("lazy").setup("plugins", {
    dev = {
        path = "~/projects/nvim_dev",
    },
})

vim.loader.enable()

-- set colorscheme
vim.cmd.colorscheme "catppuccin-mocha"

-- initialize LSP
require('lsp_setup')
