# probe_zshenv: tests whether $HOME/.zshenv leaks into our test shells.
# We add a unique sentinel to a temporary $HOME/.zshenv-shim location and
# verify whether the test shell sees it. We do NOT touch the real
# ~/.zshenv. Instead we ask the running test shell to report whether any
# user-personal config has been loaded.

setopt INTERACTIVE_COMMENTS

# Marker that something from user-level config has loaded.
# These are hallmarks of typical user configs.
print -r -- "ZSHENV_PROBE: HOME=$HOME"
print -r -- "ZSHENV_PROBE: ZDOTDIR=$ZDOTDIR"
print -r -- "ZSHENV_PROBE: ZSH=${ZSH:-(unset)}"
print -r -- "ZSHENV_PROBE: zdot_load_plugin defined: $((${+functions[zdot_load_plugin]}))"
print -r -- "ZSHENV_PROBE: zdot_use_plugin defined:  $((${+functions[zdot_use_plugin]}))"
print -r -- "ZSHENV_PROBE: zdot_simple_hook defined: $((${+functions[zdot_simple_hook]}))"
print -r -- "ZSHENV_PROBE: total functions: ${#functions}"
# Show options that were left over from anything that ran.
print -r -- "ZSHENV_PROBE: extended_glob: $([[ -o extended_glob ]] && echo yes || echo no)"
print -r -- "ZSHENV_PROBE: hist_ignore_dups: $([[ -o hist_ignore_dups ]] && echo yes || echo no)"

exit
