#!/usr/bin/env bash
# Renamed to twow-vm.sh, alongside twow.sh. This stands in so an existing work
# directory keeps working, and goes at some later point.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '\033[1;33m[warn]\033[0m setup-vm.sh is now twow-vm.sh; this stand-in will be removed\n' >&2
exec "$HERE/twow-vm.sh" "$@"
