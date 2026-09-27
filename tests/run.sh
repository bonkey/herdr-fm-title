#!/bin/sh
# Offline tests for the runtime and the plugin scripts. Needs jq; no herdr, agents or model.
# PATH is a directory of symlinks to basic tools plus shims, so each case controls whether
# fm, swiftc and herdr exist.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr-fm-title-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0 fail=0

check() { # check NAME COMMAND… — runs COMMAND in a subshell, counts the result
  name=$1
  shift
  if ("$@"); then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
eq() { [ "$1" = "$2" ] || { printf '  expected: [%s]\n  actual:   [%s]\n' "$2" "$1"; return 1; }; }

# --- environment -----------------------------------------------------------------------------
mkdir -p "$T/tools" "$T/shims"
for t in sh awk tr sed cut iconv wc find mkdir date tail mv rm cat jq dirname nohup rmdir cp chmod \
  grep ln readlink ls touch sleep env cmp head basename mktemp sort; do
  p=$(command -v "$t") && ln -s "$p" "$T/tools/$t"
done

# herdr shim: `pane get` answers with the agent named in $T/agent; anything else is appended to
# $T/herdr.log.
cat >"$T/shims/herdr" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "pane get" ]; then printf '{"result":{"pane":{"agent":"%s"}}}\\n' "\$(cat "$T/agent" 2>/dev/null)"; exit; fi
printf '%s\\n' "\$*" >>"$T/herdr.log"
EOF
# Backend stub: fm's interface; stdin to $T/stdin, reply from \$STUB_REPLY, exit \$STUB_EXIT.
cat >"$T/stub" <<EOF
#!/bin/sh
cat >"$T/stdin"
echo x >>"$T/stub.calls"
printf '%s\n' "\${STUB_REPLY-Stub Title}"
exit \${STUB_EXIT:-0}
EOF
chmod +x "$T/shims/herdr" "$T/stub"

reset() { # fresh HOME, XDG dirs and logs for each case
  rm -rf "$T/h" "$T/agent" "$T/herdr.log" "$T/stdin" "$T/stub.calls" "$T/bin"
  mkdir -p "$T/h" "$T/bin"
  export HOME="$T/h" XDG_CACHE_HOME="$T/h/cache" XDG_STATE_HOME="$T/h/state" XDG_DATA_HOME="$T/h/data" \
    XDG_CONFIG_HOME="$T/h/config"
  export PATH="$T/bin:$T/tools"
  unset HERDR_ENV HERDR_PANE_ID HERDR_FM_TITLE_BACKEND STUB_REPLY STUB_EXIT CLAUDE_CONFIG_DIR CODEX_HOME
  export HERDR_BIN_PATH="$T/shims/herdr" HERDR_PLUGIN_STATE_DIR="$T/h/pstate" HERDR_PLUGIN_CONFIG_DIR="$T/h/pconf"
}
use_stub() { export HERDR_FM_TITLE_BACKEND="$T/stub"; }
in_herdr() { export HERDR_ENV=1 HERDR_PANE_ID=p1; echo "${1:-claude}" >"$T/agent"; }
fm_title() { printf '%s' "$1" | "$repo/runtime/bin/fm-title"; }
calls() { [ -f "$T/stub.calls" ] && wc -l <"$T/stub.calls" | tr -d ' ' || echo 0; }

