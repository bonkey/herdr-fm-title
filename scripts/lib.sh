# lib.sh — sourced by install.sh, uninstall.sh and status.sh, which run scripts/<action>.py.
# shellcheck shell=sh
#
# The action runs on the first Python 3.9+ found below, and install pins that interpreter for the
# runtime in <data>/python. /usr/bin/python3 is no candidate: without developer tools it opens an
# install dialog instead of running.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

python_ok() { [ -x "$1" ] && "$1" -I -S -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; }

# run_python ACTION [args…]
run_python() {
  action=$1
  shift
  dev=$(xcode-select -p 2>/dev/null)
  for py in "${HERDR_FM_TITLE_PYTHON:-}" /Library/Developer/CommandLineTools/usr/bin/python3 \
    ${dev:+"$dev/usr/bin/python3"} /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -n "$py" ] && python_ok "$py" || continue
    export HERDR_FM_TITLE_PYTHON="$py"
    # shellcheck disable=SC2093 # the first working interpreter ends the loop
    exec "$py" -I -S "$(dirname "$0")/$action.py" "$@"
  done
  msg="Agent session titles need Python 3.9 or later: install the Xcode Command Line Tools with xcode-select --install."
  printf '%s\n' "$msg"
  "${HERDR_BIN_PATH:-herdr}" notification show "Agent session titles" --body "$msg" >/dev/null 2>&1
  [ "${1:-}" = --sync ]
}
