#!/usr/bin/env bash
# Renamed to twow.sh, which is what a script with thirteen modes had grown into.
# This stands in so an install carrying the old name keeps working, and goes at
# some later point.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '\033[1;33m[warn]\033[0m setup-native.sh is now twow.sh; this stand-in will be removed\n' >&2
exec "$HERE/twow.sh" "$@"
