# lib.sh — shared by install.sh, uninstall.sh and status.sh (sourced, not executed).
# Agents run a copy of runtime/ at $data_dir, a stable path outside herdr's plugin checkout.
# Every agent config edit is idempotent: our entries are found by $MARK, others are preserved.
# shellcheck disable=SC2034 # its variables are used by the scripts that source it
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
plugin_root=$(cd "$(dirname "$0")/.." && pwd -P)
herdr=${HERDR_BIN_PATH:-herdr}
data_dir=${XDG_DATA_HOME:-$HOME/.local/share}/herdr-fm-title
cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/herdr-fm-title
state_dir=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-fm-title}
agents_file=$state_dir/agents
config_file=${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/config.toml
claude_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
codex_dir=${CODEX_HOME:-$HOME/.codex}
opencode_dir=${XDG_CONFIG_HOME:-$HOME/.config}/opencode
SUPPORTED="claude codex opencode"
MARK='herdr-fm-title/bin/hook'
BACKUP=.bak-herdr-fm-title

notify() {
  printf '%s\n' "$1"
  "$herdr" notification show "Agent session titles" --body "$1" >/dev/null 2>&1
}

agent_dir() { case $1 in claude) echo "$claude_dir" ;; codex) echo "$codex_dir" ;; opencode) echo "$opencode_dir" ;; esac; }
hook_cmd() { printf "sh '%s/bin/hook' %s" "$data_dir" "$1"; }

# Supported agents whose config directory exists, limited by `agents = [...]` in config.toml.
selected_agents() {
  wanted=$(sed -n 's/^[[:space:]]*agents[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' "$config_file" 2>/dev/null |
    tr -d "\"' " | tr ',' ' ')
  for a in $SUPPORTED; do
    [ -d "$(agent_dir "$a")" ] || continue
    [ -z "$wanted" ] || case " $wanted " in *" $a "*) ;; *) continue ;; esac
    echo "$a"
  done
}

