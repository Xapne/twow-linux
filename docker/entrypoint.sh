#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts the kit into the work dir and hands over to it. The kit derives its own
# root from where it sits, so it lives beside the data rather than in the image.
set -euo pipefail

KIT=/opt/kit
WORK=/twow

# The image's copy wins for anything the kit owns, so pulling a newer image
# updates the scripts; everything a conversion produced is left untouched.
find "$KIT" -mindepth 1 -maxdepth 1 -printf '%P\n' \
  | while IFS= read -r item; do
      cp -a "$KIT/$item" "$WORK/" 2>/dev/null || true
    done
chmod +x "$WORK"/twow.sh "$WORK"/*.sh "$WORK"/server/*.sh 2>/dev/null || true

# Both are mounted rather than built in: together they are 1.4 GB, and neither
# is this repo's to hand out.
missing=()
[[ -f "$WORK/TurtleWoW_1.18.zip" ]] || missing+=("TurtleWoW_1.18.zip")
[[ -f "$WORK/data.zip" ]] || missing+=("data.zip")
if (( ${#missing[@]} )) && [[ ! -x "$WORK/server/bin/mangosd" ]]; then
  printf '\033[1;31m[error]\033[0m %s\n' "no ${missing[*]} in $WORK, and nothing converted yet." >&2
  cat >&2 <<'EOF'

  Mount them beside the data volume, read-only:

    -v ./TurtleWoW_1.18.zip:/twow/TurtleWoW_1.18.zip:ro
    -v ./data.zip:/twow/data.zip:ro

  compose.yaml in this repo's docker/ does it already; put the two files
  next to it and run: docker compose up
EOF
  exit 1
fi

# The world console reads this terminal. Started without stdin held open, it
# reaches end of file the moment the world finishes loading and shuts down
# again, which arrives as a clean stop with nothing naming the cause.
case "${1:-}" in
  ""|run)
    if [[ "$(readlink /proc/self/fd/0 2>/dev/null)" == /dev/null ]]; then
      printf '\033[1;31m[error]\033[0m %s\n' "the world console has no terminal to read." >&2
      cat >&2 <<'EOF'

  The console is this container's main process, so stdin has to stay open or
  the server stops as soon as it is up. Add it:

    docker run -it ...          rather than  docker run -d ...
    docker compose up -d        which sets stdin_open and tty already

  Modes that only report are reachable without one:

    docker compose run --rm twow doctor
EOF
      exit 1
    fi;;
esac

# Anything named is a mode of its own, so 'docker compose run --rm twow doctor'
# and 'docker compose exec twow ./twow.sh account' both reach one.
(( $# )) && exec "$WORK/twow.sh" "$@"

converted() { [[ -x "$WORK/server/bin/mangosd" && -d "$WORK/server/db/turtle_logon" ]]; }

# shellcheck source=../lib/kit.sh
. "$WORK/lib/kit.sh"

# A detached start has nobody to answer the first-run questions, so setup is
# handed no terminal and they keep their defaults. What that settled is said
# out loud, since a realm quietly named for somebody else is worse than a wait.
if ! converted; then
  "$WORK/twow.sh" setup < /dev/null
  warn "converted without asking anything: the realm is called TurtleWoW, answers
  on 127.0.0.1, and has no account yet. Both are settled from here:
      docker compose exec twow ./twow.sh interactive
      docker compose exec twow ./twow.sh account
  Or answer them next time by converting first: docker compose run --rm twow setup"
fi

# The address a client is told to dial. Only the host knows its own, so it
# arrives as an environment variable and the realm mode writes it down.
if [[ -n "${TWOW_REALM_ADDRESS:-}" ]]; then
  mariadb_running \
    || ( cd "$SERVER" && nohup ./1-start-mysql.sh > logs/mysql.out 2>&1 & )
  for _ in $(seq 1 60); do mariadb_running && break; sleep 1; done
  "$WORK/twow.sh" realm "$TWOW_REALM_ADDRESS" || true
fi

# What 'twow.sh realm --bind' is for, and last so it holds whatever address was
# just set. A published port arrives on the container's own address, so
# loopback inside one is reachable by nothing.
conf_set "$SERVER/bin/realmd.conf"  BindIP 0.0.0.0
conf_set "$SERVER/bin/mangosd.conf" BindIP 0.0.0.0

exec "$WORK/twow.sh" run
