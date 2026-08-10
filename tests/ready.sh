#!/usr/bin/env bash
# What a detached start makes of the world it just handed to tmux. The port is
# the readiness signal, so each of the three endings is reached by stubbing it.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

# Passes are counted in place of being slept, which puts the cap within reach of
# a test and keeps the run instant.
PASS=0 READY_AT=0 SESSION_UNTIL=0 SAID=""
# Every one of these stands in for something with a server behind it.
# shellcheck disable=SC2329
{
  sleep()           { PASS=$(( PASS + 1 )); }
  world_ready()     { (( PASS >= READY_AT )); }
  console_running() { (( PASS < SESSION_UNTIL )); }
  world_port()      { echo 8091; }
  log_path()        { return 1; }
  say()             { SAID="$SAID$1"$'\n'; }
  warn()            { SAID="$SAID$1"$'\n'; }
}

watch() {  # $1 pass the port opens on, $2 pass the session ends on, $3 cap
  PASS=0 READY_AT=$1 SESSION_UNTIL=$2 WORLD_WAIT=$3 SAID=""
  wait_for_world
}

# A world already taking clients is reported without a wait, which is what a
# restart on warm hardware looks like.
rc=0; watch 0 999 120 || rc=$?
expect "an open world returns at once"     "$rc"   0
expect "and sleeps through no passes"      "$PASS" 0

rc=0; watch 3 999 120 || rc=$?
expect "a world opening on the third pass returns success" "$rc"   0
expect "and waits exactly that long"                       "$PASS" 3
case "$SAID" in *"accepting logins"*) got=yes;; *) got=no;; esac
expect "and says the realm is open" "$got" yes

# The failure this exists for: the session carries the world, so the session
# ending is the world stopping.
rc=0; watch 999 2 120 || rc=$?
expect "a session that ends while loading is a failure" "$rc" 1
case "$SAID" in *"world server stopped"*) got=yes;; *) got=no;; esac
expect "and says so as the reason" "$got" yes

# A slow load is a slow load, and the world is still coming up behind it.
rc=0; watch 999 999 5 || rc=$?
expect "a load still going at the cap is no failure" "$rc"   0
expect "and stops watching at the cap"               "$PASS" 5
case "$SAID" in *"watch it with"*) got=yes;; *) got=no;; esac
expect "and names what returns to it" "$got" yes

exit $RC
