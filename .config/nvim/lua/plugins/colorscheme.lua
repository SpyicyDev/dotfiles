return {
    {
        "catppuccin/nvim",
        name = "catppuccin",
        priority = 1000,
        opts = {
            integrations = {
                noice = true,
                barbecue = {
                    dim_dirname = true, -- directory name is dimmed by default
                    bold_basename = true,
                    dim_context = false,
                    alt_background = false,
                },
                harpoon = true,
                gitsigns = true,
                mason = true,
                cmp = true,
                native_lsp = {
                    enabled = true,
                    virtual_text = {
                        errors = { "italic" },
                        hints = { "italic" },
                        warnings = { "italic" },
                        information = { "italic" },
                    },
                    underlines = {
                        errors = { "underline" },
                        hints = { "underline" },
                        warnings = { "underline" },
                        information = { "underline" },
                    },
                    inlay_hints = {
                        background = true,
                    },
                },
                notify = true,
                lsp_trouble = true,
                leap = true,
            },
        },
    },
}
