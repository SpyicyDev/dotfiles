return {
    -- Lua
    {
        "folke/persistence.nvim",
        event = "BufReadPre", -- this will only start session saving when an actual file was opened
        opts = {
            -- add any custom options here
        },
        init = function()
            -- restore the session for the current directory
            vim.api.nvim_set_keymap("n", "<leader>qs", [[<cmd>lua require("persistence").load()<cr>]], {})
            vim.keymap.set("n", "<leader>sl", [[<cmd>lua require("persistence").load({ last = true })<cr>]], {})
        end
    }
}
