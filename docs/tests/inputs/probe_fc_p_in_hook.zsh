# probe_fc_p_in_hook: investigates whether fc -p called inside a
# zshaddhistory hook has a different visibility scope than fc -p called at
# top level. This was triggered by empirical observation that upstream
# per-directory-history calls fc -p in zshaddhistory but $HISTFILE never
# appears to change from a user observation point.

setopt INTERACTIVE_COMMENTS

# Set a known starting HISTFILE.
HISTFILE=/tmp/pdh-probe-fc-p-orig.history
print -r -- "PROBE: initial HISTFILE=$HISTFILE"

# Register a zshaddhistory hook that does what upstream does: calls fc -p
# to switch to a per-dir file.
autoload -U add-zsh-hook
function _probe_addhistory() {
  print -r -- "PROBE: inside hook, before fc -p, HISTFILE=$HISTFILE"
  fc -p /tmp/pdh-probe-fc-p-newfile.history
  print -r -- "PROBE: inside hook, after fc -p, HISTFILE=$HISTFILE"
  return 0
}
add-zsh-hook zshaddhistory _probe_addhistory

# Now run a command that will trigger the hook.
print -r -- "PROBE: about to run a command that triggers zshaddhistory"
echo trigger-cmd
print -r -- "PROBE: after triggering hook, HISTFILE=$HISTFILE"

exit
