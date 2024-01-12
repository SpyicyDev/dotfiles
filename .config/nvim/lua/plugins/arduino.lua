return {
    -- Arduino support
    {
        "stevearc/vim-arduino",
        ft = "ino",
        init = function()
            vim.keymap.set("n", "<leader>aa", "<cmd>ArduinoAttach<CR>")
            vim.keymap.set("n", "<leader>av", "<cmd>ArduinoVerify<CR>G<CR>")
            vim.keymap.set("n", "<leader>au", "<cmd>ArduinoUpload<CR>G<CR>")
            vim.keymap.set("n", "<leader>aus", "<cmd>ArduinoUploadAndSerial<CR>")
            vim.keymap.set("n", "<leader>as", "<cmd>ArduinoSerial<CR>")
            vim.keymap.set("n", "<leader>ab", "<cmd>ArduinoChooseBoard<CR>")
            vim.keymap.set("n", "<leader>ap", "<cmd>ArduinoChooseProgrammer<CR>")
        end
    },
}
