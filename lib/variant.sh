# shellcheck shell=bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
# Which core this install runs, and everything that follows from it
# =============================================================================
# The repack's own core and the playerbots core are two branches of two forks,
# and they differ in more than a compile flag: a repository, a branch, a cmake
# option, a dependency, a config file the repack never shipped, and a set of
# tables that has to be seeded once. All of that is declared in the two tables
# below and read from there by everyone else, so switching cores is a row of
# data rather than a condition spread through the kit.
#
# ROOT and SERVER come from the caller, the same way lib/kit.sh takes them.

VARIANT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ROOT:=$(dirname "$VARIANT_LIB")}"
: "${SERVER:=$ROOT/server}"

# Columns, separated by | :
#   1 label    what this install calls itself, and the name in variant.env
#   2 repo     git remote the core is built from
#   3 branch   branch in it
#   4 cmake    options the build needs beyond the shared ones
#   5 deps     labels in twow.sh's DEPS this core needs and the other does not
#   6 conf     config files it brings that the repack does not ship, space
#              separated, each placed beside mangosd.conf
#   7 summary  one line, printed by 'bots' and by doctor
VARIANTS=(
  "stock|https://github.com/Penqle/tortoise-wow.git|1181dev|||\
|the core the repack is built from"
  "bots|https://github.com/Shyalya/tortoise-wow.git|playerbots-integration-gh|-DBUILD_PLAYERBOTS=ON|Boost|aiplayerbot.conf ahbot.conf\
|a fork of it carrying AI players, with its own fixes"
)

# Tables a core seeds once and then owns, as
# variant|directory under the source|database|glob. What the core ships for
# both, in sql/base, is the applier's own business: it takes a table from there
# when the database has never had one.
# These carry DROP TABLE at the top, so they are seeded once and never again;
# the applier records them by name, which is what makes that true. They are
# applied before the stamped migrations, since a migration in the fork's
# character stream indexes a table seeded here.
VARIANT_STREAMS=(
  "bots|src/modules/PlayerBots/sql/world|turtle_world|*.sql"
  "bots|src/modules/PlayerBots/sql/world/classic|turtle_world|*.sql"
  "bots|src/modules/PlayerBots/sql/characters|turtle_char|*.sql"
)

# What a first enable starts with. The fork's own aiplayerbot.conf.dist ships
# a thousand, which is minutes of cache building on a first boot and a thousand
# characters in every backup; its quick-start advises starting small.
# Read by twow.sh, which sources this file.
# shellcheck disable=SC2034
VARIANT_BOTS_DEFAULT=20

# Split one row into the caller's local variables, so the column order is
# written down exactly once.
variant_parse() {
  IFS='|' read -r v_label v_repo v_branch v_cmake v_deps v_conf v_summary <<<"$1"
}

variant_labels() {
  local row v_label v_repo v_branch v_cmake v_deps v_conf v_summary
  for row in "${VARIANTS[@]}"; do variant_parse "$row"; printf '%s\n' "$v_label"; done
}

# One field of one variant, by label and column name.
# $1 label, $2 one of repo branch cmake deps conf summary
variant_field() {
  local row v_label v_repo v_branch v_cmake v_deps v_conf v_summary
  for row in "${VARIANTS[@]}"; do
    variant_parse "$row"
    [[ "$v_label" == "$1" ]] || continue
    case "$2" in
      repo) printf '%s' "$v_repo" ;; branch) printf '%s' "$v_branch" ;;
      cmake) printf '%s' "$v_cmake" ;; deps) printf '%s' "$v_deps" ;;
      conf) printf '%s' "$v_conf" ;; summary) printf '%s' "$v_summary" ;;
      *) return 1 ;;
    esac
    return 0
  done
  return 1
}

variant_known() { variant_field "$1" repo >/dev/null 2>&1; }

# What this install runs. The environment wins, which is how a switch builds the
# core it is switching to before anything has been written down, and how the
# container is told which one to serve.
variant_active() {
  local v=""
  # shellcheck source=/dev/null  # written at setup time, absent until then
  [[ -f "$SERVER/variant.env" ]] && v=$(. "$SERVER/variant.env" 2>/dev/null && printf '%s' "${TWOW_VARIANT:-}")
  v=${TWOW_VARIANT:-$v}
  variant_known "$v" || v=stock
  printf '%s' "$v"
}

# Recorded only once the binaries of that core are installed, so what this says
# and what server/bin holds cannot drift apart.
variant_save() {  # $1 label
  cat > "$SERVER/variant.env" <<EOF
# Written by twow.sh, read by everything that has to know which core this
# install runs. Change it with '$ROOT/twow.sh bots on|off' rather than by hand;
# the core in server/bin has to be built to match. The environment still wins.
TWOW_VARIANT=\${TWOW_VARIANT:-$1}
EOF
}

