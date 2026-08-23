show_stash() {
  tmux_batch_setup_status_module "stash"
  run_tmux_batch_commands

  local color thm_bg thm_fg thm_gray left_sep

  color=$(get_tmux_batch_option "@catppuccin_stash_color" "#f9e2af")

  thm_bg=$(tmux show-option -gqv "@thm_bg" 2>/dev/null)
  : "${thm_bg:=#313244}"
  thm_fg=$(tmux show-option -gqv "@thm_fg" 2>/dev/null)
  : "${thm_fg:=#cdd6f4}"
  thm_gray=$(tmux show-option -gqv "@thm_gray" 2>/dev/null)
  : "${thm_gray:=#313244}"
  left_sep=$(tmux show-option -gqv "@catppuccin_status_left_separator" 2>/dev/null)
  : "${left_sep:=█}"

  # Renders NOTHING unless something is parked. A hidden tab is the only thing
  # this module exists to tell you about, so at zero it should not occupy a
  # single cell — the whole segment, separators included, sits inside the
  # conditional rather than showing an empty pill.
  #
  # The count comes from the @stash_count option, which stash.sh writes when it
  # changes. Deliberately not a #() command: that would re-fork on every status
  # redraw for a value that is almost always zero.
  # Commas inside the #[...] style specs are escaped as `#,`. They have to be:
  # tmux splits a #{?cond,then,else} on commas, so an unescaped `#[fg=x,bg=y]`
  # inside a branch ends the branch at `fg=x` and the rest of the segment is
  # silently dropped — the module renders nothing at all, with no error.
  local seg="#[fg=${color}#,bg=${thm_bg}#,nobold#,nounderscore#,noitalics]${left_sep}#[fg=${thm_bg}#,bg=${color}#,nobold#,nounderscore#,noitalics] #[fg=${thm_fg}#,bg=${thm_gray}] 󰒲 #{E:@stash_count} "

  echo "#{?#{||:#{==:#{E:@stash_count},0},#{==:#{E:@stash_count},}},,${seg}}"
}
