return {
    {
        "Olical/conjure",
        -- [Optional] cmp-conjure for cmp
        ft = { "fennel", "lua" },
        dependencies = {
            {
                "PaterJason/cmp-conjure",
            },
        },
        config = function(_, opts)
            require("conjure.main").main()
            require("conjure.mapping")["on-filetype"]()
        end,
        init = function()
            vim.g['conjure#filetypes'] = {"fennel", "lua"}

            vim.g['conjure#client#fennel#aniseed#mapping#reset_repl'] = "rs"
            vim.g['conjure#client#lua#neovim#mapping#reset_env'] = "rs"
            -- Set configuration options here
        end,
    },
    "gpanders/nvim-parinfer",
    "tpope/vim-surround",
    --"guns/vim-sexp",
    --"tpope/vim-sexp-mappings-for-regular-people",
}
