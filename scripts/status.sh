#!/bin/sh
# status.sh — action "status": each agent's connection and the model backend.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

lines=""
for a in $SUPPORTED; do
  if [ ! -d "$(agent_dir "$a")" ]; then s="not installed"
  else
    case $("state_$a") in
      connected) s="connected" ;;
      outdated) s="connected to an old runtime path, run install" ;;
      *) s="not connected" ;;
    esac
    if [ "$a" = codex ] && [ "$s" = connected ] && [ "$(codex_features_state)" != true ]; then
      s="$s, but hooks are off in config.toml [features]"
    fi
  fi
  lines="$lines$a: $s; "
done
notify "${lines}model: $(backend_state)"
