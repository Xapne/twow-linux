#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# The conveniences: password hashing, where a log lives, how run splits its
# arguments, and that a destructive step is agreed to before it runs.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- the hash the client sends -----------------------------------------------
# Known value: the repack ships ADMIN with its own name as the password, and
# this is the hash that was found in its dump.
expect "the account hash is SHA1 of USER:PASS upper-cased" \
  "$(account_hash ADMIN ADMIN)" 8301316D0D8448A34FA6D0C6BF1CBFA2B4A1A93A

# --- where a log lives, taken from the configs -------------------------------
mkdir -p "$TMP/server/bin" "$TMP/server/logs"
SERVER="$TMP/server" ROOT="$TMP"
LOGS="$TMP/server/logs"
printf 'LogsDir = "../logs"\nLogFile = "server.log"\nDBErrorLogFile = "errors.log"\n' \
  > "$TMP/server/bin/mangosd.conf"
printf 'LogsDir = "../logs/"\nLogFile = "Realmd.log"\n' > "$TMP/server/bin/realmd.conf"
: > "$LOGS/server.log"; : > "$LOGS/errors.log"; : > "$LOGS/Realmd.log"; : > "$LOGS/mysql.out"

expect "the world log comes from mangosd.conf"  "$(log_path world)"  "$LOGS/server.log"
expect "the error log comes from mangosd.conf"  "$(log_path errors)" "$LOGS/errors.log"
expect "the realmd log comes from realmd.conf"  "$(log_path realmd)" "$LOGS/Realmd.log"
expect "the database log is the kit's capture"  "$(log_path db)"     "$TMP/server/logs/mysql.out"
# The core names neither of these, so both are fixed paths rather than config
# lookups, and a config naming no LogFile still resolves them.
expect "the stderr log is the kit's capture too" "$(log_path stderr)" "$TMP/server/logs/stderr.log"
if log_path nonsense >/dev/null 2>&1; then rc=0; else rc=1; fi
expect "an unknown log is refused" "$rc" 1
case " $LOG_KINDS " in *" stderr "*) rc=0;; *) rc=1;; esac
expect "and stderr is one the mode offers" "$rc" 0

# A renamed log still resolves, which is the reason the configs are read.
printf 'LogsDir = "../logs"\nLogFile = "renamed.log"\n' > "$TMP/server/bin/mangosd.conf"
: > "$LOGS/renamed.log"
expect "a renamed log follows the config" "$(log_path world)" "$LOGS/renamed.log"

# LogTimestamp is on by default in the repack, so the file on disk carries the
# start time and the newest one is the running server's.
printf 'LogsDir = "../logs"\nLogFile = "stamped.log"\n' > "$TMP/server/bin/mangosd.conf"
touch -d '2026-08-09 10:00' "$LOGS/stamped_2026-08-09_10-00-00.log"
touch -d '2026-08-09 21:41' "$LOGS/stamped_2026-08-09_21-41-17.log"
expect "a stamped log resolves to the newest" \
  "$(log_path world)" "$LOGS/stamped_2026-08-09_21-41-17.log"

# --- run splits the flag from the log level ----------------------------------
# Everything run_all touches is replaced, and tmux is a stub on PATH that
# records how it was called.
mkdir -p "$TMP/bin" "$TMP/server/bin"
# The stub records how it was called with the socket in front, and answers
# has-session per socket the way tmux would: a session exists after new-session
# on that socket, or when a marker file seeds one there.
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
sock=default
if [ "$1" = -L ]; then sock=$2; shift 2; fi
printf '%s %s\n' "$sock" "$*" >> "$TMPFILE"
if [ "$1" = has-session ]; then
  grep -q "^$sock new-session" "$TMPFILE" && exit 0
  [ -e "$TMPFILE.$sock" ] && exit 0
  exit 1
fi
exit 0
STUB
chmod +x "$TMP/bin/tmux"
: > "$TMP/server/bin/mangosd"; chmod +x "$TMP/server/bin/mangosd"
for s in 1-start-mysql 2-realm-server 3-world-server; do
  : > "$TMP/server/$s.sh"; chmod +x "$TMP/server/$s.sh"
done
export PATH="$TMP/bin:$PATH" TMPFILE="$TMP/tmux.calls"

start_native_db()   { :; }
realm_port()        { echo 3724; }
assert_port_ours()  { :; }
our_listener()      { echo 999; }
say()               { :; }
warn()              { :; }

: > "$TMPFILE"; run_all --detached 2 >/dev/null 2>&1
expect "a detached run starts the session named twow on the kit's socket" \
  "$(grep -c "^twow new-session -d -s twow" "$TMPFILE")" 1
expect "the log level reaches the world script" \
  "$(grep -c '3-world-server.sh 2' "$TMPFILE")" 1

: > "$TMPFILE"; run_all -d >/dev/null 2>&1
expect "the short flag works and leaves no level behind" \
  "$(grep -c '3-world-server.sh $' "$TMPFILE")" 1

# --- a console from before the kit had its own socket ------------------------
# It cannot move between tmux servers, so a detached start yields to it and
# console goes to it where it is. The marker seeds it on the default socket.
: > "$TMPFILE"; : > "$TMPFILE.default"
if ( world_running() { return 0; }; run_all --detached ) >/dev/null 2>&1
then rc=0; else rc=1; fi
expect "a detached start yields to a pre-socket console" "$rc" 1
expect "and starts nothing beside it" "$(grep -c new-session "$TMPFILE")" 0

: > "$TMPFILE"
( world_running() { return 0; }; console_attach ) >/dev/null 2>&1
expect "console follows a pre-socket console to the default socket" \
  "$(grep -c '^default attach -t =twow' "$TMPFILE")" 1

# The same name on the default socket may be anyone's session; with no world
# running it is left alone.
: > "$TMPFILE"
if ( world_running() { return 1; }; console_attach ) >/dev/null 2>&1
then rc=0; else rc=1; fi
expect "a twow session that is not a console is not attached to" "$rc" 1
rm -f "$TMPFILE.default"

: > "$TMPFILE"; : > "$TMPFILE.twow"
( console_attach ) >/dev/null 2>&1
expect "console attaches on the kit's socket, to the exact name" \
  "$(grep -c '^twow attach -t =twow' "$TMPFILE")" 1
rm -f "$TMPFILE.twow"

# --- a destructive step is agreed to first -----------------------------------
# The asking path needs a terminal, which a test run does not have. What is
# checked here is the pair that holds without one: --yes carries the answer, and
# its absence refuses rather than proceeding unasked.
if confirm_destructive "test" --yes; then rc=0; else rc=1; fi
expect "--yes stands in for the answer" "$rc" 0

if ( confirm_destructive "test" "" ) >/dev/null 2>&1; then rc=0; else rc=1; fi
expect "no terminal and no --yes refuses" "$rc" 1

# --- the notice the GPL's appendix asks for ----------------------------------
# Every element that appendix names is checked here, since a notice is the kind
# of text that drifts out of date without anything failing.
notice=$(show_license)
for want in "twow-linux" "Copyright (C) 2026" "Xapne" "ABSOLUTELY NO WARRANTY" \
            "version 3 or later" "LICENSE" "xapne@protonmail.ch"; do
  case "$notice" in *"$want"*) rc=0;; *) rc=1;; esac
  expect "the notice carries '$want'" "$rc" 0
done

exit $RC
