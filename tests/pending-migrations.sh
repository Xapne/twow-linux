#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Which migration files count as pending, which failures mean the database
# already has what a migration adds, and that every stream the applier carries
# is declared whole. doctor asks the applier the first question through --check,
# so the rules are tested where they live.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=server/apply-db-updates.sh
. "$KIT/server/apply-db-updates.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

expect "an empty directory has nothing pending" "$(pending_files '*_world.sql' /dev/null | wc -l)" 0

: > 20260101000000_world.sql
: > 20260201000000_world.sql
: > 20260301000000_world.sql
: > 20260401000000_character.sql
: > notes.txt

expect "a database that recorded nothing has every world file pending" \
  "$(pending_files '*_world.sql' /dev/null | wc -l)" 3
expect "files of another stream are left out" \
  "$(pending_files '*_world.sql' /dev/null | grep -c _character || true)" 0
expect "the oldest pending comes first" \
  "$(pending_files '*_world.sql' /dev/null | head -1)" 20260101000000_world.sql
expect "a stream picks up only its own files" \
  "$(pending_files '*_character.sql' /dev/null | wc -l)" 1

printf '%s\n' 20260101000000_world 20260201000000_world 20260301000000_world > applied
expect "a database that recorded them all has nothing pending" \
  "$(pending_files '*_world.sql' applied | wc -l)" 0

printf '%s\n' 20260201000000_world > applied
expect "only what is unrecorded is pending" \
  "$(pending_files '*_world.sql' applied | wc -l)" 2

# The reason this is matched by name and not against the newest stamp: branches
# of the source interleave their stamps, so switching between them brings files
# older than ones already applied.
printf '%s\n' 20260301000000_world > applied
: > 20260215000000_world.sql
expect "a file older than the newest recorded is still pending" \
  "$(pending_files '*_world.sql' applied | grep -c 20260215000000_world || true)" 1

# A character database arrives with no record of what the live server it came
# from had applied, so a migration describing schema already in place is not a
# failure. Anything else still is.
say_err() { printf '%s\n' "$@" > "$TMP/err"; }

say_err "ERROR 1050 (42S01) at line 1: Table 'characters' already exists"
only_already_there "$TMP/err" && got=yes || got=no
expect "a table that is already there is not a failure" "$got" yes

say_err "ERROR 1060 (42S21) at line 1: Duplicate column name 'honor'" \
        "ERROR 1061 (42000) at line 2: Duplicate key name 'idx'"
only_already_there "$TMP/err" && got=yes || got=no
expect "a column and an index already there are not a failure" "$got" yes

say_err "ERROR 1050 (42S01) at line 1: Table 'characters' already exists" \
        "ERROR 1146 (42S02) at line 2: Table 'turtle_char.no_such_table' doesn't exist"
only_already_there "$TMP/err" && got=yes || got=no
expect "one real error among them is still a failure" "$got" no

: > "$TMP/err"
only_already_there "$TMP/err" && got=yes || got=no
expect "output with no error at all is not this case" "$got" no

malformed=0
for stream in "${STREAMS[@]}"; do
  IFS='|' read -r dir db glob <<< "$stream"
  [[ -n "$dir" && -n "$db" && -n "$glob" ]] || malformed=$(( malformed + 1 ))
done
expect "every stream declares a directory, a database and a glob" "$malformed" 0
expect "the world stream is one of them" \
  "$(printf '%s\n' "${STREAMS[@]}" | grep -c '|turtle_world|')" 1

exit $RC
