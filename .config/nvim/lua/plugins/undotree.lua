return {
    -- undo visualizer
    {
        "mbbill/undotree",
        init = function()
            vim.keymap.set("n", "<leader>u", vim.cmd.UndotreeToggle)
            vim.g.undotree_SetFocusWhenToggle = 1
            vim.g.undotree_WindowLayout = 2
        end
    },
}
