return {
    -- error corroborator
    {
        "folke/trouble.nvim",

        init = function()
            vim.keymap.set('n', "<leader>xx", "<cmd>TroubleToggle<cr>")
        end
    },
}
