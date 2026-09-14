# shellcheck shell=bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
# Which core this install runs, and everything that follows from it
# =============================================================================
# The repack's own core and the core with AI players are the same checkout
# with a module built in, and they differ in more than a compile flag: a second
# repository cloned into the first, a cmake option, a dependency, config files
# the repack never shipped, and migrations of the module's own. All of that is
# declared in the two tables below and read from there by everyone else, so
# switching cores is a row of data rather than a condition spread through the
# kit.
#
# ROOT and SERVER come from the caller, the same way lib/kit.sh takes them.

VARIANT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ROOT:=$(dirname "$VARIANT_LIB")}"
: "${SERVER:=$ROOT/server}"

# Columns, separated by | :
#   1 label    what this install calls itself, and the name in variant.env
#   2 repo     git remote the core is built from
#   3 branch   branch in it
#   4 module   a second repository built into the checkout, as
#              repo branch path, the path being where under the checkout it is
#              cloned to; empty for a core that is the checkout alone
#   5 cmake    options the build needs beyond the shared ones
#   6 deps     labels in twow.sh's DEPS this core needs and the other does not
#   7 conf     config files it brings that the repack does not ship, space
#              separated, each as name=source: the name is where it is placed,
#              relative to mangosd.conf, and the source is the template of it
#              under the checkout
#   8 summary  one line, printed by 'bots' and by doctor
VARIANTS=(
  "stock|https://github.com/tortoise-wow/tortoise-wow.git|main||||\
|the core the repack is built from"
  "bots|https://github.com/tortoise-wow/tortoise-wow.git|main\
|https://github.com/Sagiroth/TortoiseBots.git main modules/TortoiseBots\
|-DMODULES=static -DMODULE_TORTOISEBOTS=static|Boost\
|aiplayerbot.conf=modules/TortoiseBots/ai/playerbot/aiplayerbot.conf.dist.in \
modules/tortoise_bots.conf=modules/TortoiseBots/conf/tortoise_bots.conf.dist\
|the same core with TortoiseBots, a module of AI players"
)

# Migrations a core carries beyond the checkout's own, as
# variant|directory under the source|database|glob. They are stamped and
# idempotent like the core's, so the applier interleaves them by stamp and
# records each by name.
VARIANT_STREAMS=(
  "bots|modules/TortoiseBots/data/sql/world|turtle_world|*_world.sql"
  "bots|modules/TortoiseBots/data/sql/char|turtle_char|*_char.sql"
)

# What a first enable starts with; the module ships none. A cohort is minutes
# of cache building on a first boot and as many characters in every backup.
# shellcheck disable=SC2034
VARIANT_BOTS_DEFAULT=20

# Where their levels sit until somebody says otherwise: the whole range, which
# is the realm the core ships. 'near' keeps them to the levels being played.
# shellcheck disable=SC2034
VARIANT_BOTS_LEVELS_DEFAULT=spread

# Split one row into the caller's local variables, so the column order is
# written down exactly once.
variant_parse() {
  IFS='|' read -r v_label v_repo v_branch v_module v_cmake v_deps v_conf v_summary <<<"$1"
}

variant_labels() {
  local row v_label v_repo v_branch v_module v_cmake v_deps v_conf v_summary
  for row in "${VARIANTS[@]}"; do variant_parse "$row"; printf '%s\n' "$v_label"; done
}

# One field of one variant, by label and column name.
# $1 label, $2 one of repo branch module cmake deps conf summary
variant_field() {
  local row v_label v_repo v_branch v_module v_cmake v_deps v_conf v_summary
  for row in "${VARIANTS[@]}"; do
    variant_parse "$row"
    [[ "$v_label" == "$1" ]] || continue
    case "$2" in
      repo) printf '%s' "$v_repo" ;; branch) printf '%s' "$v_branch" ;;
      module) printf '%s' "$v_module" ;; cmake) printf '%s' "$v_cmake" ;;
      deps) printf '%s' "$v_deps" ;; conf) printf '%s' "$v_conf" ;;
      summary) printf '%s' "$v_summary" ;;
      *) return 1 ;;
    esac
    return 0
  done
  return 1
}

# The module a core builds into its checkout, split into the caller's m_repo,
# m_branch and m_path the way variant_parse splits a row. False for a core that
# is the checkout alone.
variant_module() {  # $1 label
  # shellcheck disable=SC2034  # split for the caller, the way variant_parse is
  read -r m_repo m_branch m_path <<<"$(variant_field "$1" module)"
  [[ -n "$m_repo" ]]
}

# The configs the active core brings, one per line, each as it is called
# relative to mangosd.conf.
variant_confs() {
  local e
  for e in $(variant_field "$(variant_active)" conf); do printf '%s\n' "${e%%=*}"; done
  return 0
}

# Where under the build tree the configured copy of one of them is written:
# every one lands in modules/ under its bare name.
# $1 the config, as it is called relative to mangosd.conf
variant_conf_generated() { printf 'modules/%s' "${1##*/}"; }

# Where under the checkout the template of one of them sits.
# $1 the config, as it is called relative to mangosd.conf
variant_conf_source() {
  local e
  for e in $(variant_field "$(variant_active)" conf); do
    [[ "${e%%=*}" == "$1" ]] && { printf '%s' "${e#*=}"; return 0; }
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

# The streams the active core carries beyond the checkout's own, in the
# applier's own directory|db|glob shape, relative to that core's checkout.
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
  local row claiming=() v_label v_repo v_branch v_module v_cmake v_deps v_conf v_summary
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

# Whether the installed world server actually carries the bot module. The
# config keys it reads are in the binary whether or not they are ever set, so
# this answers for the build rather than for what was written down, which is
# the one question a stale variant.env cannot be trusted on. The key is the
# module's own: the fork an older kit built reads AiPlayerbot.* too, and a
# build of it has to read as something to build again.
variant_binary_has_bots() {
  [[ -x "$SERVER/bin/mangosd" ]] || return 1
  grep -qa 'TortoiseBots\.' "$SERVER/bin/mangosd"
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

# One spelling of a git remote, so the two ways GitHub is written read as one.
variant_remote_norm() {  # $1 url
  local u=${1%/}; u=${u%.git}
  u=${u/#git@github.com:/https:\/\/github.com\/}
  printf '%s' "${u,,}"
}

# The origin of the active core's checkout, printed when it is not the
# repository the row names: an older kit cloned it from where the row pointed
# then. Prints nothing for a checkout that matches or is absent.
variant_foreign_origin() {
  local src origin
  src=$(variant_src)
  [[ -d "$src/.git" ]] || return 0
  origin=$(git -C "$src" remote get-url origin 2>/dev/null) || return 0
  [[ "$(variant_remote_norm "$origin")" == "$(variant_remote_norm "$(variant_field "$(variant_active)" repo)")" ]] && return 0
  printf '%s' "$origin"
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
