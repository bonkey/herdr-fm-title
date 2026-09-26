#!/bin/sh
# install.sh [--sync] — action "install": deploys the runtime and connects every supported agent
# whose config directory exists (limited by `agents = [...]` in config.toml when set).
# --sync is the startup hook: it redeploys and refreshes only the agents already connected, so
# it never connects an agent on its own and stays quiet (output goes to the plugin log).
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

if [ "${1:-}" = --sync ]; then
  agents=$(cat "$agents_file" 2>/dev/null)
  [ -n "$agents" ] || exit 0
else
  agents=$(selected_agents)
  [ -n "$agents" ] || { notify "No supported agent found (Claude Code, Codex, OpenCode)."; exit 0; }
fi

deploy_runtime || { notify "Could not deploy the runtime to $data_dir."; exit 1; }

connected="" failed=""
for a in $agents; do
  if "register_$a"; then connected="$connected $a"; else failed="$failed $a"; fi
done

if [ "${1:-}" = --sync ]; then
  echo "synced:${connected:- none}${failed:+; failed:$failed}"
  exit 0
fi

mkdir -p "$state_dir" && printf '%s\n' $connected >"$agents_file"
msg="Connected:${connected:- none}."
[ -z "$failed" ] || msg="$msg Failed:$failed (see the plugin log)."
case " $connected " in *" codex "*) msg="$msg Approve the new hooks once in Codex with /hooks." ;; esac
case " $connected " in *" claude "* | *" codex "*) msg="$msg New sessions pick it up; running ones keep their hooks." ;; esac
notify "$msg Model: $(backend_state)."
[ -z "$failed" ]
