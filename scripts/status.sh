#!/bin/sh
# status.sh — action "status": agent connections, Python and model backend (see status.py).
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
run_python status "$@"
