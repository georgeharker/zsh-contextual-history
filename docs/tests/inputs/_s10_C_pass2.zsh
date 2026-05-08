PER_DIRECTORY_HISTORY_GROUP_BY=(.histroot)
PER_DIRECTORY_HISTORY_GROUP_STOPS=(/tmp/pdh-mst-monorepo/submodule)
cd /tmp/pdh-mst-monorepo/submodule/leaf
history > "$PDH_HIST_OUT"
exit
