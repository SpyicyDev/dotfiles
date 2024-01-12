return {
    {
        "numToStr/FTerm.nvim",
        init = function()
            vim.keymap.set({ "n", "t" }, "<A-d>", function() require("FTerm").toggle() end)

            local fterm = require("FTerm")

            local lazygit = fterm:new({
                ft = 'fterm_lazygit', -- You can also override the default filetype, if you want
                cmd = "lazygit",
                dimensions = {
                    height = 0.9,
                    width = 0.9
                }
            })

            vim.keymap.set({ 'n', 't' }, '<A-g>', function()
                lazygit:toggle()
            end)
        end
    }
}
