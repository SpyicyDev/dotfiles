# ~/.config/nushell/config.nu — the nu data tab.
#
# Deliberately NOT a chezmoi template: nu closures are full of braces and a
# stray `{{` would be eaten by Go templating. env.nu is a .tmpl because it
# needs .homebrew_prefix; this file needs no substitution.
#
# Ordering note: every $env.config assignment below must happen BEFORE the
# `source` block at the bottom. zoxide and atuin both `upsert` onto
# $env.config — atuin appends its ctrl-r and up-arrow keybindings to
# $env.config.keybindings — so assigning keybindings after sourcing them
# would silently clobber atuin's history search.

# ── Shell behaviour ───────────────────────────────────────────────────────
$env.config.show_banner = false
$env.config.edit_mode = "vi"
$env.config.buffer_editor = "nvim"
$env.config.rm.always_trash = false

$env.config.cursor_shape.vi_insert = "line"
$env.config.cursor_shape.vi_normal = "block"

# nu keeps its own history even though atuin is the real store. sqlite over
# plaintext so concurrent nu tabs don't truncate each other.
$env.config.history.file_format = "sqlite"
$env.config.history.max_size = 100_000
$env.config.history.isolation = false

# Field-wise, not a wholesale record replace: carapace's init upserts
# completions.external and a full replace here would drop its defaults.
$env.config.completions.case_sensitive = false
$env.config.completions.quick = true
$env.config.completions.partial = true
$env.config.completions.algorithm = "fuzzy"

# ── Keybindings ───────────────────────────────────────────────────────────
# Preserves the tab/shift-tab inversion from .zshrc:69-71 —
#   tab       = accept the autosuggestion   (zsh: autosuggest-accept)
#   shift-tab = open the completion menu    (zsh: complete-word)
# `until` walks the list and stops at the first event that fires, so tab still
# falls through to completion when there is no suggestion to accept.
$env.config.keybindings = [
    {
        name: accept_autosuggestion
        modifier: none
        keycode: tab
        mode: [emacs vi_normal vi_insert]
        event: {
            until: [
                { send: historyhintcomplete }
                { send: menu name: completion_menu }
                { send: menunext }
            ]
        }
    }
    {
        name: completion_menu
        modifier: shift
        keycode: backtab
        mode: [emacs vi_normal vi_insert]
        event: {
            until: [
                { send: menu name: completion_menu }
                { send: menuprevious }
            ]
        }
    }
]

# ── Catppuccin Mocha ──────────────────────────────────────────────────────
# Matches wezterm, tmux, bat, gitui and the zsh fast-syntax-highlighting theme.
$env.config.color_config = {
    separator: "#6c7086"
    leading_trailing_space_bg: { attr: "n" }
    header: { fg: "#a6e3a1" attr: "b" }
    empty: "#89b4fa"
    bool: "#89dceb"
    int: "#cdd6f4"
    filesize: "#94e2d5"
    duration: "#cdd6f4"
    date: "#f5c2e7"
    range: "#cdd6f4"
    float: "#cdd6f4"
    string: "#cdd6f4"
    nothing: "#f38ba8"
    binary: "#cba6f7"
    cell-path: "#cdd6f4"
    row_index: { fg: "#a6e3a1" attr: "b" }
    record: "#cdd6f4"
    list: "#cdd6f4"
    hints: "#585b70"
    search_result: { fg: "#f38ba8" bg: "#cdd6f4" }

    shape_binary: { fg: "#cba6f7" attr: "b" }
    shape_bool: "#89dceb"
    shape_int: { fg: "#cba6f7" attr: "b" }
    shape_float: { fg: "#cba6f7" attr: "b" }
    shape_range: { fg: "#f9e2af" attr: "b" }
    shape_internalcall: { fg: "#94e2d5" attr: "b" }
    shape_external: "#94e2d5"
    shape_externalarg: { fg: "#a6e3a1" attr: "b" }
    shape_literal: "#89b4fa"
    shape_operator: "#f9e2af"
    shape_signature: { fg: "#a6e3a1" attr: "b" }
    shape_string: "#a6e3a1"
    shape_string_interpolation: { fg: "#94e2d5" attr: "b" }
    shape_datetime: { fg: "#94e2d5" attr: "b" }
    shape_list: { fg: "#94e2d5" attr: "b" }
    shape_table: { fg: "#89b4fa" attr: "b" }
    shape_record: { fg: "#94e2d5" attr: "b" }
    shape_block: { fg: "#89b4fa" attr: "b" }
    shape_filepath: "#94e2d5"
    shape_globpattern: { fg: "#94e2d5" attr: "b" }
    shape_variable: "#cba6f7"
    shape_flag: { fg: "#89b4fa" attr: "b" }
    shape_custom: { attr: "b" }
    shape_nothing: "#89dceb"
    shape_garbage: { fg: "#cdd6f4" bg: "#f38ba8" attr: "b" }
}