# Each core keeps its own checkout and build tree, so switching back is a
# relink rather than a recompile.
variant_src()   { printf '%s' "$ROOT/src/$(variant_active)"; }
variant_build() { printf '%s' "$ROOT/build/$(variant_active)"; }

# The streams the active core seeds, in the applier's own directory|db|glob
# shape, with the directory relative to that core's checkout.
variant_streams() {
  local row want; want=$(variant_active)
  for row in "${VARIANT_STREAMS[@]}"; do
    [[ "${row%%|*}" == "$want" ]] && printf '%s\n' "${row#*|}"
  done
  return 0
}

# Which cores claim a dependency, for a report that has to say who it is for.
# $1 label
variant_claiming_dep() {
  local row claiming=() v_label v_repo v_branch v_cmake v_deps v_conf v_summary
  for row in "${VARIANTS[@]}"; do
    variant_parse "$row"
    [[ " $v_deps " == *" $1 "* ]] && claiming+=("$v_label")
  done
  printf '%s' "${claiming[*]}"
}

# Whether a dependency labelled in DEPS is one this core needs. A label no
# variant claims is needed by both, and is never asked about here.
variant_needs_dep() {  # $1 label
  local deps; deps=$(variant_field "$(variant_active)" deps) || return 1
  [[ " $deps " == *" $1 "* ]]
}

# Whether the installed world server actually carries the bot subsystem. The
# config keys it reads are in the binary whether or not they are ever set, so
# this answers for the build rather than for what was written down, which is
# the one question a stale variant.env cannot be trusted on.
variant_binary_has_bots() {
  [[ -x "$SERVER/bin/mangosd" ]] || return 1
  grep -qa 'AiPlayerbot\.' "$SERVER/bin/mangosd"
}

# What the binaries in server/bin were built from, read off the binaries.
variant_binary_label() {
  [[ -x "$SERVER/bin/mangosd" ]] || return 1
  if variant_binary_has_bots; then printf 'bots'; else printf 'stock'; fi
}

# Fixes the kit carries for a core until they land upstream, in patches/<label>.
# Applying is idempotent, and a patch that no longer fits is reported rather
# than forced. Logging is the caller's: this file is sourced by tests that have
# none.
variant_patches() {
  local dir p
  dir="$ROOT/patches/$(variant_active)"
  [[ -d "$dir" ]] || return 0
  for p in "$dir"/*.patch; do [[ -e "$p" ]] && printf '%s\n' "$p"; done
  return 0
}

# Applies every patch not already in the checkout. Prints the ones that fit
# neither way, and returns 2 when there were any.
variant_apply_patches() {
  local src p rc=0
  src=$(variant_src)
  [[ -d "$src/.git" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if git -C "$src" apply --check "$p" 2>/dev/null; then
      git -C "$src" apply "$p" 2>/dev/null || { printf '%s\n' "$p"; rc=2; }
    elif git -C "$src" apply --reverse --check "$p" 2>/dev/null; then
      continue                      # already in the checkout
    else
      printf '%s\n' "$p"; rc=2
    fi
  done < <(variant_patches)
  return $rc
}

# Takes them back out, so a pull sees the checkout upstream left. Genuine local
# edits are not touched, which keeps 'git pull --ff-only' free to refuse for the
# reason it always did.
variant_unapply_patches() {
  local src p
  src=$(variant_src)
  [[ -d "$src/.git" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    git -C "$src" apply --reverse --check "$p" 2>/dev/null \
      && git -C "$src" apply --reverse "$p" 2>/dev/null
  done < <(variant_patches)
  return 0
}

# Installs made before the kit knew about variants keep the single src/ and
# build/ the layout used to have. The checkout moves under its label; the build
# tree is dropped rather than moved, since cmake records absolute paths in its
# cache and a moved one is refused on the next configure. Nothing in server/bin
# is touched, so a converted install keeps running on the binaries it has.
variant_migrate_legacy() {
  [[ -f "$ROOT/src/CMakeLists.txt" ]] || return 0
  local tmp="$ROOT/src.stock.$$"
  mv "$ROOT/src" "$tmp" || return 1
  mkdir -p "$ROOT/src"
  mv "$tmp" "$ROOT/src/stock" || return 1
  [[ -d "$ROOT/build" && ! -d "$ROOT/build/stock" ]] && rm -rf "$ROOT/build"
  return 0
}
