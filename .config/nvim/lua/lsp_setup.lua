-- diagnostic keybinds
vim.keymap.set('n', 'gl', '<cmd>lua vim.diagnostic.open_float()<cr>')
vim.keymap.set('n', '[d', '<cmd>lua vim.diagnostic.goto_prev()<cr>')
vim.keymap.set('n', ']d', '<cmd>lua vim.diagnostic.goto_next()<cr>')

-- diagnostic signs
vim.fn.sign_define("DiagnosticSignError",
    { text = " ", texthl = "DiagnosticSignError" })
vim.fn.sign_define("DiagnosticSignWarn",
    { text = " ", texthl = "DiagnosticSignWarn" })
vim.fn.sign_define("DiagnosticSignInfo",
    { text = " ", texthl = "DiagnosticSignInfo" })
vim.fn.sign_define("DiagnosticSignHint",
    { text = "", texthl = "DiagnosticSignHint" })

-- LSP keybinds, sets when LSP attaches
vim.api.nvim_create_autocmd('LspAttach', {
    desc = 'LSP actions',
    callback = function(event)
        local opts = { buffer = event.buf }

        vim.keymap.set('n', 'K', '<cmd>lua vim.lsp.buf.hover()<cr>', opts)
        vim.keymap.set('n', 'gd', '<cmd>lua vim.lsp.buf.definition()<cr>', opts)
        vim.keymap.set('n', 'gD', '<cmd>lua vim.lsp.buf.declaration()<cr>', opts)
        vim.keymap.set('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<cr>', opts)
        vim.keymap.set('n', 'go', '<cmd>lua vim.lsp.buf.type_definition()<cr>', opts)
        vim.keymap.set('n', 'gr', '<cmd>lua vim.lsp.buf.references()<cr>', opts)
        vim.keymap.set('n', 'gh', '<cmd>lua vim.lsp.buf.signature_help()<cr>', opts)

        vim.keymap.set('n', 'gn', ':IncRename ', opts)
        vim.keymap.set({ 'n', 'x' }, 'gf', '<cmd>lua vim.lsp.buf.format({async = true})<cr>', opts)
        vim.keymap.set('n', 'gc', require("actions-preview").code_actions, opts)
    end
})

-- setup each LSP in mason
local lsp_capabilities = require('cmp_nvim_lsp').default_capabilities()
lsp_capabilities.textDocument.foldingRange = {
    dynamicRegistration = false,
    lineFoldingOnly = true
}

local on_attach = function(client, bufnr)
    if client.server_capabilities["documentSymbolProvider"] then
        require("nvim-navic").attach(client, bufnr)
    end
end

local default_setup = function(server)
    require('lspconfig')[server].setup({
        capabilities = lsp_capabilities,
        on_attach = on_attach,
    })
end

require('mason').setup({})
require('mason-lspconfig').setup({
    ensure_installed = {},
    handlers = {
        default_setup,
    },
})

-- specific config for julia
require 'lspconfig'.julials.setup {
    on_new_config = function(new_config, _)
        local julia = vim.fn.expand("~/.julia/environments/nvim-lspconfig/bin/julia")
        if require 'lspconfig'.util.path.is_file(julia) then
            new_config.cmd[1] = julia
        end
    end
}

-- null-ls setup
require("mason-null-ls").setup({
    ensure_installed = {},
    automatic_installation = false,
    handlers = {},
})
require("null-ls").setup({
    sources = {}
})

-- snippets i think?
require("luasnip.loaders.from_vscode").lazy_load()

-- cmp setup
local cmp = require('cmp')
local luasnip = require('luasnip')

local has_words_before = function()
    unpack = unpack or table.unpack
    local line, col = unpack(vim.api.nvim_win_get_cursor(0))
    return col ~= 0 and vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match("%s") == nil
end


cmp.setup({
    sources = cmp.config.sources({
        { name = 'path' },
        { name = 'copilot' },
        { name = 'nvim_lsp' },
        { name = 'nvim_lua' },
        { name = 'conjure' },
        { name = 'nvlime' },
        { name = 'buffer',  keyword_length = 3 },
        { name = 'luasnip', keyword_length = 2 },
    }),
    ---@diagnostic disable-next-line: missing-fields
    formatting = {
        fields = { 'abbr', 'kind', 'menu' },
        format = require('lspkind').cmp_format({
            menu = {
                nvim_lsp = "[LSP]",
                conjure = "[Conjure]",
            },
            mode = 'symbol_text',
            maxwidth = 50,         -- prevent the popup from showing more than provided characters
            ellipsis_char = '...', -- when popup menu exceed maxwidth, the truncated part would show ellipsis_char instead
            symbol_map = { Copilot = "" },
        })
    },
    mapping = cmp.mapping.preset.insert({
        ['<CR>'] = cmp.mapping.confirm({
            behavior = cmp.ConfirmBehavior.replace,
            select = false
        }),
        ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
                cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
                luasnip.expand_or_jump()
            elseif has_words_before() then
                cmp.complete()
            else
                fallback()
            end
        end, { "i", "s" }),


        ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
                cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
                luasnip.jump(-1)
            else
                fallback()
            end
        end, { "i", "s" }),
    }),
    window = {
        completion = cmp.config.window.bordered(),
        documentation = cmp.config.window.bordered(),
    },
    snippet = {
        expand = function(args)
            require('luasnip').lsp_expand(args.body)
        end,
    },
})
