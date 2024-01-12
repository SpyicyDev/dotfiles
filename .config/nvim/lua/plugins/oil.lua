return {
    -- better netrw
    {
        'stevearc/oil.nvim',
        opts = {
            keymaps = {
                ["<C-a>"] = "actions.select_vsplit"
            }
        },
        init = function()
            vim.keymap.set("n", "<leader>pv", "<cmd>Oil --float .<cr>")
        end,
        -- Optional dependencies
        dependencies = { "nvim-tree/nvim-web-devicons" },
    },
}
