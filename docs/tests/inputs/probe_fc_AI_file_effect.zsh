# probe_fc_AI_file_effect: investigates what fc -AI does to the on-disk
# file when called against a shared HISTFILE under SHARE_HISTORY. We
# track inode, size, mtime, and content before and after the fc -AI call.

setopt INTERACTIVE_COMMENTS
setopt SHARE_HISTORY

# Use a known temp histfile to make tracking unambiguous.
HISTFILE=/tmp/pdh-fc-AI-probe.history
rm -f "$HISTFILE"
HISTSIZE=10000
SAVEHIST=10000

# Baseline state.
print -r -- "PROBE: HISTFILE=$HISTFILE"
print -r -- "PROBE: --- baseline (file does not exist yet) ---"
ls -li "$HISTFILE" 2>&1 || true

# Trigger SHARE_HISTORY's incremental writes by running commands.
print -r -- "PROBE: --- running 3 commands to populate via SHARE_HISTORY ---"
echo c1
echo c2
echo c3

# Snapshot the file after SHARE_HISTORY's writes.
print -r -- "PROBE: --- after SHARE_HISTORY incremental writes ---"
ls -li "$HISTFILE"
print -r -- "PROBE: file size: $(wc -c <"$HISTFILE")"
print -r -- "PROBE: --- file contents ---"
cat "$HISTFILE"

# Now call fc -AI explicitly.
print -r -- "PROBE: --- calling fc -AI ---"
fc -AI "$HISTFILE"

# Snapshot again.
print -r -- "PROBE: --- after fc -AI ---"
ls -li "$HISTFILE"
print -r -- "PROBE: file size: $(wc -c <"$HISTFILE")"
print -r -- "PROBE: --- file contents ---"
cat "$HISTFILE"

exit
