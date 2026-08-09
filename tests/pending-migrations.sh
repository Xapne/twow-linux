#!/usr/bin/env bash
# Which migration files count as pending. doctor asks the applier this through
# --check, so the rule is tested where it lives.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=server/apply-db-updates.sh
. "$KIT/server/apply-db-updates.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

expect "an empty directory has nothing pending" "$(pending_files '' | wc -l)" 0

: > 20260101000000_world.sql
: > 20260201000000_world.sql
: > 20260301000000_world.sql
: > 20260401000000_char.sql
: > notes.txt

expect "a database at nothing has every world file pending" "$(pending_files '' | wc -l)" 3
expect "a database midway has the later ones pending"       "$(pending_files 20260101000000 | wc -l)" 2
expect "a database at the newest has nothing pending"       "$(pending_files 20260301000000 | wc -l)" 0
expect "files for other databases are left out"             "$(pending_files '' | grep -c _char || true)" 0
expect "the oldest pending comes first"                     "$(pending_files '' | head -1)" 20260101000000_world.sql

exit $RC
