#!/usr/bin/env bash
#
# Backward-compat shim. The preflight/orientation chain that used to live here now
# lives in scripts/bootstrap.sh as its read-only `--check` mode — one front door
# for the whole deployment (check + rebuild), so the checks can never drift from
# the build that relies on them.
#
#   ./scripts/start-here.sh            -> ./scripts/bootstrap.sh --check
#   ./scripts/start-here.sh --check    -> ./scripts/bootstrap.sh --check
#
# To BUILD/rebuild the cluster (this shim never does): ./scripts/bootstrap.sh
#
exec "$(dirname "$0")/bootstrap.sh" --check "$@"