# --- fm-title: text preparation --------------------------------------------------------------
t_pasted() { reset; use_stub; fm_title 'fix the login
<pasted_content id="1">
secret pasted lines
</pasted_content id="1">
please now' >/dev/null && eq "$(sed -n 3p "$T/stdin")" "fix the login please now"; }
t_slash_args() { reset; use_stub; fm_title '/code-review spec.md in detail' >/dev/null && eq "$(sed -n 3p "$T/stdin")" "spec.md in detail"; }
t_slash_bare() { reset; use_stub; ! fm_title '/clear' && eq "$(calls)" 0; }
t_path_prompt() { reset; use_stub; fm_title '/Users/me/app.swift crashes on launch' >/dev/null &&
  eq "$(sed -n 3p "$T/stdin")" "/Users/me/app.swift crashes on launch"; }
t_short() { reset; use_stub; ! fm_title 'meh' && ! fm_title 'fix it' && eq "$(calls)" 0; }
check "fm-title removes pasted blocks" t_pasted
check "fm-title keeps slash command arguments" t_slash_args
check "fm-title skips a bare slash command" t_slash_bare
check "fm-title keeps a prompt starting with a path" t_path_prompt
check "fm-title skips prompts under 3 words" t_short

# --- fm-title: cleaning ----------------------------------------------------------------------
clean() { reset; use_stub; STUB_REPLY=$1 fm_title 'fix the login crash on ipad'; }
t_quotes() { eq "$(clean '"Login Crash Fix"')" "Login Crash Fix"; }
t_pathword() { eq "$(clean 'Add Captions to @scripts/promo/intro-video/')" "Add Captions"; }
t_words() { eq "$(clean 'Herdr Plugin for Tab Name Generation')" "Herdr Plugin Tab Name"; }
t_short_keeps() { eq "$(clean 'Add Captions to Video')" "Add Captions to Video"; }
t_article() { eq "$(clean 'The Dark Theme Fix')" "Dark Theme Fix"; }
t_punct() { eq "$(clean 'Stats Task: Show Costs.')" "Stats Task Show Costs"; }
t_lines() { eq "$(clean '

Title Here
second line')" "Title Here"; }
t_empty() { ! clean ''; }
t_oneword() { ! clean 'Ok' && ! clean 'The Fix'; }
t_quoted() { reset; use_stub; fm_title 'fix the login crash on ipad' >/dev/null &&
  eq "$(tr '\n' '|' <"$T/stdin")" 'Task:|"""|fix the login crash on ipad|"""|'; }
t_failed() { reset; use_stub; ! STUB_EXIT=1 fm_title 'fix the login crash on ipad' && grep -q 'backend failed' "$XDG_STATE_HOME/herdr-fm-title/runtime.log"; }
t_logcap() { reset; use_stub; log=$XDG_STATE_HOME/herdr-fm-title/runtime.log; mkdir -p "$(dirname "$log")"
  head -c 102400 /dev/zero | tr '\0' x >"$log"
  ! STUB_EXIT=1 fm_title 'fix the login crash on ipad' && eq "$(wc -c <"$log" | tr -d ' ')" 51200 && tail -n1 "$log" | grep -q 'backend failed'; }
t_cut() { eq "$(clean 'Supercalifragilistic Internationalization Refactor')" "Supercalifragilistic Internationalizatio"; }
t_endpunct() { eq "$(clean "'Refactor Parser C++'")" "Refactor Parser C"; }
t_apostrophe() { eq "$(clean "Don't Crash Parser")" "Don't Crash Parser"; }
check "fm-title strips quotes" t_quotes
check "fm-title drops path-like words and a trailing small word" t_pathword
check "fm-title drops small words from a long reply, then keeps 4" t_words
check "fm-title keeps small words inside a title of up to 4 words" t_short_keeps
check "fm-title drops a leading article" t_article
check "fm-title strips colons and trailing punctuation" t_punct
check "fm-title takes the first non-empty line" t_lines
check "fm-title fails on an empty reply" t_empty
check "fm-title rejects a one-word title" t_oneword
check "fm-title sends the prompt quoted" t_quoted
check "fm-title logs a failed backend" t_failed
check "fm-title keeps the log under 100 KB by dropping its older half" t_logcap
check "fm-title cuts a title at 40 characters, even mid-word" t_cut
check "fm-title strips leading quotes and trailing punctuation marks" t_endpunct
check "fm-title keeps an apostrophe inside a word" t_apostrophe

# --- fm-title: backend order -----------------------------------------------------------------
fm_shim() { # fm_shim available|unavailable
  cat >"$T/bin/fm" <<EOF
#!/bin/sh
case \$1 in available) [ "$1" = available ] ;; respond) cat >/dev/null; echo "Fm Title" ;; esac
EOF
  chmod +x "$T/bin/fm"
}
swift_bin() { mkdir -p "$XDG_CACHE_HOME/herdr-fm-title/bin" && printf '#!/bin/sh\ncat >/dev/null; echo "Swift Title"\n' >"$XDG_CACHE_HOME/herdr-fm-title/bin/title" &&
  chmod +x "$XDG_CACHE_HOME/herdr-fm-title/bin/title"; }
swiftc_shim() { # writes a working binary to the -o path; logs every call
  cat >"$T/bin/swiftc" <<EOF
#!/bin/sh
echo "\$*" >>"$T/swiftc.log"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
printf '#!/bin/sh\ncat >/dev/null; echo "Built Title"\n' >"\$out" && chmod +x "\$out"
EOF
  printf '#!/bin/sh\necho called >>"%s/swift.log"\n' "$T" >"$T/bin/swift"
  chmod +x "$T/bin/swiftc" "$T/bin/swift"
}
t_fm_first() { reset; fm_shim available; swift_bin; eq "$(fm_title 'fix the login crash on ipad')" "Fm Title"; }
t_swift_next() { reset; fm_shim unavailable; swift_bin; eq "$(fm_title 'fix the login crash on ipad')" "Swift Title"; }
t_none() { reset; fm_shim unavailable; ! fm_title 'fix the login crash on ipad'; }
t_build() {
  reset; rm -f "$T/swiftc.log" "$T/swift.log"; swiftc_shim
  ! fm_title 'fix the login crash on ipad' || return 1
  i=0; while [ ! -x "$XDG_CACHE_HOME/herdr-fm-title/bin/title" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  eq "$(fm_title 'fix the login crash on ipad')" "Built Title" && eq "$(wc -l <"$T/swiftc.log" | tr -d ' ')" 1 && [ ! -e "$T/swift.log" ]
}
t_stale() { reset; swiftc_shim; swift_bin; touch -t 200001010000 "$XDG_CACHE_HOME/herdr-fm-title/bin/title"; rm -f "$T/swiftc.log"
  ! fm_title 'fix the login crash on ipad' || return 1
  i=0; while [ -d "$XDG_CACHE_HOME/herdr-fm-title/build.lock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  eq "$(wc -l <"$T/swiftc.log" | tr -d ' ')" 1; }
check "fm-title prefers fm" t_fm_first
check "fm-title uses the Swift binary without fm" t_swift_next
check "fm-title fails with no backend" t_none
check "fm-title builds the Swift binary once in the background, never the interpreter" t_build
t_lock_fresh() { reset; rm -f "$T/swiftc.log"; swiftc_shim; mkdir -p "$XDG_CACHE_HOME/herdr-fm-title/build.lock"
  ! fm_title 'fix the login crash on ipad' && sleep 0.3 && [ ! -e "$T/swiftc.log" ]; }
t_lock_stale() { reset; rm -f "$T/swiftc.log"; swiftc_shim; mkdir -p "$XDG_CACHE_HOME/herdr-fm-title/build.lock"
  touch -t 200001010000 "$XDG_CACHE_HOME/herdr-fm-title/build.lock"
  ! fm_title 'fix the login crash on ipad' || return 1
  i=0; while [ ! -x "$XDG_CACHE_HOME/herdr-fm-title/bin/title" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  eq "$(wc -l <"$T/swiftc.log" | tr -d ' ')" 1; }
check "fm-title rebuilds a binary older than title.swift" t_stale
check "fm-title leaves a build to the process holding the lock" t_lock_fresh
check "fm-title takes over a build lock older than 10 minutes" t_lock_stale

# --- herdr-title -----------------------------------------------------------------------------
t_report() { reset; in_herdr; "$repo/runtime/bin/herdr-title" claude "Login Crash Fix" &&
  eq "$(cat "$T/herdr.log")" "pane report-metadata p1 --source plugin:bonkey.fm-title --agent claude --title Login Crash Fix"; }
t_outside() { reset; "$repo/runtime/bin/herdr-title" claude "Login Crash Fix" && [ ! -e "$T/herdr.log" ]; }
t_wait() { reset; in_herdr; : >"$T/agent"; "$repo/runtime/bin/herdr-title" claude "Late Title" && [ ! -e "$T/herdr.log" ] || return 1
  echo claude >"$T/agent"; i=0; while [ ! -e "$T/herdr.log" ] && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q -- "--agent claude --title Late Title" "$T/herdr.log"; }
check "herdr-title reports the metadata title" t_report
check "herdr-title does nothing outside herdr" t_outside
check "herdr-title waits in the background until herdr sees the agent" t_wait

# --- hook claude -----------------------------------------------------------------------------
hook() { # hook AGENT JSON
  printf '%s' "$2" | "$repo/runtime/bin/hook" "$1"
}
ups() { jq -cn --arg s "$1" --arg p "$2" --arg t "$T/h/proj/$1.jsonl" '{hook_event_name: "UserPromptSubmit", session_id: $s, transcript_path: $t, prompt: $p}'; }
sidecar() { mkdir -p "$T/h/proj/$1" && jq -cn --arg t "$2" '{customTitle: $t}' >"$T/h/proj/$1/custom-title.json"; }
marker() { cat "$XDG_STATE_HOME/herdr-fm-title/named/$1" 2>/dev/null; }
t_c_first() { reset; use_stub; in_herdr; out=$(hook claude "$(ups s1 'fix the login crash on ipad')") &&
  eq "$out" '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"Stub Title"}}' &&
  eq "$(marker claude-s1)" "Stub Title" && grep -q -- '--agent claude --title Stub Title' "$T/herdr.log"; }
t_c_rename() { reset; use_stub; in_herdr; hook claude "$(ups s1 'fix the login crash on ipad')" >/dev/null; sidecar s1 "My Name"
  out=$(hook claude "$(ups s1 'and now the settings screen')") && eq "$out" "" && eq "$(calls)" 1 &&
  eq "$(marker claude-s1)" "My Name" && eq "$(tail -n1 "$T/herdr.log")" "pane report-metadata p1 --source plugin:bonkey.fm-title --agent claude --title My Name"; }
t_c_named_elsewhere() { reset; use_stub; in_herdr; sidecar s2 "Named"; out=$(hook claude "$(ups s2 'fix the login crash on ipad')") &&
  eq "$out" "" && eq "$(calls)" 0 && eq "$(marker claude-s2)" "Named"; }
t_c_marker_only() { reset; use_stub; hook claude "$(ups s1 'fix the login crash on ipad')" >/dev/null
  out=$(hook claude "$(ups s1 'another long prompt here')") && eq "$out" "" && eq "$(calls)" 1; }
t_c_fail() { reset; use_stub; out=$(STUB_EXIT=1 hook claude "$(ups s1 'fix the login crash on ipad')") && eq "$out" "" && [ -z "$(marker claude-s1)" ]; }
t_c_badsid() { reset; use_stub; out=$(hook claude "$(ups '../x' 'fix the login crash on ipad')") && eq "$out" "" && eq "$(calls)" 0; }
t_c_start() { reset; in_herdr; hook claude '{"hook_event_name":"SessionStart","session_id":"s3","session_title":"Resumed"}' &&
  eq "$(marker claude-s3)" "Resumed" && grep -q -- '--title Resumed' "$T/herdr.log"; }
t_c_start_none() { reset; in_herdr; hook claude '{"hook_event_name":"SessionStart","session_id":"s3"}' &&
  [ -z "$(marker claude-s3)" ] && [ ! -e "$T/herdr.log" ]; }
check "hook claude: first prompt sets sessionTitle, tab and marker" t_c_first
check "hook claude: /rename reaches the tab, no second title" t_c_rename
check "hook claude: a session named elsewhere is not titled" t_c_named_elsewhere
check "hook claude: a marker stops generation" t_c_marker_only
check "hook claude: a failed backend leaves no output or marker" t_c_fail
check "hook claude: rejects an unsafe session id" t_c_badsid
check "hook claude: SessionStart reports session_title" t_c_start
t_c_nosuffix() { reset; use_stub; in_herdr; sidecar s4 "Plain Path"
  out=$(hook claude "$(jq -cn --arg t "$T/h/proj/s4" '{hook_event_name: "UserPromptSubmit", session_id: "s4", transcript_path: $t, prompt: "fix the login crash on ipad"}')") &&
  eq "$out" "" && eq "$(calls)" 0 && eq "$(marker claude-s4)" "Plain Path"; }
t_c_nonstring() { reset; use_stub; in_herdr
  hook claude '{"hook_event_name":"UserPromptSubmit","session_id":7,"prompt":"fix the login crash on ipad"}' &&
    hook claude '{"hook_event_name":"UserPromptSubmit","session_id":"s5","prompt":["fix the login crash on ipad"]}' &&
    hook claude '["UserPromptSubmit"]' && hook claude 'not json' &&
    eq "$(calls)" 0 && [ ! -e "$T/herdr.log" ] && [ -z "$(marker claude-s5)" ]; }
old_marker() { # old_marker NAME DAYS_AGO
  mkdir -p "$XDG_STATE_HOME/herdr-fm-title/named" && echo Old >"$XDG_STATE_HOME/herdr-fm-title/named/$1" &&
    touch -t "$(date -v-"$2"d +%Y%m%d%H%M)" "$XDG_STATE_HOME/herdr-fm-title/named/$1"; }
t_prune() { reset; old_marker claude-old 32; old_marker claude-recent 29
  hook claude '{"hook_event_name":"SessionStart","session_id":"s6"}' &&
    [ ! -e "$XDG_STATE_HOME/herdr-fm-title/named/claude-old" ] && [ -e "$XDG_STATE_HOME/herdr-fm-title/named/claude-recent" ] &&
    old_marker claude-old2 40 && hook claude '{"hook_event_name":"SessionStart","session_id":"s6"}' &&
    [ -e "$XDG_STATE_HOME/herdr-fm-title/named/claude-old2" ]; }
check "hook claude: SessionStart without a title does nothing" t_c_start_none
check "hook claude: a transcript path without .jsonl finds its sidecar" t_c_nosuffix
check "hook claude: non-string fields and non-object input do nothing" t_c_nonstring
check "hook: markers over 30 days old are pruned, at most once a day" t_prune

# --- hook codex ------------------------------------------------------------------------------
t_x_first() { reset; use_stub; in_herdr codex; out=$(hook codex "$(ups s1 'fix the login crash on ipad')") && eq "$out" "" &&
  eq "$(marker codex-s1)" "Stub Title" && grep -q -- '--agent codex --title Stub Title' "$T/herdr.log"; }
t_x_named() { reset; use_stub; in_herdr codex; hook codex "$(ups s1 'fix the login crash on ipad')"; rm -f "$T/herdr.log"
  out=$(hook codex "$(ups s1 'another long prompt here')") && eq "$out" "" && eq "$(calls)" 1 &&
  grep -q -- '--agent codex --title Stub Title' "$T/herdr.log"; }
check "hook codex: first prompt names the tab, prints nothing" t_x_first
check "hook codex: a named session re-reports its title, never regenerates" t_x_named

# --- plugin scripts --------------------------------------------------------------------------
plugin() { (cd "$repo" && sh "scripts/$1.sh" ${2:+"$2"}) >"$T/plugin.out" 2>&1; }
cmd_for() { printf "sh '%s/bin/hook' %s" "$XDG_DATA_HOME/herdr-fm-title" "$1"; }
claude_settings() { mkdir -p "$HOME/.claude" && printf '%s\n' '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-stop"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"other-ups"}]}]}}' >"$HOME/.claude/settings.json"; }
t_i_claude() {
  reset; claude_settings; plugin install || return 1
  f=$HOME/.claude/settings.json c=$(cmd_for claude)
  jq -e --arg c "$c" '.model == "x" and (.hooks.Stop[0].hooks[0].command == "other-stop")
    and ([.hooks.UserPromptSubmit[].hooks[].command] == ["other-ups", $c])
    and (.hooks.UserPromptSubmit[1].hooks[0].timeout == 10) and ([.hooks.SessionStart[].hooks[].command] == [$c])' "$f" >/dev/null &&
    cp "$f" "$T/first" && plugin install && cmp -s "$f" "$T/first" &&
    jq -e '.hooks.SessionStart == null' "$f.bak-herdr-fm-title" >/dev/null && [ -x "$XDG_DATA_HOME/herdr-fm-title/bin/hook" ]
}
t_i_stale_event() {
  reset; mkdir -p "$HOME/.codex"
  jq -cn --arg c "sh '/old/herdr-fm-title/bin/hook' codex" '{hooks: {SessionStart: [{matcher: "resume", hooks: [{type: "command", command: $c}]}], Stop: [{hooks: [{type: "command", command: "other"}]}]}}' >"$HOME/.codex/hooks.json"
  plugin install && jq -e '.hooks.SessionStart == null and .hooks.Stop[0].hooks[0].command == "other"' "$HOME/.codex/hooks.json" >/dev/null
}
t_i_badjson() { reset; mkdir -p "$HOME/.claude"; printf '{ broken' >"$HOME/.claude/settings.json"; ! plugin install &&
  eq "$(cat "$HOME/.claude/settings.json")" "{ broken" && grep -q 'Failed: claude' "$T/plugin.out"; }
t_i_codex() {
  reset; mkdir -p "$HOME/.codex"; printf '%s\n' 'model = "gpt"' '' '[features]' 'worktrees = true' >"$HOME/.codex/config.toml"
  plugin install || return 1
  c=$(cmd_for codex)
  jq -e --arg c "$c" '.hooks == {UserPromptSubmit: [{hooks: [{type: "command", command: $c, async: true}]}]}' "$HOME/.codex/hooks.json" >/dev/null &&
    eq "$(sed -n '/^\[features\]/,$p' "$HOME/.codex/config.toml" | tr '\n' '|')" "[features]|hooks = true|worktrees = true|" &&
    grep -q '/hooks' "$T/plugin.out"
}
t_i_codex_table() { reset; mkdir -p "$HOME/.codex"; printf 'model = "gpt"\n' >"$HOME/.codex/config.toml"; plugin install &&
  eq "$(tr '\n' '|' <"$HOME/.codex/config.toml")" 'model = "gpt"||[features]|hooks = true|'; }
t_i_codex_keep() { reset; mkdir -p "$HOME/.codex"; printf '[features]\nhooks = true\n' >"$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$T/orig"; plugin install && cmp -s "$HOME/.codex/config.toml" "$T/orig"; }
t_i_opencode() { reset; mkdir -p "$XDG_CONFIG_HOME/opencode"; plugin install &&
  eq "$(readlink "$XDG_CONFIG_HOME/opencode/plugins/herdr-fm-title")" "$XDG_DATA_HOME/herdr-fm-title/opencode" &&
  [ -f "$XDG_CONFIG_HOME/opencode/plugins/herdr-fm-title/tui.js" ]; }
t_i_select() { reset; claude_settings; mkdir -p "$HOME/.codex" "$HERDR_PLUGIN_CONFIG_DIR"; printf 'agents = ["claude"]\n' >"$HERDR_PLUGIN_CONFIG_DIR/config.toml"
  plugin install && [ ! -e "$HOME/.codex/hooks.json" ] && eq "$(cat "$HERDR_PLUGIN_STATE_DIR/agents")" claude; }
t_i_none() { reset; plugin install && grep -q 'No supported agent' "$T/plugin.out" && [ ! -e "$XDG_DATA_HOME/herdr-fm-title" ]; }
t_sync() {
  reset; claude_settings; plugin install || return 1
  mkdir -p "$HOME/.codex"; touch "$XDG_DATA_HOME/herdr-fm-title/stale"
  plugin install --sync && [ ! -e "$XDG_DATA_HOME/herdr-fm-title/stale" ] && [ ! -e "$HOME/.codex/hooks.json" ] &&
    eq "$(cat "$HERDR_PLUGIN_STATE_DIR/agents")" claude
}
t_sync_idle() { reset; claude_settings; plugin install --sync && [ ! -e "$XDG_DATA_HOME/herdr-fm-title" ] && ! grep -q herdr-fm-title "$HOME/.claude/settings.json"; }
t_uninstall() {
  reset; claude_settings; mkdir -p "$HOME/.codex" "$XDG_CONFIG_HOME/opencode"; cp "$HOME/.claude/settings.json" "$T/orig"
  plugin install && plugin uninstall || return 1
  eq "$(jq -S . "$HOME/.claude/settings.json")" "$(jq -S . "$T/orig")" && [ ! -e "$HOME/.codex/hooks.json" ] &&
    [ ! -e "$XDG_CONFIG_HOME/opencode/plugins/herdr-fm-title" ] && [ ! -e "$XDG_DATA_HOME/herdr-fm-title" ] &&
    [ -e "$HOME/.claude/settings.json.bak-herdr-fm-title" ] && grep -q 'Disconnected: claude codex opencode' "$T/plugin.out"
}
t_status() {
  reset; claude_settings; mkdir -p "$XDG_CONFIG_HOME/opencode"; plugin install && plugin status || return 1
  grep -q 'claude: connected; codex: not installed; opencode: connected; model: none' "$T/plugin.out"
}
t_status_fm() { reset; fm_shim available; plugin status && grep -q 'model: fm$' "$T/plugin.out"; }
t_i_empty_event() { reset; mkdir -p "$HOME/.claude"
  printf '%s\n' '{"hooks":{"Notification":[],"Stop":[{"hooks":[{"type":"command","command":"other-stop"}]}]}}' >"$HOME/.claude/settings.json"
  plugin install && jq -e '.hooks.Notification == null and .hooks.Stop[0].hooks[0].command == "other-stop"' "$HOME/.claude/settings.json" >/dev/null; }
t_u_untouched() { reset; mkdir -p "$HOME/.claude"; printf '{"hooks":{"Stop":[]}}' >"$HOME/.claude/settings.json"
  touch -t 200001010000 "$HOME/.claude/settings.json"; cp -p "$HOME/.claude/settings.json" "$T/orig"
  plugin uninstall && cmp -s "$HOME/.claude/settings.json" "$T/orig" && [ ! "$HOME/.claude/settings.json" -nt "$T/orig" ]; }
t_i_codex_false() { reset; mkdir -p "$HOME/.codex"; printf '[features]\nhooks = false\n' >"$HOME/.codex/config.toml"; cp "$HOME/.codex/config.toml" "$T/orig"
  plugin install && cmp -s "$HOME/.codex/config.toml" "$T/orig" && plugin status && grep -q 'codex: connected, but hooks are off' "$T/plugin.out"; }
t_status_outdated() { reset; claude_settings; plugin install || return 1
  sed -i '' "s#$XDG_DATA_HOME#/old/place#g" "$HOME/.claude/settings.json"; plugin status && grep -q 'claude: connected to an old runtime path' "$T/plugin.out"; }
check "install: Claude hooks added, others kept, idempotent, backed up once" t_i_claude
check "install: our entries from an older version are removed from every event" t_i_stale_event
check "install: unparseable settings.json left untouched and reported" t_i_badjson
check "install: Codex hooks async + [features] hooks in the existing table" t_i_codex
check "install: Codex [features] table appended when missing" t_i_codex_table
check "install: Codex existing hooks setting left as is" t_i_codex_keep
check "install: OpenCode plugin folder symlinked to the runtime" t_i_opencode
check "install: agents = [...] in config.toml limits the agents" t_i_select
check "install: no supported agent deploys nothing" t_i_none
check "install --sync: redeploys, refreshes only connected agents" t_sync
check "install --sync: nothing connected, nothing touched" t_sync_idle
check "uninstall: agent configs restored, runtime removed, backups kept" t_uninstall
check "status: connections and model" t_status
check "status: fm backend" t_status_fm
check "status: outdated runtime path" t_status_outdated
check "install: every emptied event array is dropped" t_i_empty_event
check "uninstall: a config without our entries is not rewritten" t_u_untouched
check "install: Codex hooks = false is kept, and status says so" t_i_codex_false

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
