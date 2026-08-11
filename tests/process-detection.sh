#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Whether a process is this install's server. A command line proves nothing:
# anything may carry "mangosd -c" in its arguments, and one that did made the
# world server refuse to start.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=lib/kit.sh
. "$KIT/lib/kit.sh"

TMP=$(mktemp -d)
DECOY="" REAL=""
# Invoked by the trap below.
# shellcheck disable=SC2329
cleanup() {
  [[ -n "$DECOY" ]] && kill "$DECOY" 2>/dev/null
  [[ -n "$REAL"  ]] && kill "$REAL"  2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin"
SERVER="$TMP"

expect "nothing running means no world server" "$(world_running && echo yes || echo no)" no

# A stranger holding the pattern in its arguments. Its binary is a shell, so it
# is not this install's world server whatever its command line says.
bash -c 'exec -a "sh mangosd -c mangosd.conf" sleep 47' &
DECOY=$!
sleep 1
expect "a stranger carrying the pattern is not the world server" \
  "$(world_running && echo yes || echo no)" no
expect "and server_pids claims none of it" "$(server_pids mangosd | wc -l)" 0

# The real thing: a binary living in server/bin, started under the name the
# start script uses. sleep stands in for the core, which nothing here runs.
cp /bin/sleep "$TMP/bin/mangosd"
bash -c 'exec -a "./mangosd -c mangosd.conf" "$0" 47' "$TMP/bin/mangosd" &
REAL=$!
sleep 1
expect "a binary from server/bin is the world server" \
  "$(world_running && echo yes || echo no)" yes
expect "and server_pids names exactly one" "$(server_pids mangosd | wc -l)" 1

exit $RC
