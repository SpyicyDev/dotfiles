return {
    -- fuzzy finder
    {
        'nvim-telescope/telescope.nvim',
        config = function()
            local builtin = require('telescope.builtin')
            vim.keymap.set('n', '<leader>ff', builtin.find_files, {})
            vim.keymap.set('n', '<leader>fh', "<cmd>lua require('telescope').extensions.recent_files.pick()<CR>", {})
            vim.keymap.set('n', '<leader>fr', '<Cmd>Telescope frecency<CR>', {})
            vim.keymap.set('n', '<leader>fg', builtin.live_grep, {})
            vim.keymap.set('n', '<leader>fm', '<cmd>Telescope harpoon marks<cr>', {})
            vim.keymap.set('n', '<leader>ft', "<cmd>TodoTelescope<CR>")
            vim.keymap.set('n', '<leader>fk', builtin.keymaps, {})
            vim.keymap.set('n', '<leader>fl', builtin.help_tags, {})

            vim.keymap.set('n', '<leader>fb', require('telescope').extensions.file_browser.file_browser)

            require('telescope').load_extension('fzf')
            require("telescope").load_extension('harpoon')
            require("telescope").load_extension "file_browser"
        end,

        dependencies = {
            "nvim-telescope/telescope-file-browser.nvim",
            -- native fzf for telescope
            { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
        },
    },
    {
        "nvim-telescope/telescope-frecency.nvim",
        config = function()
            require("telescope").load_extension "frecency"
        end,
    },
    {
        "smartpde/telescope-recent-files",
        config = function()
            require("telescope").load_extension("recent_files")
        end,
    },
}
