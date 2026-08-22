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

# -- the tables the core ships ------------------------------------------------
# sql/base holds one file per table, each opening with DROP TABLE. A table the
# database already has is left alone whatever the file would rebuild it as, and
# one it has never had is taken from there.
mkdir -p "$TMP/base-src/sql/base"
: > "$TMP/base-src/sql/base/tw_world_creature_template.sql"
: > "$TMP/base-src/sql/base/tw_world_itemextendedcost.sql"
: > "$TMP/base-src/sql/base/tw_char_characters.sql"
: > "$TMP/base-src/sql/base/notes.sql"
SRC="$TMP/base-src"
# What each database holds, in place of the client's answer to SHOW TABLES.
DB() {
  case "$*" in
    *turtle_world*) printf '%s\n' creature_template playerbot ;;
    *turtle_char*)  printf '%s\n' characters ;;
  esac
}
: > "$TMP/applied"
expect "a table the database already has is not rebuilt" \
  "$(base_missing "$TMP/applied" | grep -c creature_template || true)" 0
expect "one it has never had is taken from the core's own dump" \
  "$(base_missing "$TMP/applied" | grep -c tw_world_itemextendedcost || true)" 1
expect "each is named with the database it belongs to" \
  "$(base_missing "$TMP/applied" | grep itemextendedcost | cut -d'|' -f1)" turtle_world
expect "a file naming no database is left where it is" \
  "$(base_missing "$TMP/applied" | grep -c notes || true)" 0
expect "the character database is asked about its own" \
  "$(base_missing "$TMP/applied" | grep -c tw_char_characters || true)" 0
printf '%s\n' tw_world_itemextendedcost > "$TMP/applied"
expect "and one already recorded is not offered twice" \
  "$(base_missing "$TMP/applied" | wc -l)" 0
unset -f DB

# -- what runs before what ----------------------------------------------------
# Two streams reach the same database and their stamps interleave: the core's
# own history adds a column and a fix on top of it names that column, so the
# order that counts is the stamp, not the directory.
mkdir -p "$TMP/src/sql/database_updates/world" "$TMP/src/sql/seed"
: > "$TMP/src/sql/database_updates/20260731120000_world.sql"
: > "$TMP/src/sql/database_updates/world/20260721013813_world.sql"
: > "$TMP/src/sql/database_updates/world/20260820000000_world.sql"
: > "$TMP/src/sql/seed/ai_playerbot_texts.sql"
SRC="$TMP/src"
# The applier keeps what a database has recorded in a file of its own, which is
# why the record the stub answers from is a second one.
APPLIED=$TMP/applied.now
RECORDED=$TMP/recorded; : > "$RECORDED"
applied_names() { cat "$RECORDED"; }
ALL_STREAMS=(
  "sql/seed|turtle_world|*.sql"
  "sql/database_updates|turtle_world|*_world.sql"
  "sql/database_updates/world|turtle_world|*_world.sql"
)
expect "the core's own seed goes first, whatever the stamps say" \
  "$(pending_all | head -1 | cut -d'|' -f4)" ai_playerbot_texts.sql
expect "then the oldest stamp, from whichever directory holds it" \
  "$(pending_all | sed -n 2p | cut -d'|' -f4)" 20260721013813_world.sql
expect "and a fix that names what it added comes after it" \
  "$(pending_all | sed -n 3p | cut -d'|' -f4)" 20260731120000_world.sql
expect "every pending file is listed once" "$(pending_all | wc -l)" 4
expect "each one carries the database and the directory it belongs to" \
  "$(pending_all | sed -n 2p | cut -d'|' -f2,3)" "turtle_world|sql/database_updates/world"
printf '%s\n' 20260721013813_world > "$RECORDED"
expect "what the database recorded is left out" \
  "$(pending_all | grep -c 20260721013813 || true)" 0
cd "$TMP" || exit 1

malformed=0
for stream in "${STREAMS[@]}"; do
  IFS='|' read -r dir db glob <<< "$stream"
  [[ -n "$dir" && -n "$db" && -n "$glob" ]] || malformed=$(( malformed + 1 ))
done
expect "every stream declares a directory, a database and a glob" "$malformed" 0
# The core keeps its own history in a directory of its own and the fixes on top
# of it beside them, and both reach the world database.
expect "the world database is reached by both of its streams" \
  "$(printf '%s\n' "${STREAMS[@]}" | grep -c '|turtle_world|')" 2

exit $RC
