# My neovim config

Yo. My neovim config. Should work by cloning to .config/nvim and opening and closing a few times!

## Layout

Here's the structure of the setup:

```
.
├── README.md
├── init.lua
├── lazy-lock.json
└── lua/
    ├── keymaps.lua
    ├── lsp_setup.lua
    ├── plugins/
    │   └── ...
    └── set.lua
```

```init.lua``` is the start, keymaps, settings, and plugins get initialized/setup there. Also there is ```lsp_setup.lua```, which is setting up all the LSP plugins separately from their plugin configs because they're all too interrelated to do that.

Plugin configs are all in the ```plugins directory```!
