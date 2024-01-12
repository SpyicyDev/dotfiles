return {
    -- highlighted todo comments, looks nice
    {
        "folke/todo-comments.nvim",
        dependencies = { "nvim-lua/plenary.nvim" },
        opts = {},
        init = function ()
            vim.keymap.set("n", "<leader>tt", "<cmd>TodoTrouble<cr>")
        end
    },
}
