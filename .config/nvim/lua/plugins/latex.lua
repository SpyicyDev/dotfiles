return {
    -- LaTeX yay!
    {
        "lervag/vimtex",
        init = function()
            vim.g.vimtex_view_method = 'skim'
            vim.cmd [[set conceallevel=2]]
            vim.g.vimtex_quickfix_open_on_warning = 0
        end
    },
}
