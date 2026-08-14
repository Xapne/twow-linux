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
# SERVER points at an empty directory throughout: past the guard, run_all must
# die on the missing binaries rather than reach a converted install's server.
refused=$( ( service_installed() { return 0; }; service_active() { return 0; }
             SERVER="$TMP"; run_all ) 2>&1 ) || true
case "$refused" in *"runs as a service"*) rc=0;; *) rc=1;; esac
expect "run refuses while systemd holds the server" "$rc" 0

# The watcher is the one caller allowed through; dying on the binaries instead
# is what proves it got past the guard.
passed=$( ( service_installed() { return 0; }; service_active() { return 0; }
            SERVER="$TMP"; TWOW_SERVICE=1; run_all ) 2>&1 ) || true
case "$passed" in *"runs as a service"*) rc=1;; *) rc=0;; esac
expect "the service's own watcher passes the guard" "$rc" 0
case "$passed" in *"no native binaries"*) rc=0;; *) rc=1;; esac
expect "and stops at the binary check, starting nothing" "$rc" 0

# --- run hands an idle service to systemctl -----------------------------------
# A stubbed systemctl that refuses is what keeps the test off the real ports;
# the delegation message and the refusal report are what is asserted.
delegated=$( ( service_installed() { return 0; }; service_active() { return 1; }
               systemctl() { return 1; }; SERVER="$TMP"; run_all ) 2>&1 ) || true
case "$delegated" in *"starting it there"*) rc=0;; *) rc=1;; esac
expect "run starts an installed service through systemctl" "$rc" 0
case "$delegated" in *"did not start"*) rc=0;; *) rc=1;; esac
expect "and reports a start systemd refused" "$rc" 0

noted=$( ( service_installed() { return 0; }; service_active() { return 1; }
           systemctl() { return 1; }; SERVER="$TMP"; run_all debug ) 2>&1 ) || true
case "$noted" in *"does not apply"*) rc=0;; *) rc=1;; esac
expect "a log level is named as not applying under the service" "$rc" 0

( service_installed() { return 0; }; service_active() { return 1; }
  systemctl() { return 0; }; console_running() { return 0; }
  wait_for_world() { return 0; }; SERVER="$TMP"; run_all ) >/dev/null 2>&1 && rc=0 || rc=$?
expect "run returns clean once the service brings the world up" "$rc" 0

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
