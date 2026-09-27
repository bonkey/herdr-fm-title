#!/bin/sh
# uninstall.sh — action "uninstall": removes what install added (see uninstall.py).
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
run_python uninstall "$@"
