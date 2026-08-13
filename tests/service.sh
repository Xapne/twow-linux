#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# The unit the service mode writes, and the guards around a server systemd
# owns: run yields to an active service, and doctor spots a unit that starts
# some other install.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- the unit says what the design decided -----------------------------------
unit=$(service_unit_text)
case "$unit" in *"ExecStart=\"$ROOT/twow.sh\" service watch"*) rc=0;; *) rc=1;; esac
expect "ExecStart names this install, quoted" "$rc" 0
for want in "Type=exec" "KillMode=mixed" "Restart=on-failure" \
            "TimeoutStopSec=" "WantedBy=default.target" "StartLimitBurst="; do
  case "$unit" in *"$want"*) rc=0;; *) rc=1;; esac
  expect "the unit carries $want" "$rc" 0
done
# Processes escaping the manager's lifecycle is the failure the socket work
# closed off; the mode the man page recommends against never appears.
case "$unit" in *"KillMode=none"*) rc=1;; *) rc=0;; esac
expect "KillMode=none is not used" "$rc" 0

# --- run yields to an active service -----------------------------------------
refused=$( ( service_active() { return 0; }; run_all ) 2>&1 ) || true
case "$refused" in *"runs as a service"*) rc=0;; *) rc=1;; esac
expect "run refuses while systemd holds the server" "$rc" 0

# The watcher is the one caller allowed through; it fails later on the missing
# binaries here, which proves it got past the guard.
passed=$( ( service_active() { return 0; }; TWOW_SERVICE=1; run_all ) 2>&1 ) || true
case "$passed" in *"runs as a service"*) rc=1;; *) rc=0;; esac
expect "the service's own watcher passes the guard" "$rc" 0

# --- doctor reads the unit back ----------------------------------------------
# systemctl and loginctl answer nothing here, so only the ExecStart check can
# come out ok; what is asserted is that check alone.
mkdir -p "$TMP/bin"
for c in systemctl loginctl; do
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
done
export PATH="$TMP/bin:$PATH"

SERVICE_UNIT="$TMP/twow.service"
service_unit_text > "$SERVICE_UNIT"
verdict=$(doctor_service 2>&1)
case "$verdict" in *"the unit starts this install"*) rc=0;; *) rc=1;; esac
expect "doctor accepts the unit this install wrote" "$rc" 0

printf 'ExecStart="/somewhere/else/twow.sh" service watch\n' > "$SERVICE_UNIT"
verdict=$(doctor_service 2>&1)
case "$verdict" in *"not this install"*) rc=0;; *) rc=1;; esac
expect "doctor names a unit that starts another install" "$rc" 0

rm -f "$SERVICE_UNIT"
expect "doctor is silent while no unit is installed" "$(doctor_service 2>&1)" ""

exit $RC
