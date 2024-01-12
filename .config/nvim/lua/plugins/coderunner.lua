return {
    -- code running
    {
        "CRAG666/code_runner.nvim",
        cond = false,
        opts = {
            mode = "float",
            startinsert = true,
            float = {
                border = "rounded",
                x = 1,
                width = 0.4,
                y = 0.1,
                height = 1,
            },

            filetype = {
                python = [[
        if [ -f $dir/../pyproject.toml ] || [ -f $dir/pyproject.toml ]; then
            poetry run python3 $file
        else
            python3 $file
        fi
        ]],
                clojure = "lein run",
                go = "go run .",
                rust = "cargo run",
            },
        },

        init = function()
            vim.keymap.set("n", "<leader>rr", ":RunCode<CR>", { noremap = true, silent = false })
            vim.keymap.set('n', '<leader>rc', function()
                if vim.api.nvim_win_get_config(0).zindex then
                    return ":q<CR>"
                else
                    return ""
                end
            end, { expr = true, noremap = true, silent = false })
        end,

        event = "BufReadPre",
    }, --]]
}
