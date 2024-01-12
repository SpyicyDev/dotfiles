return {
    { 'neovim/nvim-lspconfig' },             -- Required
    { 'williamboman/mason.nvim' },
    { 'williamboman/mason-lspconfig.nvim' }, -- Optional

    -- Autocompletion
    { 'hrsh7th/nvim-cmp' },     -- Required
    { 'hrsh7th/cmp-nvim-lsp' }, -- Required
    { 'hrsh7th/cmp-nvim-lua' },
    {
        "L3MON4D3/LuaSnip",
        -- follow latest release.
        version = "v2.*", -- Replace <CurrentMajor> by the latest released major (first number of latest release)
        -- install jsregexp (optional!).
        build = "make install_jsregexp",

        dependencies = {
            "rafamadriz/friendly-snippets",
            "saadparwaiz1/cmp_luasnip",
        },
    },

    -- null-ls yay still alive!
    "nvimtools/none-ls.nvim",
    {
        "jay-babu/mason-null-ls.nvim",
        event = { "BufReadPre", "BufNewFile" },
    },

    -- icons for LSP
    "onsails/lspkind.nvim",

    -- neovim API setup
    { "folke/neodev.nvim", opts = {}, priority = 999 },

    -- better renaming
    {
        "smjonas/inc-rename.nvim",
        opts = {},
    },

    -- better code actions window
    "aznhe21/actions-preview.nvim",
}