# ── Aliases ───────────────────────────────────────────────────────────────
# NOTE: `ls` is deliberately NOT aliased to eza here, unlike .zshrc:157.
# nu's built-in `ls` returns a *table* — `ls | where size > 10mb | sort-by
# modified` is the entire reason this tab exists. Aliasing it away would throw
# out the best thing about the shell. `eza` is still on PATH by name.
#
# `cd` is not aliased either: zoxide's init is generated with `--cmd cd`, so
# `cd` already IS `z`, sharing the same database as the zsh tabs.

# git — the 15 highest-value omz aliases, semantics matched exactly to
# ohmyzsh/plugins/git so muscle memory transfers without surprises.
alias g = git
alias gst = git status
alias ga = git add
alias gaa = git add --all
alias gc = git commit --verbose
alias gcmsg = git commit --message
alias gco = git checkout
alias gcb = git checkout -b
alias gd = git diff
alias gdca = git diff --cached
alias gp = git push
alias gl = git pull
alias gb = git branch
alias glo = git log --oneline --decorate

# omz's `gcm` is `git checkout $(git_main_branch)`, not a static alias — it
# probes for the repo's actual trunk. Same probe order as upstream.
def git-main-branch [] {
    [main trunk mainline default stable master]
    | where {|b|
        (do -i { ^git show-ref --verify --quiet $"refs/heads/($b)" } | complete).exit_code == 0
    }
    | get 0?
    | default "main"
}

def --wrapped gcm [...rest] { ^git checkout (git-main-branch) ...$rest }

# ── Functions ─────────────────────────────────────────────────────────────

# .zshrc:149 — clear, then scroll the prompt to the bottom of the viewport.
def c [] {
    clear
    print -n (1..100 | each { "\n" } | str join)
}

def --env hh [] {
    cd $nu.home-dir
    c
}

# .zshrc:174 — yazi, inheriting the directory you quit in.
def --env y [...args] {
    let tmp = (mktemp -t "yazi-cwd.XXXXXX")
    ^yazi ...$args --cwd-file $tmp
    let cwd = (open $tmp | str trim)
    if ($cwd | is-not-empty) and $cwd != $env.PWD and ($cwd | path exists) {
        cd $cwd
    }
    rm -f $tmp
}

# .zshrc:166 — pass --port 0 unless a positional arg was given.
def --wrapped opencode [...args] {
    let has_positional = ($args | any {|a| not ($a | str starts-with "-") })
    if $has_positional {
        ^opencode ...$args
    } else {
        ^opencode --port 0 ...$args
    }
}

def --wrapped oc [...args] { opencode ...$args }
def --wrapped occ [...args] { opencode -c ...$args }

# Nu-native addition (not a zsh port — delete if unwanted). The single most
# common jq pattern in this history is yabai introspection:
#   yabai -m query --spaces | jq 'map({index,label,display,focused:."has-focus"})'
# which becomes:
#   ybq spaces | select index label display has-focus
def ybq [domain: string@"nu-complete ybq-domain" = "spaces"] {
    ^yabai -m query $"--($domain)" | from json
}

def "nu-complete ybq-domain" [] { [spaces windows displays] }

# ── Tool inits ────────────────────────────────────────────────────────────
# Generated and cached by env.nu, which runs as an earlier parse/eval unit.
# `source` resolves at PARSE time, so these files must already exist — they
# always do, because env.nu writes an empty placeholder when a tool is absent.
# Keep this block last: see the ordering note at the top of the file.
source ~/.cache/nu/starship.nu
source ~/.cache/nu/zoxide.nu
source ~/.cache/nu/atuin.nu
source ~/.cache/nu/carapace.nu
