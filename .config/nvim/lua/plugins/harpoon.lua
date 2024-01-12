return {
    -- harpoon, BLAZINGLY FAST
    {
        "theprimeagen/harpoon",
        opts = {
            tabline = true,
        },
        init = function()
            vim.keymap.set("n", "<leader>hg", require("harpoon.mark").add_file)
            vim.keymap.set("n", "<leader>hh", require("harpoon.ui").toggle_quick_menu)

            for i = 1, 8 do
                vim.keymap.set("n", "<leader>" .. i, function() require("harpoon.ui").nav_file(i) end)
            end
        end,
    },
}
