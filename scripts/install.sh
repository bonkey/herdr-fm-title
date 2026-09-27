#!/bin/sh
# install.sh [--sync] — action "install": deploys the runtime and connects the agents (see install.py).
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
run_python install "$@"