# Copy runtime/ into place; mtimes are kept so the Swift binary is rebuilt only for a new title.swift.
deploy_runtime() {
  mkdir -p "$(dirname "$data_dir")" || return 1
  tmp="$data_dir.new.$$"
  rm -rf "$tmp" "$data_dir.old"
  cp -Rp "$plugin_root/runtime" "$tmp" && chmod +x "$tmp"/bin/* || { rm -rf "$tmp"; return 1; }
  [ ! -e "$data_dir" ] || mv "$data_dir" "$data_dir.old"
  mv "$tmp" "$data_dir" && rm -rf "$data_dir.old"
}

# json_update FILE FILTER [jq args…] — atomic write; leaves an unparseable file untouched. A missing
# file starts as {}. Unless no_backup=1, an existing file is backed up before its first change, so
# a backup always holds the file as it was before install.
json_update() {
  file=$1 filter=$2
  shift 2
  if [ -f "$file" ]; then
    jq -e . "$file" >/dev/null 2>&1 || { echo "cannot parse $file, left unchanged" >&2; return 1; }
    [ "${no_backup:-}" = 1 ] || [ -e "$file$BACKUP" ] || cp -p "$file" "$file$BACKUP"
    jq "$@" "$filter" "$file" >"$file.tmp.$$"
  else
    printf '{}' | jq "$@" "$filter" >"$file.tmp.$$"
  fi && mv -f "$file.tmp.$$" "$file" || { rm -f "$file.tmp.$$"; return 1; }
}

JQ_STRIP='def strip: if type == "array" then map(select(any(.hooks[]?; (.command? // "") | tostring | contains($mark)) | not)) else . end;'

# hooks_register FILE ENTRIES_JSON — removes our entries from every event, then adds one per event
# in ENTRIES_JSON, so entries of an older version for other events go too.
hooks_register() {
  json_update "$1" "$JQ_STRIP"'
    .hooks = ((.hooks // {}) | map_values(strip) | with_entries(select(.value != [])))
    | reduce ($entries | to_entries[]) as $e (.; .hooks[$e.key] = ((.hooks[$e.key] // []) + [$e.value]))' \
    --arg mark "$MARK" --argjson entries "$2"
}

# hooks_unregister FILE — removes our entries; drops emptied events, an emptied `hooks`, and a
# file this plugin created (it has no backup) that ends up empty.
hooks_unregister() {
  [ -f "$1" ] && grep -q "$MARK" "$1" || return 0
  no_backup=1
  json_update "$1" "$JQ_STRIP"'
    if .hooks then .hooks |= (map_values(strip) | with_entries(select(.value != []))) else . end
    | if .hooks == {} then del(.hooks) else . end' --arg mark "$MARK"
  rc=$? no_backup=
  [ $rc -eq 0 ] || return 1
  [ -e "$1$BACKUP" ] || [ "$(jq -c . "$1")" != "{}" ] || rm -f "$1"
}

# hooks_state FILE AGENT → connected | outdated | no
hooks_state() {
  cmd=$(hook_cmd "$2")
  if [ -f "$1" ] && jq -e --arg c "$cmd" '[.hooks[]?[]?.hooks[]?.command?] | any(. == $c)' "$1" >/dev/null 2>&1; then
    echo connected
  elif [ -f "$1" ] && grep -q "$MARK" "$1"; then echo outdated; else echo no; fi
}

register_claude() {
  cmd=$(hook_cmd claude)
  hooks_register "$claude_dir/settings.json" "$(jq -cn --arg c "$cmd" '{
    SessionStart: {hooks: [{type: "command", command: $c}]},
    UserPromptSubmit: {hooks: [{type: "command", command: $c, timeout: 10}]}}')"
}
unregister_claude() { hooks_unregister "$claude_dir/settings.json"; }
state_claude() { hooks_state "$claude_dir/settings.json" claude; }

# Codex runs hooks.json only with `[features] hooks = true`. A `hooks` key already under
# [features] is left as it is.
codex_features_state() {
  awk '/^[[:space:]]*\[/ { in_f = ($0 ~ /^[[:space:]]*\[features\][[:space:]]*(#.*)?$/) }
       in_f && /^[[:space:]]*hooks[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v); print v; exit }' \
    "$codex_dir/config.toml" 2>/dev/null
}
codex_enable_hooks() {
  f=$codex_dir/config.toml
  [ -z "$(codex_features_state)" ] || return 0
  if [ -f "$f" ]; then
    [ -e "$f$BACKUP" ] || cp -p "$f" "$f$BACKUP"
    if grep -Eq '^[[:space:]]*\[features\][[:space:]]*(#.*)?$' "$f"; then
      awk '{ print } !done && /^[[:space:]]*\[features\][[:space:]]*(#.*)?$/ { print "hooks = true"; done = 1 }' "$f" >"$f.tmp.$$"
    else
      { cat "$f"; printf '\n[features]\nhooks = true\n'; } >"$f.tmp.$$"
    fi && mv -f "$f.tmp.$$" "$f"
  else
    printf '[features]\nhooks = true\n' >"$f"
  fi
}
register_codex() {
  cmd=$(hook_cmd codex)
  hooks_register "$codex_dir/hooks.json" "$(jq -cn --arg c "$cmd" '{
    UserPromptSubmit: {hooks: [{type: "command", command: $c, async: true}]}}')" &&
    codex_enable_hooks
}
unregister_codex() { hooks_unregister "$codex_dir/hooks.json"; }
state_codex() { hooks_state "$codex_dir/hooks.json" codex; }

register_opencode() {
  mkdir -p "$opencode_dir/plugins" && ln -sfn "$data_dir/opencode" "$opencode_dir/plugins/herdr-fm-title"
}
unregister_opencode() { [ ! -L "$opencode_dir/plugins/herdr-fm-title" ] || rm -f "$opencode_dir/plugins/herdr-fm-title"; }
state_opencode() {
  link=$opencode_dir/plugins/herdr-fm-title
  if [ "$(readlink "$link" 2>/dev/null)" = "$data_dir/opencode" ] && [ -d "$link" ]; then echo connected
  elif [ -L "$link" ]; then echo outdated; else echo no; fi
}

backend_state() {
  if command -v fm >/dev/null 2>&1 && fm available >/dev/null 2>&1; then echo "fm"
  elif [ -x "$cache_dir/bin/title" ] && ! [ "$data_dir/title.swift" -nt "$cache_dir/bin/title" ]; then echo "Swift binary"
  elif command -v swiftc >/dev/null 2>&1; then echo "Swift, built on the next prompt"
  else echo "none: titles are off (needs the fm CLI, or Xcode Command Line Tools)"; fi
}
