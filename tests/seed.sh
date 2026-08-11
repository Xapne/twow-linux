#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# The seed's guards: which MariaDB may read the repack's data directory, which
# databases come out of it, and that the copy is cleared away afterwards.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- the version gate --------------------------------------------------------
# The repack's files were written by 10.3, so anything older is turned away and
# every version shipping today is let through. 10.11 against 10.3 is the pair a
# string comparison gets backwards.
while read -r have want code; do
  [[ -n "$have" ]] || continue
  if ver_ge "$have" "$want"; then rc=0; else rc=1; fi
  expect "ver_ge $have $want" "$rc" "$code"
done <<'CASES'
10.3    10.3  0
10.11   10.3  0
11.4    10.3  0
12.3.2  10.3  0
10.2    10.3  1
5.5     10.3  1
10      10.3  1
CASES

# The floor is the version that wrote the files, so the two are stated once and
# checked against each other rather than repeated as a literal.
if ver_ge "$SEED_SRC_VERSION" "$SEED_SRC_VERSION"; then rc=0; else rc=1; fi
expect "the daemon that wrote the files can read them back" "$rc" 0

# --- what the seed carries ---------------------------------------------------
expect "the seed carries the four game databases" \
  "${SEED_DBS[*]}" "turtle_logon turtle_char turtle_logs turtle_world"

# --- the copy is cleared away ------------------------------------------------
# Reached from a trap when a step fails, so it has to hold with no daemon
# running and with nothing set at all.
SEED_SOCK=""; SEED_WORK=""
if seed_cleanup; then rc=0; else rc=1; fi
expect "cleanup with nothing to clean succeeds" "$rc" 0

SEED_WORK="$TMP/seed-db"; mkdir -p "$SEED_WORK"; SEED_SOCK="$SEED_WORK/absent.sock"
seed_cleanup
if [[ -d "$SEED_WORK" ]]; then rc=1; else rc=0; fi
expect "cleanup removes the copy" "$rc" 0

exit $RC
