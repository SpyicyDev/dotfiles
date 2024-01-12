return {
    -- better folds
    {
        'kevinhwang91/nvim-ufo',
        dependencies = {
            'kevinhwang91/promise-async',
        },

        config = function()
            vim.o.fillchars = [[eob: ,fold: ,foldopen:,foldsep: ,foldclose:]]
            vim.o.foldcolumn = '0' -- '0' is not bad
            vim.o.foldlevel = 99 -- Using ufo provider need a large value, feel free to decrease the value
            vim.o.foldlevelstart = 99
            vim.o.foldenable = true

            -- Using ufo provider need remap `zR` and `zM`. If Neovim is 0.6.1, remap yourself
            vim.keymap.set('n', 'zR', require('ufo').openAllFolds)
            vim.keymap.set('n', 'zM', require('ufo').closeAllFolds)

            local handler = function(virtText, lnum, endLnum, width, truncate)
                local newVirtText = {}
                local suffix = (' 󰁂 %d '):format(endLnum - lnum)
                local sufWidth = vim.fn.strdisplaywidth(suffix)
                local targetWidth = width - sufWidth
                local curWidth = 0
                for _, chunk in ipairs(virtText) do
                    local chunkText = chunk[1]
                    local chunkWidth = vim.fn.strdisplaywidth(chunkText)
                    if targetWidth > curWidth + chunkWidth then
                        table.insert(newVirtText, chunk)
                    else
                        chunkText = truncate(chunkText, targetWidth - curWidth)
                        local hlGroup = chunk[2]
                        table.insert(newVirtText, { chunkText, hlGroup })
                        chunkWidth = vim.fn.strdisplaywidth(chunkText)
                        -- str width returned from truncate() may less than 2nd argument, need padding
                        if curWidth + chunkWidth < targetWidth then
                            suffix = suffix .. (' '):rep(targetWidth - curWidth - chunkWidth)
                        end
                        break
                    end
                    curWidth = curWidth + chunkWidth
                end
                table.insert(newVirtText, { suffix, 'MoreMsg' })
                return newVirtText
            end

            local function customizeSelector(bufnr)
                local function handleFallbackException(err, providerName)
                    if type(err) == 'string' and err:match('UfoFallbackException') then
                        return require('ufo').getFolds(bufnr, providerName)
                    else
                        return require('promise').reject(err)
                    end
                end

                return require('ufo').getFolds(bufnr, 'lsp'):catch(function(err)
                    return handleFallbackException(err, 'treesitter')
                end):catch(function(err)
                    return handleFallbackException(err, 'indent')
                end)
            end

            require('ufo').setup({
                provider_selector = function(bufnr, filetype, buftype)
                    return customizeSelector
                end,

                fold_virt_text_handler = handler
            })

            vim.api.nvim_create_autocmd({ "BufWinLeave" }, {
                pattern = { "*.*" },
                desc = "save view (folds), when closing file",
                callback = function()
                    if not vim.api.nvim_win_get_config(0).zindex then
                        vim.cmd("silent! mkview")
                    end
                end
            })
            vim.api.nvim_create_autocmd({ "BufWinEnter" }, {
                pattern = { "*.*" },
                desc = "load view (folds), when opening file",
                command = "silent! loadview"
            })
        end
    },
}
