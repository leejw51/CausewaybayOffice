# Session-only integration. No user startup files are modified.
case "${SHELL##*/}" in
bash)
  exec "$SHELL" --rcfile /dev/fd/3 -i 3<<'CBO_BASH_RC'
if [ -r /etc/profile ]; then . /etc/profile; fi
if [ -r "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
elif [ -r "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
elif [ -r "$HOME/.profile" ]; then . "$HOME/.profile"
elif [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"
fi
__cbo_cwd() {
  local p="$PWD"
  p=${p//%/%25}; p=${p//$'\033'/%1B}; p=${p//$'\007'/%07}
  p=${p//$'\n'/%0A}; p=${p//$'\r'/%0D}
  printf '\033]7;file://localhost%s\007' "$p"
}
if declare -p PROMPT_COMMAND 2>/dev/null | command grep -q 'declare -a'; then
  PROMPT_COMMAND+=(__cbo_cwd)
else
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__cbo_cwd"
fi
CBO_BASH_RC
  ;;
zsh)
  cbo_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/cbo-shell.XXXXXXXX") || exec "$SHELL" -il
  export CBO_ZDOTDIR="${ZDOTDIR-$HOME}" CBO_RC_DIR="$cbo_dir"
  cat > "$cbo_dir/.zshenv" <<'CBO_ZENV'
ZDOTDIR="$CBO_ZDOTDIR"
[[ -r "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
CBO_ZDOTDIR="$ZDOTDIR"
ZDOTDIR="$CBO_RC_DIR"
CBO_ZENV
  cat > "$cbo_dir/.zprofile" <<'CBO_ZPROFILE'
ZDOTDIR="$CBO_ZDOTDIR"
[[ -r "$ZDOTDIR/.zprofile" ]] && source "$ZDOTDIR/.zprofile"
CBO_ZDOTDIR="$ZDOTDIR"
ZDOTDIR="$CBO_RC_DIR"
CBO_ZPROFILE
  cat > "$cbo_dir/.zshrc" <<'CBO_ZRC'
ZDOTDIR="$CBO_ZDOTDIR"
[[ -r "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
function __cbo_cwd() {
  local p="$PWD"
  p=${p//\%/%25}; p=${p//$'\033'/%1B}; p=${p//$'\007'/%07}
  p=${p//$'\n'/%0A}; p=${p//$'\r'/%0D}
  printf '\033]7;file://localhost%s\007' "$p"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd __cbo_cwd
# Only our three generated files; never a recursive delete of a variable path.
command rm -f -- "$CBO_RC_DIR/.zshenv" "$CBO_RC_DIR/.zprofile" "$CBO_RC_DIR/.zshrc"
command rmdir -- "$CBO_RC_DIR"
unset CBO_RC_DIR CBO_ZDOTDIR
CBO_ZRC
  ZDOTDIR="$cbo_dir" exec "$SHELL" -il
  ;;
fish)
  exec "$SHELL" -il -C 'function __cbo_cwd --on-event fish_prompt; printf "\e]7;file://localhost%s\a" (string replace -ai "%2F" "/" -- (string escape --style=url -- $PWD)); end'
  ;;
*) exec "${SHELL:-/bin/sh}" -il ;;
esac
