#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# twow.sh reached through a symlink, as /usr/local/bin/twow would, still finds
# the checkout that holds lib/.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

ln -s "$KIT/twow.sh" "$TMP/twow"
out=$("$TMP/twow" help 2>&1) && rc=0 || rc=$?
expect "help answers through the symlink" "$rc" 0
case "$out" in *"Modes:"*) rc=0;; *) rc=1;; esac
expect "and reads as the kit's own usage" "$rc" 0

exit $RC
