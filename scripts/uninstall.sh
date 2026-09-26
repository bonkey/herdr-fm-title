#!/bin/sh
# uninstall.sh — action "uninstall": removes exactly what install added from every supported
# agent, then the deployed runtime. Config backups (*.bak-herdr-fm-title), the Swift binary cache,
# session markers and a Codex `[features] hooks` setting stay.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

removed="" failed=""
for a in $SUPPORTED; do
  [ "$("state_$a")" = no ] && continue
  if "unregister_$a"; then removed="$removed $a"; else failed="$failed $a"; fi
done
rm -rf "$data_dir"
rm -f "$agents_file"

msg="Disconnected:${removed:- none}."
[ -z "$failed" ] || msg="$msg Failed:$failed (see the plugin log)."
notify "$msg"
[ -z "$failed" ]
