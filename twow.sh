#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
# TurtleWoW 1.18.1: convert the SIGGZ Windows repack to a native Linux server
# and run it, in one command. Works on any Linux distro; every step is idempotent,
# so re-running only does what is missing.
#
# Layout it expects (and creates) under the folder this script lives in:
#   server/   the repack (from TurtleWoW_1.18.zip), native db in server/db
#   client/   the 1.18.1 game client (only needed to play, not to convert)
#   src/      core source, one checkout per core (see lib/variant.sh)
#   build/    native build tree, one per core
#   deps/     locally built ACE library, where the distro packages none
#   lib/      terminal prompts shared with twow-vm.sh
#
# Usage: ./twow.sh help
# =============================================================================
set -euo pipefail

# readlink follows a symlinked invocation, such as /usr/local/bin/twow, back
# to the checkout that holds lib/ and server/.
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SERVER="$ROOT/server"
# shellcheck source=lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=lib/firewall.sh
. "$ROOT/lib/firewall.sh"
# Logging, the database handle, and the port, process and config questions this
# script shares with the scripts in server/. Both used to carry a copy.
# shellcheck source=lib/kit.sh
. "$ROOT/lib/kit.sh"
# Which core this install runs: its repository, branch, build options, extra
# dependency, config and seed tables. Everything below asks this rather than
# naming a fork.
# shellcheck source=lib/variant.sh
. "$ROOT/lib/variant.sh"
# Overrides the compile job count worked out below, for a machine the
# measurement no longer fits.
TWOW_BUILD_JOBS=${TWOW_BUILD_JOBS:-}
export TWOW_BUILD_JOBS
ACE_VER=8.0.3

# =============================================================================
# Dependencies: the single source of truth
# =============================================================================
# Every dependency is declared once in DEPS. The missing-dependency report, the
# install command shown on failure, the `deps` mode and twow-vm.sh's guest
# provisioning are all derived from it, so no package name belongs anywhere
# else in the repo; a second list drifts, and the drift surfaces twenty minutes
# into a compile.
#
# Columns, separated by | :
#   1 label   name used in the report
#   2 kind    cmd      every command in column 3 is on PATH
#             daemon   the mariadb daemon, wherever the distro hides it
#             header   every header in column 3 is under /usr/include
#             header1  at least one header in column 3 (either spelling)
#             ace      a system ACE >= $ACE_MIN_MAJOR
#   3 target  what is checked, space separated; empty where the kind knows
#   4 tier    required  missing stops the run
#             variant   required only for the core that claims it in
#                       lib/variant.sh, which is the only place that says so
#             optional  missing only costs build time
#             seed      needed once, for the initial database seed
#             console   missing leaves the world console in its own terminal
#   5-8 package on debian | fedora | suse | arch; "-" where unpackaged, which
#       skips the row on that distro
DEPS=(
  "C/C++ toolchain|cmd|gcc g++ make|required|build-essential|gcc gcc-c++ make|gcc gcc-c++ make|gcc make"
  "cmake|cmd|cmake|required|cmake|cmake|cmake|cmake"
  "ninja|cmd|ninja|required|ninja-build|ninja-build|ninja|ninja"
  "git|cmd|git|required|git|git|git|git"
  "curl|cmd|curl|required|curl|curl|curl|curl"
  "bsdtar|cmd|bsdtar|required|libarchive-tools|bsdtar|bsdtar|libarchive"
  "sha1sum|cmd|sha1sum|required|coreutils|coreutils|coreutils|coreutils"
  "MariaDB client tools|cmd|mariadb mariadb-dump mariadb-admin|required|mariadb-client|mariadb|mariadb-client|mariadb-clients"
  "MariaDB daemon|daemon||required|mariadb-server|mariadb-server|mariadb|mariadb"
  "mariadb-install-db|cmd|mariadb-install-db|required|mariadb-server|mariadb-server|mariadb|mariadb"
  "MySQL headers|header1|mysql/mysql.h mariadb/mysql.h|required|default-libmysqlclient-dev|mariadb-connector-c-devel|libmariadb-devel|mariadb-libs"
  "OpenSSL headers|header|openssl/ssl.h|required|libssl-dev|openssl-devel|libopenssl-devel|openssl"
  "ZLIB headers|header|zlib.h|required|zlib1g-dev|zlib-devel|zlib-devel|zlib"
  "ACE library|ace||optional|libace-dev|-|-|-"
  "Boost|header|boost/thread.hpp boost/filesystem.hpp|variant|libboost-thread-dev libboost-filesystem-dev libboost-system-dev|boost-devel|libboost_thread-devel libboost_filesystem-devel libboost_system-devel|boost"
  "wine|cmd|wine|seed|wine|wine|wine|wine"
  "tmux|cmd|tmux|console|tmux|tmux|tmux|tmux"
)

# What this distro calls things. Falls back to Arch names with a note when the
# distro is unknown; DISTRO_COL selects the column, INSTALL is the command that
# installs from it.
detect_distro() {
  local id
  # shellcheck source=/dev/null
  id=$(. "${OS_RELEASE:-/etc/os-release}" 2>/dev/null && echo "${ID:-} ${ID_LIKE:-}") || id=""
  case " $id " in
    *" debian "*|*" ubuntu "*) DISTRO_COL=5; INSTALL="apt install -y";;
    *" fedora "*|*" rhel "*|*" centos "*) DISTRO_COL=6; INSTALL="dnf install -y";;
    *" suse "*|*" opensuse "*) DISTRO_COL=7; INSTALL="zypper install -y";;
    *)
      DISTRO_COL=8; INSTALL="pacman -S --needed"
      case " $id " in *" arch "*|*" manjaro "*|*" endeavouros "*) ;; *)
        [[ -n "$id" ]] && UNKNOWN_DISTRO=1;; esac;;
  esac
  # A container is usually entered as root and often carries no sudo, so an
  # install line naming it would not run as printed.
  [[ $EUID -eq 0 ]] || INSTALL="sudo $INSTALL"
}

# Split one row into the caller's local variables. Kept in one place so the
# column order is written down exactly once.
dep_parse() {
  IFS='|' read -r d_label d_kind d_target d_tier d_deb d_fed d_suse d_arch <<<"$1"
  case $DISTRO_COL in
    5) d_pkg=$d_deb;; 6) d_pkg=$d_fed;; 7) d_pkg=$d_suse;; *) d_pkg=$d_arch;;
  esac
}

dep_present() {
  local kind=$1 target=$2 t
  case "$kind" in
    cmd)     for t in $target; do command -v "$t" >/dev/null 2>&1 || return 1; done;;
    daemon)  find_mariadbd >/dev/null || return 1;;
    header)  for t in $target; do [[ -f "/usr/include/$t" ]] || return 1; done;;
    header1) for t in $target; do [[ -f "/usr/include/$t" ]] && return 0; done; return 1;;
    ace)     system_ace >/dev/null || return 1;;
  esac
  return 0
}

# The package providing one labelled row, for messages that name a single
# dependency rather than the whole list.
dep_pkg_of() {
  local row d_label d_kind d_target d_tier d_deb d_fed d_suse d_arch d_pkg
  for row in "${DEPS[@]}"; do
    dep_parse "$row"
    [[ "$d_label" == "$1" ]] && { printf '%s' "$d_pkg"; return 0; }
  done
  printf '%s' "$1"
}

# Every package for this distro, in table order, deduplicated. This is what
# twow-vm.sh provisions its guest with, and what the container image installs.
# A dependency only one core needs is in here too: a guest or an image is built
# before anyone has said which core it will run, and the package costs less than
# the failed compile twenty minutes into a switch.
dep_packages() {
  local row one out=() seen=" " d_label d_kind d_target d_tier d_deb d_fed d_suse d_arch d_pkg
  for row in "${DEPS[@]}"; do
    dep_parse "$row"
    [[ "$d_pkg" == "-" || -z "$d_pkg" ]] && continue
    for one in $d_pkg; do
      [[ "$seen" == *" $one "* ]] && continue
      seen+="$one "; out+=("$one")
    done
  done
  printf '%s\n' "${out[*]}"
}

# Copy into place without ETXTBSY: write beside the target, then rename over
# it. rename() only swaps the directory entry, so a running binary keeps its
# old inode and the next start picks up the new one.
install_binaries() {
  local src
  for src in "$@"; do
    local dest="$SERVER/bin/${src##*/}"
    cp -f "$src" "$dest.new" || die "could not stage ${src##*/} into server/bin/"
    chmod +x "$dest.new"
    mv -f "$dest.new" "$dest" || die "could not install ${src##*/} into server/bin/"
  done
}

# The headers are checked alongside the commands because distros that split
# their -dev packages pass every command check and then fail inside cmake.
# Deferred tiers are reported up front too: an hour of compiling before the
# database step announces a missing wine is the failure mode this prevents.
check_deps() {
  local row missing=() later=()
  local d_label d_kind d_target d_tier d_deb d_fed d_suse d_arch d_pkg
  for row in "${DEPS[@]}"; do
    dep_parse "$row"
    [[ "$d_pkg" == "-" ]] && continue
    dep_present "$d_kind" "$d_target" && continue
    case "$d_tier" in
      required) missing+=("$d_label ($d_pkg)") ;;
      variant)  variant_needs_dep "$d_label" && missing+=("$d_label ($d_pkg), for the $(variant_active) core") ;;
      optional) ace_built || later+=("no system ACE; it gets built from source here, which costs
  a few minutes on the first run. Skip that with: $INSTALL $d_pkg") ;;
      seed)     seeded || later+=("the one-time database seed further down needs wine,
  which is missing. Install it before then: $INSTALL $d_pkg") ;;
      console)  later+=("tmux carries the detached world console: 'run --detached' keeps the
  server up past the shell that started it, and 'console' returns to it.
  Install it with: $INSTALL $d_pkg") ;;
    esac
  done

  if ((${#missing[@]})); then
    local msg="missing dependencies:" m
    for m in "${missing[@]}"; do msg+=$'\n    '"$m"; done
    msg+=$'\n\n  install all of them with:\n\n  '"$INSTALL $(dep_packages)"
    [[ -n "${UNKNOWN_DISTRO:-}" ]] && msg+=$'\n\n  (unrecognized distro; those are Arch package names, adapt as needed)'
    die "$msg"
  fi
  say "all required commands and headers present"
  local l; for l in "${later[@]}"; do warn "$l"; done
}

# A local ACE build satisfies the server just as well, so once one exists the
# packaged ACE saves nothing and advising it would only mislead.
ace_built() { [[ -f "$ROOT/deps/ACE_wrappers/lib/libACE.so" ]]; }

# Dependency status for every tier, plus the command that installs the lot.
deps_report() {
  local row mark d_label d_kind d_target d_tier d_deb d_fed d_suse d_arch d_pkg
  printf '\n%s\n\n' "${C_BOLD}Dependencies for this system${C_RST}"
  for row in "${DEPS[@]}"; do
    dep_parse "$row"
    if [[ "$d_pkg" == "-" ]]; then
      mark="${C_GRAY}-${C_RST}"; d_pkg="not packaged on this distro, handled by the script"
    elif [[ "$d_tier" == variant ]] && ! variant_needs_dep "$d_label"; then
      mark="${C_GRAY}-${C_RST}"; d_tier="$(variant_claiming_dep "$d_label") only"
    elif dep_present "$d_kind" "$d_target"; then
      mark="${C_GREEN}✓${C_RST}"
    else
      mark="${C_YELLOW}✗${C_RST}"
    fi
    printf '  %s %-22s %-9s %s\n' "$mark" "$d_label" "$d_tier" "${C_DIM}$d_pkg${C_RST}"
  done
  printf '\n  %s\n\n' "$INSTALL $(dep_packages)"
  [[ -n "${UNKNOWN_DISTRO:-}" ]] \
    && printf '  %s\n\n' "(unrecognized distro; those are Arch package names, adapt as needed)"
  return 0
}

# -----------------------------------------------------------------------------
# repack files in server/
# -----------------------------------------------------------------------------
ensure_repack() {
  if [[ -f "$SERVER/turtle_world.sql" && -d "$SERVER/bin" ]]; then
    say "repack already in server/"; return
  fi
  local zip="$ROOT/TurtleWoW_1.18.zip"
  [[ -f "$zip" ]] || die "server/ is not populated and $zip not found.
  Download the SIGGZ repack (TurtleWoW_1.18.zip) into $ROOT first."
  say "extracting repack into server/"
  mkdir -p "$SERVER"
  bsdtar -xf "$zip" --strip-components=1 -C "$SERVER"
}

# -----------------------------------------------------------------------------
# map data in server/data (dbc, maps, mmaps, vmaps)
# -----------------------------------------------------------------------------
# What DataDir has to hold before mangosd will start.
MAPDATA_DIRS=(dbc maps mmaps vmaps)

ensure_mapdata() {
  local ok=1 d
  for d in "${MAPDATA_DIRS[@]}"; do [[ -d "$SERVER/data/$d" ]] || ok=0; done
  if ((ok)); then say "map data already in server/data/"; return; fi
  local zip="$ROOT/data.zip"
  [[ -f "$zip" ]] || die "server/data is missing dbc/maps/mmaps/vmaps and $zip not found.
  Download SIGGZ's pre-made map data as $zip (or extract it from a client,
  see the setup guide, Section 5)."
  say "extracting map data into server/data/"
  mkdir -p "$SERVER/data"
  bsdtar -xf "$zip" --strip-components=1 -C "$SERVER/data"
}

# -----------------------------------------------------------------------------
# source checkout
# -----------------------------------------------------------------------------
ensure_source() {
  local v src repo branch
  v=$(variant_active); src=$(variant_src)
  variant_migrate_legacy \
    || die "could not move the existing checkout to src/stock; move it by hand and re-run"
  if [[ -f "$src/CMakeLists.txt" ]]; then
    say "$v source already in ${src#"$ROOT"/}"
  else
    repo=$(variant_field "$v" repo); branch=$(variant_field "$v" branch)
    say "cloning $repo ($branch)"
    mkdir -p "$ROOT/src"
    git clone --depth 1 --branch "$branch" "$repo" "$src" \
      || die "git clone failed. Check network access and that branch '$branch' still exists."
  fi
  apply_source_patches
}

# The kit's own fixes for this core, re-applied on every run so a checkout made
# by an older kit picks up one added since. A patch that fits neither way is
# named and let go: upstream has changed underneath it, and the build either no
# longer needs it or fails loudly enough to say so.
apply_source_patches() {
  local stale
  stale=$(variant_apply_patches) && return 0
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    warn "the fix in ${p#"$ROOT"/} no longer fits this source and was left out;
  if the build fails on it, the fix has to be brought forward"
  done <<< "$stale"
  return 0
}

# -----------------------------------------------------------------------------
# ACE library: the distribution's when it is recent enough, otherwise built here
# -----------------------------------------------------------------------------
# Only Debian packages a usable version (13 ships 8.0.2); Fedora, openSUSE and
# Arch package none at all, and Ubuntu 24.04 is on 7.1.2, a major version below
# what the core is built against.
ACE_MIN_MAJOR=8
ACE_FROM=""

# Both the headers and the link library have to be present, or find_package(ACE)
# would fail after the local build had already been skipped. The linker is asked
# directly, since the library sits in a multiarch or lib64 directory depending
# on the distribution, and an absolute path is only returned when it exists.
system_ace() {
  local h=/usr/include/ace/Version.h v
  [[ -f "$h" ]] || return 1
  [[ "$(gcc -print-file-name=libACE.so 2>/dev/null)" == /* ]] || return 1
  v=$(sed -n 's/^#define ACE_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' "$h")
  [[ -n "$v" && "${v%%.*}" -ge "$ACE_MIN_MAJOR" ]] || return 1
  echo "$v"
}

# How far the compile may be parallelized, printed only where a cgroup holds
# this machine to less than it has. nproc counts the host's CPUs even inside a
# container, so an LXC given two cores on a large host would start one compiler
# per host CPU and be killed for it. Nothing is printed when neither a CPU nor
# a memory limit is set, which leaves make and ninja on their own defaults
# everywhere else.
#
# The memory budget comes from measuring this source rather than a rule of
# thumb. Cost per job climbs as parallelism falls, since fewer jobs average out
# fewer light files: 0.6 GB per job at 18 of them, 0.87 GB at 3, against a
# heaviest single file of 1.26 GB. A gigabyte per job is therefore sized for
# the small container, which is the only place this applies. MEM_RESERVE is
# what the rest of the container keeps: its init, and on Debian the packaged
# MariaDB, which is running by then. Page cache is not subtracted, being
# reclaimable under pressure rather than a cause of the kill.
CG=/sys/fs/cgroup
MEM_PER_JOB=$(( 1 << 30 ))
MEM_RESERVE=$(( 1 << 30 ))

# The cgroup's memory ceiling in bytes, printed only where one is set. An unset
# limit reads as "max" on v2 and as a number near INT64_MAX on v1.
mem_limit() {
  local mem=""
  [[ -r $CG/memory.max ]] && mem=$(<"$CG/memory.max")
  [[ -z $mem && -r $CG/memory/memory.limit_in_bytes ]] && mem=$(<"$CG/memory/memory.limit_in_bytes")
  [[ $mem =~ ^[0-9]+$ ]] && ((mem < (1 << 62))) && printf '%s' "$mem"
  return 0
}
build_jobs() {
  local jobs cap quota period mem
  if [[ -n "$TWOW_BUILD_JOBS" ]]; then
    [[ "$TWOW_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] \
      || die "TWOW_BUILD_JOBS must be a whole number of jobs, not '$TWOW_BUILD_JOBS'."
    printf '%s' "$TWOW_BUILD_JOBS"; return 0
  fi
  jobs=$(nproc 2>/dev/null) || return 0
  if [[ -r $CG/cpu.max ]]; then                                   # cgroup v2
    read -r quota period < "$CG/cpu.max" || quota=max
  elif [[ -r $CG/cpu/cpu.cfs_quota_us && -r $CG/cpu/cpu.cfs_period_us ]]; then
    quota=$(<"$CG/cpu/cpu.cfs_quota_us"); period=$(<"$CG/cpu/cpu.cfs_period_us")
  fi
  if [[ ${quota:-} =~ ^[0-9]+$ && ${period:-0} =~ ^[0-9]+$ ]] && ((period > 0)); then
    cap=$(( (quota + period - 1) / period ))
    ((cap > 0 && cap < jobs)) && jobs=$cap
  fi
  mem=$(mem_limit)
  if [[ -n $mem ]]; then
    cap=$(( (mem - MEM_RESERVE) / MEM_PER_JOB )); ((cap < 1)) && cap=1
    ((cap < jobs)) && jobs=$cap
  fi
  ((jobs < $(nproc))) && printf '%s' "$jobs"
  return 0
}

# How many times this cgroup has had a process killed for memory. Compared
# either side of a compile, it separates a compiler the kernel shot from one
# that found a genuine error, which read the same in ninja's output.
oom_kills() {
  local f
  for f in "$CG/memory.events.local" "$CG/memory.events"; do
    [[ -r $f ]] || continue
    awk '$1 == "oom_kill" { print $2; hit = 1 } END { if (!hit) print 0 }' "$f"
    return 0
  done
  echo 0
}

# The compile died for memory rather than for anything in the source. The
# budget below was measured against the tree as it stood, so a heavier upstream
# is the first thing to suspect when it no longer holds.
die_out_of_memory() {
  local jobs="$1" mem="${2:-}" human=""
  [[ "$mem" =~ ^[0-9]+$ ]] && human=$(awk -v b="$mem" 'BEGIN{printf "%.1f GB", b/1073741824}')
  die "the compiler was killed for running out of memory, not by an error in the
  source. This ran ${jobs:-all available} job(s)${human:+ against a $human limit}.

  The job count is worked out from a measurement of this source, so the usual
  cause is that upstream has grown heavier since: a new dependency or a heavier
  header makes each compiler need more than it used to, and the count that fit
  before no longer does.

  Retry with fewer at a time, which is the quickest thing to try:

    TWOW_BUILD_JOBS=1 $0 ${mode:-setup}

  Or give the machine more memory. On Proxmox that is the container's Memory
  setting, raised from the host with:

    pct set <ctid> -memory 8192

  Nothing compiled so far is lost: the build resumes where it stopped, so a
  retry only picks up the files that were still outstanding."
}

# ACE_ROOT is left unset for a packaged ACE, which is where FindACE.cmake finds
# it under /usr; otherwise it points at the tree built below.
select_ace() {
  local v
  if v=$(system_ace); then
    unset ACE_ROOT
    ACE_FROM="the distribution's ACE $v"
  else
    export ACE_ROOT="$ROOT/deps/ACE_wrappers"
    ACE_FROM=""
  fi
}

ensure_ace() {
  select_ace
  [[ -n "$ACE_FROM" ]] && { say "using $ACE_FROM"; return; }
  if [[ -f "$ACE_ROOT/lib/libACE.so" ]]; then say "ACE already built"; return; fi
  say "downloading and building ACE $ACE_VER (a few minutes)"
  mkdir -p "$ROOT/deps"; cd "$ROOT/deps"
  local url="https://github.com/DOCGroup/ACE_TAO/releases/download/ACE%2BTAO-${ACE_VER//./_}/ACE-$ACE_VER.tar.gz"
  [[ -f "ACE-$ACE_VER.tar.gz" ]] || curl -sfLO "$url" \
    || die "could not download ACE from $url
  Check https://github.com/DOCGroup/ACE_TAO/releases for the current name."
  tar xf "ACE-$ACE_VER.tar.gz"
  echo '#include "ace/config-linux.h"' > "$ACE_ROOT/ace/config.h"
  # $(ACE_ROOT) is a make variable and reaches the file literally.
  # shellcheck disable=SC2016
  echo 'include $(ACE_ROOT)/include/makeinclude/platform_linux.GNU' \
    > "$ACE_ROOT/include/makeinclude/platform_macros.GNU"
  local jobs; jobs=$(build_jobs)
  make -C "$ACE_ROOT/ace" -j"${jobs:-$(nproc)}" > "$ROOT/deps/ace-build.log" 2>&1 \
    || die "ACE build failed, see $ROOT/deps/ace-build.log"
  [[ -f "$ACE_ROOT/lib/libACE.so" ]] || die "ACE build produced no libACE.so, see $ROOT/deps/ace-build.log"
}

# -----------------------------------------------------------------------------
# build realmd + mangosd, install into server/bin
# -----------------------------------------------------------------------------
# The binaries in server/bin are asked what they are rather than trusted to be
# what variant.env says: a switch that stopped halfway through is the case where
# the two disagree, and the answer decides whether this compiles or skips.
ensure_binaries() {
  local v build src flags=()
  v=$(variant_active); build=$(variant_build); src=$(variant_src)
  if [[ -x "$SERVER/bin/mangosd" && -x "$SERVER/bin/realmd" \
        && "$(variant_binary_label)" == "$v" ]]; then
    say "native $v binaries already in server/bin/"; variant_save "$v"; return
  fi
  say "configuring and compiling the $v server (10-20 min on first run)"
  mkdir -p "$build"
  read -ra flags <<< "$(variant_field "$v" cmake)"
  cmake -B "$build" -S "$src" -GNinja \
    -DCMAKE_BUILD_TYPE=Release -DDEBUG_SYMBOLS=OFF "${flags[@]}" > "$build/configure.log" 2>&1 \
    || die "cmake configure failed, see ${build#"$ROOT"/}/configure.log"
  local jobs; jobs=$(build_jobs)
  [[ -n "$jobs" ]] && say "holding the compile to $jobs job(s) to stay inside this cgroup's limits"
  local oom_before; oom_before=$(oom_kills)
  if ! ninja -C "$build" ${jobs:+-j"$jobs"} mangosd realmd; then
    (( $(oom_kills) > oom_before )) && die_out_of_memory "$jobs" "$(mem_limit)"
    die "compile failed. Scroll up for the first error; report it on the tortoise-wow GitHub."
  fi
  install_binaries "$build/src/mangosd/mangosd" "$build/src/realmd/realmd"
  # Written where the binaries are, so what this install says it runs and what
  # server/bin actually holds are settled in the same breath.
  variant_save "$v"
  say "installed native $v mangosd and realmd"
}

# -----------------------------------------------------------------------------
# config fixes needed on Linux
# -----------------------------------------------------------------------------
fix_configs() {
  local f
  for f in "$SERVER/bin/realmd.conf" "$SERVER/bin/mangosd.conf"; do
    [[ -f "$f" ]] || die "$f is missing. The repack should provide it;
  re-extract TurtleWoW_1.18.zip or restore the file from it."
  done
  resolve_db_port
  # The repack points these at localhost:3306. "localhost" makes the client
  # library use the distro's default socket path instead of ours, and 3306 is
  # not necessarily where we ended up, so rewrite host and port on every
  # connection string while leaving the user, password and database alone.
  # The two files spell the key differently: realmd.conf has LoginDatabaseInfo,
  # mangosd.conf has WorldDatabase.Info, so the dot is optional. Missing it
  # leaves mangosd pointed at 3306, where a distro MariaDB answers and refuses.
  for f in "$SERVER/bin/realmd.conf" "$SERVER/bin/mangosd.conf"; do
    sed -i -E "s@^([[:space:]]*(Login|World|Character|Logs)Database\.?Info[[:space:]]*=[[:space:]]*\")[^;\"]*;[^;\"]*;@\1$TWOW_DB_HOST;$TWOW_DB_PORT;@" "$f"
  done
  sed -i 's|^DataDir = "\.\./Data"|DataDir = "../data"|' "$SERVER/bin/mangosd.conf"
  # The repack throttles the realm list to one request a second, which drops the
  # second of the pair a client sends over loopback or a LAN. Realmd closes the
  # socket on it, and the login hangs on "Retrieving realm list".
  conf_set "$SERVER/bin/realmd.conf" MinRealmListDelay 0
  # The repack ships mangosd at LogLevel 3 with the SQL echo on, which buries the
  # console under every statement the core runs. Errors only here; the log file
  # keeps its own detail through LogFileLevel, and 'run <level>' overrides it.
  set_console_level 1
  ensure_variant_conf
  write_db_env
  say "configs checked (database $TWOW_DB_HOST:$TWOW_DB_PORT, DataDir lowercase)"
}

# A core that brings a config the repack never shipped gets it put where it
# looks for it, on every run rather than only on a switch: a container or a
# scripted install never passes through 'bots on' at all. An existing file keeps
# the count it was given, and every count derived from it is settled again.
ensure_variant_conf() {  # $1 how many bots, or nothing for what the config asks
  local confs n=${1:-}
  confs=" $(variant_field "$(variant_active)" conf) "
  [[ "$n" =~ ^[0-9]+$ ]] || { n=$(bot_count 2>/dev/null) || n=""; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=$VARIANT_BOTS_DEFAULT
  # The auction house is placed first, so the cohort size settles its switch
  # along with every other count derived from it.
  [[ "$confs" == *" ahbot.conf "* ]] && ensure_ahbot_conf
  [[ "$confs" == *" aiplayerbot.conf "* ]] && ensure_bot_conf "$n"
  return 0
}

# -----------------------------------------------------------------------------
# client safety, if a client is present in client/
#   - defuse the live launcher, which patches the client and needs WebView2
#   - point the client at this server, once the database can say where that is
# -----------------------------------------------------------------------------
fix_client() {
  local client="$ROOT/client"
  [[ -d "$client" ]] || { warn "no client/ folder yet; skipping client fixes"; return; }
  if [[ -f "$client/TurtleWoW.exe" ]]; then
    mv "$client/TurtleWoW.exe" "$client/TurtleWoW.exe.DO-NOT-RUN"
    say "live launcher renamed to TurtleWoW.exe.DO-NOT-RUN (start WoW.exe instead)"
  fi
}

# What the realm advertises now, read by everything that writes it, by the
# client's realmlist.wtf below, and by the question that offers to move it.
realm_address() { DB -N -B -e "SELECT address FROM turtle_logon.realmlist ORDER BY id LIMIT 1" 2>/dev/null; }

# Where the realm answers is settled once, in turtle_logon.realmlist, which the
# LAN question writes. The client reads client/realmlist.wtf, so it is brought
# to the same address rather than asked again; a client carried over from the
# live game points at Turtle's own login server otherwise, and connects there
# instead of here.
sync_client_realmlist() {
  local f="$ROOT/client/realmlist.wtf" addr cur want
  [[ -d "$ROOT/client" ]] || return 0
  addr=$(realm_address) || return 0
  [[ -n "$addr" ]] || return 0
  want="set realmlist $addr"
  cur=$(head -1 "$f" 2>/dev/null | tr -d '\r')
  [[ "$cur" == "$want" ]] && return 0
  printf '%s\n' "$want" > "$f" 2>/dev/null \
    || { warn "could not write ${f#"$ROOT"/}; point it at the realm by hand: $want"; return 0; }
  say "client realmlist -> $addr (was ${cur:-unset})"
}

# Where the realm answers, written in one place. Two things have to agree: the
# address in turtle_logon.realmlist, which is what the login server hands to a
# client, and BindIP in both configs, which is what the server listens on. A
# realm advertising an address it is not bound to accepts nothing.
#
# The bind is derived from the address, since a realm reachable from elsewhere
# has to listen on more than the loopback, but it can be overridden because the
# two legitimately differ behind a port forward: a VM advertises 127.0.0.1 to a
# client on its host while having to bind 0.0.0.0, the forward arriving on the
# guest's own address rather than its loopback.
#
# Prints nothing and records what changed in CHANGES, so the interactive screen
# can summarize it and the realm mode can report in its own voice.
# $1 address, $2 optional bind address
set_realm_address() {
  local addr=$1 bind=${2:-} R="$SERVER/bin/realmd.conf" M="$SERVER/bin/mangosd.conf" cur
  [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "'$addr' is not an IPv4 address"; return 1; }
  [[ -f "$R" && -f "$M" ]] || { warn "no configs in server/bin yet; run: $0 setup"; return 1; }
  if [[ -z "$bind" ]]; then
    bind=0.0.0.0; [[ "$addr" == 127.0.0.1 ]] && bind=127.0.0.1
  fi
  cur=$(realm_address) || cur=""
  if [[ "$addr" != "$cur" ]]; then
    DB -e "UPDATE turtle_logon.realmlist SET address='$addr'" \
      || { warn "could not write the realm address into turtle_logon.realmlist"; return 1; }
    CHANGES+=("realm address: ${cur:-unset} -> $addr")
  fi
  conf_set "$R" BindIP "$bind" quote
  conf_set "$M" BindIP "$bind" quote
  REALM_BIND="$bind"
  return 0
}

# What the realm list shows a client. It lives in turtle_logon.realmlist beside
# the address, and the column is 32 characters wide.
#
# Records what changed in CHANGES and prints only on failure, like the address
# above, so each caller reports in its own voice.
DEFAULT_REALM_NAME=TurtleWoW

realm_name() { DB -N -B -e "SELECT name FROM turtle_logon.realmlist ORDER BY id LIMIT 1" 2>/dev/null; }

set_realm_name() {  # $1 name
  local name=$1 cur warner="${CONF_WARN:-warn}"
  [[ -n "$name" ]] || { "$warner" "a realm name cannot be empty"; return 1; }
  (( ${#name} <= 32 )) || { "$warner" "'$name' is ${#name} characters; the realm list holds 32"; return 1; }
  cur=$(realm_name) || cur=""
  [[ "$name" == "$cur" ]] && return 0
  DB -e "UPDATE turtle_logon.realmlist SET name='${name//\'/\'\'}'" \
    || { "$warner" "could not write the realm name into turtle_logon.realmlist"; return 1; }
  CHANGES+=("realm name: ${cur:-unset} -> $name")
  return 0
}

# Offered once, while every realm the repack ships is still called TurtleWoW.
# A realm that has been named already is left alone, so a repeated setup is
# quiet, and 'interactive' renames it at any later point.
offer_realm_name() {
  local cur CONF_WARN=ui_warn
  cur=$(realm_name) || return 0
  [[ "$cur" == "$DEFAULT_REALM_NAME" ]] || return 0
  ui_intro "name your realm"
  ui_note "shown in the client's realm list; Enter keeps $DEFAULT_REALM_NAME"
  ui_text "Realm name" "$cur"
  if [[ "$ANSWER" == "$cur" ]]; then
    ui_outro "left as $cur"
  elif set_realm_name "$ANSWER"; then
    ui_outro "the realm is now called $ANSWER"
  else
    ui_outro "left as $cur"
  fi
}

# How far the realm reaches. The firewall offer follows a LAN answer, a closed
# port being the remaining thing between an addressed realm and a client on the
# network.
# $1 the address in place, so the list opens on it
offer_realm_address() {
  local cur=${1:-} lanip="" defidx=0 CONF_WARN=ui_warn
  [[ -n "$cur" && "$cur" != 127.0.0.1 ]] && defidx=1
  ui_select "Who can connect?" "$defidx" \
    "Only this machine (127.0.0.1)" \
    "My local network (LAN play)"
  if (( ANSWER == 0 )); then
    set_realm_address 127.0.0.1 || ui_warn "leaving the realm address unchanged"
    return 0
  fi
  (( defidx )) && lanip="$cur"
  [[ -n "$lanip" ]] || lanip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
  ui_text "This machine's LAN IP (clients connect here)" "${lanip:-192.168.?.?}"
  if set_realm_address "$ANSWER"; then
    fw_offer_ports "$(realm_port)" "$(world_port)"
  else
    ui_warn "leaving the realm address unchanged"
  fi
}

# What the world says on its own. The rows in autobroadcast name strings in
# mangos_string, one of which goes out to every player each time the interval
# below elapses.
broadcast_count() { DB -N -B -e "SELECT COUNT(*) FROM turtle_world.autobroadcast" 2>/dev/null; }

broadcast_text() {
  DB -N -B -e "SELECT s.content_default
     FROM turtle_world.autobroadcast a
     JOIN turtle_world.mangos_string s ON s.entry = a.string_id LIMIT 1" 2>/dev/null
}

clear_broadcasts() { DB -e "DELETE FROM turtle_world.autobroadcast"; }

# Minutes between broadcasts, taken from the file the core reads. An absent key
# leaves the core on its compiled-in minute, which stands in here.
broadcast_minutes() {
  local ms
  ms=$(conf_get "$SERVER/bin/mangosd.conf" AutoBroadcast.Timer 2>/dev/null) || ms=""
  [[ "$ms" =~ ^[0-9]+$ ]] || ms=60000
  (( ms >= 60000 )) || ms=60000
  printf '%s\n' $(( ms / 60000 ))
}

# The repack ships one autobroadcast, a disclaimer for a realm somebody might
# take for Turtle's own. Whoever converts an install already knows what it is,
# which leaves the line to taste.
#
# Asked while the repack's rows are in place, the way the realm name is. A
# database that refuses the delete leaves the rows and the setup carries on.
offer_broadcast() {
  local n text mins
  n=$(broadcast_count) || return 0
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  (( n > 0 )) || return 0
  mins=$(broadcast_minutes)
  ui_intro "the realm broadcasts to everyone playing"
  text=$(broadcast_text) || text=""
  [[ -n "$text" ]] && ui_note "\"$text\""
  ui_note "sent in chat every $mins minutes, to every player, while the world runs"
  ui_select "Keep it?" 0 \
    "Yes, keep the repack's broadcast" \
    "No, the realm broadcasts nothing"
  if (( ANSWER == 0 )); then
    ui_outro "left as the repack ships it"
  elif clear_broadcasts; then
    ui_outro "the realm broadcasts nothing"
  else
    ui_warn "could not empty turtle_world.autobroadcast"
    ui_outro "left as the repack ships it"
  fi
  return 0
}

# What a finished install still has to ask, listed once. twow-vm.sh runs the
# conversion detached, which leaves it without a terminal, and calls this over
# one afterwards, so a question added here reaches every path.
#
# Each is asked only until it has been answered: a repeated run is silent.
first_run_questions() {
  local addr bind
  offer_realm_name
  # Asked while the realm sits on the loopback the repack ships and is bound to
  # it. A wider bind under the same address is a port forward, which twow-vm.sh
  # arranges before this runs.
  addr=$(realm_address) || addr=""
  bind=$(conf_get "$SERVER/bin/realmd.conf" BindIP 2>/dev/null) || bind=""
  [[ "$addr" == 127.0.0.1 && "$bind" == 127.0.0.1 ]] && offer_realm_address "$addr"
  offer_broadcast
  has_own_gm || make_gm_account
  # Last of the questions: answering yes compiles the other core, and a compile
  # that fails should not take the game master account down with it.
  offer_bots
}

# Whether a game master account already exists. The repack's own pair is deleted
# during setup, and one that survives it kept its place by having its password
# changed, which makes it somebody's own; either way what is left here counts.
# Asking only while there is none keeps a repeated setup quiet.
has_own_gm() {
  local n
  n=$(DB -N -B -e "SELECT COUNT(*) FROM turtle_logon.account
        WHERE \`rank\` >= 3" 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] && ((n > 0))
}

# Vanilla sends SHA1 of USER:PASS upper-cased, so that is what the column holds.
account_hash() {  # $1 name, $2 password
  printf '%s:%s' "$1" "$2" | sha1sum | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'
}

# Whether an account of this name is here. The name is restricted to what the
# client can type, which keeps it out of the statement as anything but a word.
account_exists() {  # $1 name
  local n
  n=$(DB -N -B -e "SELECT COUNT(*) FROM turtle_logon.account WHERE username = '$1'" 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 ))
}

# Who is on this server, at what level, and when they were last seen. rank 3 and
# above is a game master.
# Bot accounts are the core's own bookkeeping and outnumber the players on a
# populated realm, so the list is people by default and says how many it left
# out.
list_accounts() {  # $1 --all to include the bot accounts
  local prefix where="" hidden=""
  prefix=$(bot_prefix)
  if [[ "${1:-}" != --all ]]; then
    where="WHERE username NOT LIKE '$prefix%'"
    hidden=$(bot_cohort) || hidden=""
  fi
  DB -e "SELECT id, username, \`rank\`, DATE(joindate) AS joined,
                DATE(last_login) AS last_seen, last_ip
           FROM turtle_logon.account $where ORDER BY id" \
    || die "the account list could not be read; is the database up? ($0 status)"
  [[ "$hidden" =~ ^[0-9]+$ ]] && (( hidden )) \
    && say "$hidden bot account(s) left out; --all lists them too"
  return 0
}

# The world console does this with 'account set password', which is reachable
# only from the console itself; this reaches it from a shell.
set_account_password() {  # $1 name
  local acc=${1^^} hash
  [[ "$acc" =~ ^[A-Z0-9_]{3,16}$ ]] || die "an account name is 3-16 letters, digits or underscores"
  account_exists "$acc" || die "no account called $acc ($0 account --list shows them)"
  ui_intro "new password for $acc"
  ui_text "Password" "mysecret"
  local pass=${ANSWER^^}
  [[ -n "$pass" ]] || { ui_warn "a password is required"; ui_outro "unchanged"; return 1; }
  hash=$(account_hash "$acc" "$pass")
  DB -e "UPDATE turtle_logon.account SET sha_pass_hash = '$hash' WHERE username = '$acc'" \
    || { ui_warn "the database refused the change"; ui_outro "unchanged"; return 1; }
  ui_outro "${acc,,} now logs in with the password you gave"
}

# The name is restricted to what the client can type anyway, which also keeps it
# out of the statement below as anything but a plain word.
make_gm_account() {
  local acc pass hash
  ui_intro "game master account"
  ui_note "the world console does the same, once it is up:"
  ui_note "  account create <name> <pass>  and  account set gmlevel <name> 3"
  ui_select "Create a game master account now?" 0 \
    "Yes, create one for me" "Skip, I will use the console"
  (( ANSWER == 0 )) || { ui_outro "skipped; the console commands above still work"; return 0; }
  ui_text "Account name" "apostle"
  acc=${ANSWER^^}
  if [[ ! "$acc" =~ ^[A-Z0-9_]{3,16}$ ]]; then
    ui_warn "an account name is 3-16 letters, digits or underscores"
    ui_outro "not created"; return 0
  fi
  ui_text "Password" "mysecret"
  pass=${ANSWER^^}
  if [[ -z "$pass" ]]; then ui_warn "a password is required"; ui_outro "not created"; return 0; fi
  hash=$(account_hash "$acc" "$pass")
  DB turtle_logon -e "
    INSERT INTO account (username, sha_pass_hash, joindate) VALUES ('$acc','$hash',NOW())
      ON DUPLICATE KEY UPDATE sha_pass_hash='$hash';
    UPDATE account SET \`rank\` = 3 WHERE username = '$acc';" 2>/dev/null \
    || { ui_warn "the database refused the account; the console commands above still work"
         ui_outro "not created"; return 0; }
  ui_outro "log in as ${acc,,} with the password you gave, and you are a game master"
}

# -----------------------------------------------------------------------------
# native database in server/db, seeded from the bundled Windows one
# -----------------------------------------------------------------------------
# The daemon is started by server/1-start-mysql.sh, which is also the manual
# path; waiting for it and vouching for the credentials belong here. Both used
# to start it, and only this one did so carefully.
start_native_db() {
  mkdir -p "$SERVER/logs"
  if mariadb_running; then
    mariadb --socket="$SERVER/db/mysql.sock" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" \
        -e "SELECT 1" >/dev/null 2>&1 \
      || die "the database in server/db is running but rejects $TWOW_DB_USER's password.
  Pass the right one as TWOW_DB_PASS=..., or shut it down and let this script start it:
  mariadb-admin --socket=$SERVER/db/mysql.sock -u $TWOW_DB_USER -p<password> shutdown"
    resolve_db_port
    return
  fi
  resolve_db_port
  [[ -x "$SERVER/1-start-mysql.sh" ]] \
    || die "$SERVER/1-start-mysql.sh is missing or not executable; restore it (chmod +x)."
  say "starting native MariaDB on port $TWOW_DB_PORT"
  ( cd "$SERVER" && nohup ./1-start-mysql.sh > "$SERVER/logs/mysql.out" 2>&1 & )
  # The socket file outlives a stop that never got to clean up, so its presence
  # is not the daemon answering: a killed container or a lost power leaves one
  # behind, and waiting on the file alone declared the database up before it had
  # started. ping answers for a live server whatever it makes of the password,
  # and crash recovery is what the wait is long enough for.
  local i; for i in $(seq 1 60); do mariadb_running && break; sleep 1; done
  mariadb_running || die "MariaDB did not come up. Last lines of ${SERVER#"$ROOT"/}/logs/mysql.out:

$(tail -n 15 "$SERVER/logs/mysql.out" 2>/dev/null | sed 's/^/  /')"
  write_db_env
}

# The root password is only set when the data dir is created, so a server/db
# left by an earlier run can hold a root account that refuses this script's
# password over TCP; a data dir from before this script set an auth method has
# root on unix_socket, which no password can satisfy. The local socket is the
# way back in, since it reaches this project's server alone and its root still
# answers there.
ensure_db_credentials() {
  DB -e "SELECT 1" >/dev/null 2>&1 && return 0
  warn "the database in server/db does not accept $TWOW_DB_USER's password over
  $TWOW_DB_HOST:$TWOW_DB_PORT; repairing the account through the local socket"
  mariadb --socket="$SERVER/db/mysql.sock" -u "$TWOW_DB_USER" -e "
    ALTER USER '$TWOW_DB_USER'@'localhost' IDENTIFIED BY '$TWOW_DB_PASS';
    CREATE USER IF NOT EXISTS '$TWOW_DB_USER'@'127.0.0.1' IDENTIFIED BY '$TWOW_DB_PASS';
    GRANT ALL PRIVILEGES ON *.* TO '$TWOW_DB_USER'@'127.0.0.1' WITH GRANT OPTION;
    FLUSH PRIVILEGES;" >/dev/null 2>&1 \
    || die "the database in server/db rejects $TWOW_DB_USER and the socket refuses it too.
  Give the right password as TWOW_DB_PASS=... $0 ${mode:-setup}, or stop the database
  and delete ${SERVER#"$ROOT"/}/db to start it over (the game databases are seeded again;
  nothing else is kept there)."
  DB -e "SELECT 1" >/dev/null 2>&1 \
    || die "the account was repaired but $TWOW_DB_HOST:$TWOW_DB_PORT still refuses it,
  which means that port is answered by a different MariaDB than the one in
  ${SERVER#"$ROOT"/}/db. Stop that one, or pick another port: TWOW_DB_PORT=<port> $0 ${mode:-setup}"
  say "root's password repaired"
}

# Everything below writes the game databases, so the far end has to be this
# project's own server. A port is just as happily answered by a distro MariaDB
# service, and seeding into that would land in someone else's data.
assert_own_database() {
  local dd want="$SERVER/db"
  dd=$(DB -N -B -e "SELECT @@datadir" 2>/dev/null) || dd=""
  [[ -n "$dd" ]] || die "could not ask $TWOW_DB_HOST:$TWOW_DB_PORT where it keeps its data."
  dd="${dd%/}"
  if command -v realpath >/dev/null 2>&1; then
    dd=$(realpath -m "$dd"); want=$(realpath -m "$want")
  fi
  [[ "$dd" == "$want" ]] || die "the MariaDB on $TWOW_DB_HOST:$TWOW_DB_PORT stores its data in
  $dd, not in $want, so it belongs to something else (a distro
  mariadb service?). Stop it, or run this on another port:
  TWOW_DB_PORT=<port> $0 ${mode:-setup}"
}

ensure_database() {
  mkdir -p "$SERVER/logs"
  resolve_db_port
  sync_my_cnf
  if [[ ! -d "$SERVER/db/mysql" ]]; then
    say "initializing native MariaDB data dir in server/db"
    mariadb-install-db --no-defaults --datadir="$SERVER/db" \
      --auth-root-authentication-method=normal > "$SERVER/logs/mysql-install.log" 2>&1 \
      || die "mariadb-install-db failed, see $SERVER/logs/mysql-install.log"
    start_native_db
    mariadb --socket="$SERVER/db/mysql.sock" -u root -e "
      ALTER USER 'root'@'localhost' IDENTIFIED BY '$TWOW_DB_PASS';
      CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$TWOW_DB_PASS';
      GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
      FLUSH PRIVILEGES;" || die "could not set the root password"
  else
    start_native_db
  fi
  ensure_db_credentials
  assert_own_database

  if DB -N -e "SELECT 1 FROM turtle_logon.account LIMIT 1" >/dev/null 2>&1; then
    say "game databases already present"; return
  fi

  # Seed: dump the four preloaded DBs out of the bundled Windows MariaDB.
  # One-time only; needs wine. The package name comes from the DEPS table so
  # this message cannot drift away from what check_deps warns about earlier.
  #
  # A native daemon cannot stand in here, which is not obvious and has been
  # tried: the repack's data directory carries a redo log that was never
  # cleanly shut down, and only 10.4 or earlier can apply one written by 10.3,
  # so 11.x and 12.x refuse it with "Upgrade after a crash is not supported".
  # Skipping recovery with innodb-force-recovery=6 does start and does dump
  # every row, but the auto-increment counters live in that log and nowhere
  # else, and they come back as MAX(id)+1: turtle_world.creature alone drops
  # from 9584715 to 2902648, handing new spawns guids that were used before.
  # The bundled 10.3 mysqld is the only engine that reads the log, and wine is
  # the only way to run it here.
  command -v wine >/dev/null 2>&1 \
    || die "game databases are empty and seeding them needs wine once ($INSTALL $(dep_pkg_of wine)).
  Alternative: import dumps you already have into $TWOW_DB_HOST:$TWOW_DB_PORT."
  local windb="$SERVER/mariadb-10.3.39-winx64"
  [[ -d "$windb/data/turtle_logon" ]] \
    || die "bundled Windows MariaDB data not found in $windb; cannot seed the databases."
  # 3307 by habit, but it is only borrowed for a minute and anything may hold it.
  local sp seedport=""
  for sp in 3307 3313 3314 3315; do port_free "$sp" && { seedport=$sp; break; }; done
  [[ -n "$seedport" ]] \
    || die "no free port for the one-time seeding instance (tried 3307 and 3313-3315)."
  say "seeding databases from the bundled Windows MariaDB (via wine, one time)"
  ( cd "$windb/bin" && nohup wine mysqld.exe --console --port="$seedport" \
      > "$SERVER/logs/wine-mysql.out" 2>&1 & )
  local i; for i in $(seq 1 60); do
    mariadb -h 127.0.0.1 -P "$seedport" -u root -p"$TWOW_SEED_PASS" --skip-ssl -e "SELECT 1" >/dev/null 2>&1 && break
    sleep 2
  done
  mariadb -h 127.0.0.1 -P "$seedport" -u root -p"$TWOW_SEED_PASS" --skip-ssl -e "SELECT 1" >/dev/null 2>&1 \
    || die "the bundled Windows MariaDB did not answer on port $seedport, see $SERVER/logs/wine-mysql.out
  It is reached with the repack's own root password. If yours differs from the
  default, give it as TWOW_SEED_PASS=... $0 ${mode:-setup} (TWOW_DB_PASS is this
  server's password and is not used here)."
  mariadb-dump -h 127.0.0.1 -P "$seedport" -u root -p"$TWOW_SEED_PASS" --skip-ssl --routines --triggers \
    --databases turtle_logon turtle_char turtle_logs turtle_world > "$SERVER/logs/seed-dump.sql" \
    || die "dumping from the wine MariaDB failed"
  mariadb-admin -h 127.0.0.1 -P "$seedport" -u root -p"$TWOW_SEED_PASS" --skip-ssl shutdown || true
  say "importing the seed dump into native MariaDB"
  DB < "$SERVER/logs/seed-dump.sql" || die "import of the seed dump failed"
}

# -----------------------------------------------------------------------------
# accounts and characters the repack's dump carries from the server it was
# sliced out of
# -----------------------------------------------------------------------------
# turtle_logon arrives with ADMIN and TEST at SEC_ADMINISTRATOR, each holding
# its own name as its password, so a realm reachable on the LAN hands full
# administrator rights to anyone who finds port 3724. Both go, and the account
# counter starts again at 1.
#
# turtle_char arrives with six level 60s whose accounts stayed behind and two
# pets whose owners were deleted before the export. Guids are handed out from
# MAX(guid)+1, which lands on one of those owners, so the first character
# created adopts a stray pet whatever its class.
#
# Scope is what the dump brought with it. An account whose password has been
# changed is somebody's own and stays, as does a character with an account and
# a pet whose owner exists. Removing the two accounts leaves their characters
# ownerless, which is what the sweep below is for, so the order matters.
# The pair the repack ships, recognised by the password it set them: an account
# whose password has been changed belongs to whoever changed it.
# A password equal to the account's own name. Vanilla stores SHA1 of USER:PASS
# upper-cased, so the repack's shipped pair is recognisable by the hash alone.
SELF_PASS="sha_pass_hash = UPPER(SHA1(CONCAT(username, ':', username)))"
SEED_STOCK="username IN ('ADMIN','TEST') AND $SELF_PASS"

# What the dump still has here, one count each, so the sweep can subtract a
# total honestly and the doctor mode can name what it found.
count_stock_accounts() {
  DB -N -B -e "SELECT COUNT(*) FROM turtle_logon.account WHERE $SEED_STOCK" 2>/dev/null
}
count_orphan_characters() {
  DB -N -B -e "SELECT COUNT(*) FROM turtle_char.characters c
     LEFT JOIN turtle_logon.account a ON a.id = c.account WHERE a.id IS NULL" 2>/dev/null
}
count_orphan_pets() {
  DB -N -B -e "SELECT COUNT(*) FROM turtle_char.character_pet p
     LEFT JOIN turtle_char.characters c ON c.guid = p.owner WHERE c.guid IS NULL" 2>/dev/null
}

seed_leftovers() {
  local a b c
  a=$(count_stock_accounts)    || return 1
  b=$(count_orphan_characters) || return 1
  c=$(count_orphan_pets)       || return 1
  printf '%s\n' "$(( a + b + c ))"
}

# Removes the accounts a predicate selects, everything filed under them, and
# every character and pet left without an owner. The predicate is the only
# difference between clearing the pair the repack ships and emptying the realm,
# so the tables below are listed once.
# $1 an SQL predicate over turtle_logon.account
sweep_accounts() {
  local pred=$1
  DB turtle_char <<SQL >/dev/null 2>&1
CREATE TEMPORARY TABLE twow_stock (id INT UNSIGNED PRIMARY KEY);
INSERT INTO twow_stock
  SELECT id FROM turtle_logon.account
   WHERE $pred;

DELETE t FROM turtle_logon.account_ip_logins  t JOIN twow_stock s ON s.id = t.account_id;
DELETE t FROM turtle_logon.account_banned     t JOIN twow_stock s ON s.id = t.id;
DELETE t FROM turtle_logon.account_muted      t JOIN twow_stock s ON s.id = t.id;
DELETE t FROM turtle_logon.shop_coins         t JOIN twow_stock s ON s.id = t.id;
DELETE t FROM turtle_logon.rbac_account_permissions t JOIN twow_stock s ON s.id = t.account_id;
DELETE t FROM account_data                    t JOIN twow_stock s ON s.id = t.account;
DELETE t FROM character_tutorial              t JOIN twow_stock s ON s.id = t.account;
DELETE t FROM whisper_targets                 t JOIN twow_stock s ON s.id = t.account;
DELETE t FROM turtle_logon.account            t JOIN twow_stock s ON s.id = t.id;

CREATE TEMPORARY TABLE twow_gone (guid INT UNSIGNED PRIMARY KEY);
INSERT INTO twow_gone
  SELECT c.guid FROM characters c
    LEFT JOIN turtle_logon.account a ON a.id = c.account WHERE a.id IS NULL;

DELETE t FROM character_account_data     t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_action           t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_armory_stats     t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_aura             t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_aura_suspended   t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_battleground_data t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_forgotten_skills t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_gifts            t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_homebind         t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_honor_cp         t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_instance         t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_inventory        t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_item_logs        t JOIN twow_gone g ON g.guid = t.playerLowGuid;
DELETE t FROM character_queststatus      t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_reputation       t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_skills           t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_social           t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_social           t JOIN twow_gone g ON g.guid = t.friend;
DELETE t FROM character_spell            t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_spell_cooldown   t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_spell_dual_spec  t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_stats            t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_ticket           t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_titles           t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_transmogs        t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM character_xp_from_log      t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM corpse                     t JOIN twow_gone g ON g.guid = t.player;
DELETE t FROM gm_surveys                 t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM gm_tickets                 t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM guild_bank_log             t JOIN twow_gone g ON g.guid = t.player;
DELETE t FROM guild_member               t JOIN twow_gone g ON g.guid = t.guid;
DELETE t FROM item_instance              t JOIN twow_gone g ON g.guid = t.owner_guid;
DELETE t FROM mail_items                 t JOIN twow_gone g ON g.guid = t.receiver;
DELETE t FROM mail                       t JOIN twow_gone g ON g.guid = t.receiver;
DELETE t FROM characters                 t JOIN twow_gone g ON g.guid = t.guid;

DELETE p FROM character_pet p LEFT JOIN characters c ON c.guid = p.owner WHERE c.guid IS NULL;
DELETE t FROM pet_aura          t LEFT JOIN character_pet p ON p.id = t.guid WHERE p.id IS NULL;
DELETE t FROM pet_spell         t LEFT JOIN character_pet p ON p.id = t.guid WHERE p.id IS NULL;
DELETE t FROM pet_spell_cooldown t LEFT JOIN character_pet p ON p.id = t.guid WHERE p.id IS NULL;

ALTER TABLE turtle_logon.account AUTO_INCREMENT = 1;
SQL
}

clean_seed_leftovers() {
  local before after stock
  stock=$(count_stock_accounts) || stock=0
  before=$(seed_leftovers) || return 0
  [[ "$before" =~ ^[0-9]+$ ]] || return 0
  (( before > 0 )) || return 0

  sweep_accounts "$SEED_STOCK" \
    || { warn "could not clear what the repack's dump left behind; ADMIN and TEST may still be able to log in"; return 0; }

  after=$(seed_leftovers) || after=0
  say "cleared $(( before - after )) row(s) the repack's dump arrived with; the realm starts empty"
  (( stock > 0 )) && say "ADMIN and TEST are gone with it; an account keeps its place here once its password is changed"
  return 0
}

# -----------------------------------------------------------------------------
# bring the database schema up to what the compiled source expects
# -----------------------------------------------------------------------------
ensure_migrations() {
  [[ -x "$SERVER/apply-db-updates.sh" ]] \
    || die "$SERVER/apply-db-updates.sh is missing; restore it from the repo."
  "$SERVER/apply-db-updates.sh"
}

# -----------------------------------------------------------------------------
# Interactive mode: a guided, clack-style prompt for the most common options.
# Text fields come pre-filled with the current value (Enter keeps it), lists
# are picked with the arrow keys. Nothing is written unless a value changed.
# The prompts themselves live in lib/ui.sh, shared with twow-vm.sh.
# -----------------------------------------------------------------------------
CHANGES=()

interactive_config() {
  local M="$SERVER/bin/mangosd.conf" R="$SERVER/bin/realmd.conf" RATE="$SERVER/bin/rate.conf"
  [[ -f "$M" && -f "$R" ]] || die "no configs in server/bin yet; run: $0 setup"
  trap 'printf "\033[?25h\n"; exit 130' INT
  # A skipped key is reported in the gutter here, not in the log prefix the
  # other modes speak in.
  local CONF_WARN=ui_warn

  # realm name/address live in the turtle_logon DB; bring it up if it exists
  local have_db=0 rname="" raddr=""
  if [[ -d "$SERVER/db/mysql" ]]; then
    start_native_db
    if rname="$(realm_name)"; then
      have_db=1
      raddr="$(realm_address)" || raddr=""
    fi
  fi

  ui_banner "apne's all-in-one CLI" "for TurtleWoW on Linux"
  ui_intro "server configuration"
  ui_note "Enter keeps the shown value · pick from lists with ↑/↓ + Enter · Ctrl+C quits"
  ui_note "free software, GPL-3.0-or-later, with no warranty · terms: $0 license"

  if (( have_db )); then
    ui_text "Realm name (shown in the in-game realm list)" "$rname"
    set_realm_name "$ANSWER" || ui_warn "the realm name is still $rname"

    offer_realm_address "$raddr"
  else
    ui_note "realm name/address live in the database, which is not initialized yet;"
    ui_note "run '$0 setup' first, then come back here"
  fi

  local gt gtidx=0 i
  gt="$(conf_get "$M" GameType)"
  local gtvals=(0 1 6 8)
  for i in "${!gtvals[@]}"; do [[ "${gtvals[i]}" == "$gt" ]] && gtidx=$i; done
  ui_select "Game type" "$gtidx" "Normal / PvE" "PvP" "RP (Turtle default)" "RP-PvP"
  conf_set "$M" GameType "${gtvals[ANSWER]}"

  ui_text "Message of the day" "$(conf_get "$M" Motd)"
  conf_set "$M" Motd "$ANSWER" quote

  local xp; xp="$(conf_get "$M" Rate.XP.Kill)"
  ui_num "XP rate (kill/quest/explore, 1 = Blizzlike)" "$xp"
  if [[ "$ANSWER" != "$xp" ]]; then
    conf_set "$M" Rate.XP.Kill "$ANSWER"
    conf_set "$M" Rate.XP.Quest "$ANSWER"
    conf_set "$M" Rate.XP.Explore "$ANSWER"
  fi
  if [[ -f "$RATE" ]] \
      && grep -E '^Rate\.XP\.Kill' "$RATE" | tr -d '\r' | grep -vqE '=[[:space:]]*1$'; then
    ui_select "rate.conf also scales kill XP per level bracket (Turtle tuning)" 0 \
      "Keep the per-bracket tuning" \
      "Flatten all brackets to 1x (my XP rate applies at every level)"
    if (( ANSWER == 1 )); then
      sed -i 's/^Rate\.XP\.Kill.*/Rate.XP.Kill    = 1/' "$RATE"
      CHANGES+=("rate.conf: all level brackets flattened to 1x")
    fi
  fi

  # Scales Turtle's shipped tuning (uncommon 2x, everything else 1x), so
  # 1 always restores the authentic defaults no matter what was set before.
  local dr q; dr="$(conf_get "$M" Rate.Drop.Item.Rare)"
  ui_num "Item drop rate (1 = Turtle default: uncommon 2x, rest 1x)" "$dr"
  for q in Poor Normal Uncommon Rare Epic Legendary Artifact Referenced; do
    if [[ "$q" == Uncommon ]]; then
      conf_set "$M" "Rate.Drop.Item.$q" "$(awk -v a="$ANSWER" 'BEGIN{print a*2}')"
    else
      conf_set "$M" "Rate.Drop.Item.$q" "$ANSWER"
    fi
  done

  ui_num "Money drop rate" "$(conf_get "$M" Rate.Drop.Money)"
  conf_set "$M" Rate.Drop.Money "$ANSWER"

  ui_num "Honor rate" "$(conf_get "$M" Rate.Honor)"
  conf_set "$M" Rate.Honor "$ANSWER"

  local rr; rr="$(conf_get "$M" Rate.Rest.InGame)"
  ui_num "Rest bonus rate (inns and cities)" "$rr"
  if [[ "$ANSWER" != "$rr" ]]; then
    conf_set "$M" Rate.Rest.InGame "$ANSWER"
    conf_set "$M" Rate.Rest.Offline.InTavernOrCity "$ANSWER"
  fi

  ui_num "Player limit (0 = unlimited)" "$(conf_get "$M" PlayerLimit)"
  conf_set "$M" PlayerLimit "$ANSWER"

  ui_num "Starting level for new characters" "$(conf_get "$M" StartPlayerLevel)"
  conf_set "$M" StartPlayerLevel "$ANSWER"

  # The cohort size is a setting like the rest once bots are on; turning them on
  # is a compile, which is not something a form should start.
  if [[ "$(variant_active)" == bots && -f "$BOT_CONF" ]]; then
    ui_num "AI players the realm asks for" "$(bot_count)"
    set_bot_count "${ANSWER%%.*}"
  else
    ui_note "'$0 bots on' populates the world with AI players"
  fi

  # The realm address may have moved just now, and the client follows it.
  sync_client_realmlist
  if (( ${#CHANGES[@]} )); then
    printf '%s\n' "$GUT"
    local c; for c in "${CHANGES[@]}"; do
      printf '%s  %s %s\n' "$GUT" "${C_GREEN}✔${C_RST}" "$c"
    done
    ui_outro "saved - restart the server ('$0 run') to apply"
  else
    ui_outro "nothing changed"
  fi
}

# -----------------------------------------------------------------------------
# AI players: the other core, and the cohort it keeps
# -----------------------------------------------------------------------------
# One command decides which core this install runs, because populating the world
# is the only thing anyone wants from it; which fork, branch, build option and
# dependency that means is lib/variant.sh's business and is named nowhere else.
# A switch never touches accounts or characters: the databases either core reads
# differently are the world's, and the bots' own tables are seeded once and left
# alone from then on.
BOT_CONF="$SERVER/bin/aiplayerbot.conf"
# The auction house the bots trade on. It is the same module and the same
# lifetime as the players, so it is placed and carried forward with them.
AHBOT_CONF="$SERVER/bin/ahbot.conf"

# The dist a module config is copied from. A build generates one beside the
# module; the source's own copy stands in where a build tree has been cleared,
# and each subsystem keeps that one in a directory of its own.
# $1 the file's name, as it is called beside mangosd.conf
bot_conf_dist() {
  local b s
  b="$(variant_build)/src/modules/PlayerBots/$1.dist"
  [[ -f "$b" ]] && { printf '%s' "$b"; return 0; }
  for s in "$(variant_src)"/src/modules/PlayerBots/*/"$1.dist.in"; do
    [[ -f "$s" ]] && { printf '%s' "$s"; return 0; }
  done
  return 1
}

# The core fills every account it creates with nine characters on this
# expansion and draws the cohort from that pool, so the account count is what
# decides how many characters a first boot writes.
BOT_CHARS_PER_ACCOUNT=9
bot_accounts_for() {  # $1 how many bots
  printf '%s' "$(( ( ${1:-0} + BOT_CHARS_PER_ACCOUNT - 1) / BOT_CHARS_PER_ACCOUNT ))"
}

# Guilds are founded by bots and filled from the same pool, so the shipped
# twenty would leave a small realm with a guild per bot.
BOT_GUILDS_MAX=20
bot_guilds_for() {  # $1 how many bots
  local g; g=$(bot_accounts_for "${1:-0}")
  (( g > BOT_GUILDS_MAX )) && g=$BOT_GUILDS_MAX
  printf '%s' "$g"
}

# What the config asks for, and what the realm holds. The two differ while a
# cohort is still being built, which is why both are reported.
bot_count()  { conf_get "$BOT_CONF" AiPlayerbot.MinRandomBots 2>/dev/null; }
bot_prefix() {
  local p; p=$(conf_get "$BOT_CONF" AiPlayerbot.RandomBotAccountPrefix 2>/dev/null)
  printf '%s' "${p:-RNDBOT}"
}
bot_cohort() {
  DB -N -B -e "SELECT COUNT(*) FROM turtle_logon.account
     WHERE username LIKE '$(bot_prefix)%'" 2>/dev/null
}

# The characters those accounts hold, which is what the cohort is drawn from
# and what every character backup carries.
bot_characters() {
  DB -N -B -e "SELECT COUNT(*) FROM turtle_char.characters c
          JOIN turtle_logon.account a ON a.id = c.account
         WHERE a.username LIKE '$(bot_prefix)%'" 2>/dev/null
}

# Puts the bot config where the core looks for it, which is beside mangosd.conf,
# and settles the three keys that decide what a boot does. The shipped file asks
# for a thousand bots, and for one boot in ten thousand to wipe the cohort and
# build it again.
ensure_bot_conf() {  # $1 how many bots
  place_module_conf "$BOT_CONF"
  conf_set "$BOT_CONF" AiPlayerbot.Enabled 1
  set_bot_count "$1"
  # One boot with this set wipes the cohort and creates it again. That is a
  # reset somebody asks for by hand, never what a switch leaves behind.
  conf_set "$BOT_CONF" AiPlayerbot.DeleteRandomBotAccounts 0
}

# Every count the core derives from the cohort moves with it. Both ends of the
# range are set, since a range creates bots up to the top and logs in as few as
# the bottom, and the account count with them: the shipped five hundred accounts
# write four and a half thousand characters whatever the cohort asks for.
set_bot_count() {  # $1 how many
  conf_set "$BOT_CONF" AiPlayerbot.MinRandomBots "$1"
  conf_set "$BOT_CONF" AiPlayerbot.MaxRandomBots "$1"
  conf_set "$BOT_CONF" AiPlayerbot.RandomBotAccountCount "$(bot_accounts_for "$1")"
  conf_set "$BOT_CONF" AiPlayerbot.RandomBotGuildCount "$(bot_guilds_for "$1")"
  # The auction house runs on the cohort's own characters, so a realm that asks
  # for no bots has nobody to trade and the core would report that every
  # quarter of an hour.
  [[ -f "$AHBOT_CONF" ]] \
    && conf_set "$AHBOT_CONF" AhBot.Enabled "$([[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )) && echo 1 || echo 0)"
  return 0
}

# Settings the core has gained since this copy was made, as whole lines from
# the current dist. Commented lines are the core's own defaults and are left
# where they are.
# $1 the config in server/bin
bot_conf_missing() {
  [[ -f "$1" ]] || return 0
  local dist line key
  dist=$(bot_conf_dist "${1##*/}") || return 0
  while IFS= read -r line; do
    key=${line%%=*}; key=${key%"${key##*[![:space:]]}"}
    conf_has "$1" "$key" || printf '%s\n' "$line"
  done < <(grep -E '^[A-Za-z][A-Za-z0-9_.]*[[:space:]]*=' "$dist")
  return 0
}

# Takes those in at the values the core ships them at. What the file already
# holds is left alone, so a cohort size and any hand edit survive an update.
# $1 the config in server/bin
bot_conf_freshen() {
  local line added=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # A file whose last line was never terminated would take the first addition
    # onto the end of it.
    [[ -s "$1" && -z "$(tail -c1 "$1")" ]] || printf '\n' >> "$1"
    printf '%s\n' "$line" >> "$1"
    added=$(( added + 1 ))
  done < <(bot_conf_missing "$1")
  (( added )) && say "$added new setting(s) in ${1##*/}, taken from the core's own defaults"
  return 0
}

# Copies a module config into server/bin, where the core reads it from beside
# mangosd.conf, and brings one already there forward.
# $1 the config in server/bin
place_module_conf() {
  local dist name=${1##*/}
  if [[ ! -f "$1" ]]; then
    dist=$(bot_conf_dist "$name") || die "the $(variant_active) source carries no $name to copy;
  re-run '$0 bots on' once the source is in place"
    cp "$dist" "$1" || die "could not write $1"
    say "$name placed beside mangosd.conf, where the core looks for it"
  fi
  bot_conf_freshen "$1"
}

# The auction house the bots trade on, put where the core reads it from. What
# it needs beyond that is the cohort itself: bidders and sellers are the bots'
# own characters, which is why AhBot.GUID is left at zero - it names the one
# character to fall back on where a realm has no bot accounts at all.
ensure_ahbot_conf() {
  place_module_conf "$AHBOT_CONF"
}

# The number is asked rather than assumed: it decides how long the next boot
# takes and how much of every character backup is bots. Answers land in
# BOT_COUNT, since the prompts are drawn on stdout and a captured call would
# swallow the screen.
ask_bot_count() {
  BOT_COUNT=$(bot_count 2>/dev/null) || BOT_COUNT=""
  [[ "$BOT_COUNT" =~ ^[0-9]+$ ]] || BOT_COUNT=$VARIANT_BOTS_DEFAULT
  [[ -t 0 ]] || return 0
  ui_intro "how many"
  ui_note "each bot is a character that levels, quests, groups and trades"
  ui_note "they run the auction house between them, so it is stocked from the first boot"
  ui_note "the first boot builds their caches, which takes longer the more there are"
  ui_num "How many bots?" "$BOT_COUNT"
  BOT_COUNT=${ANSWER%%.*}
  ui_outro "$BOT_COUNT bots"
}

# Which core is running, whether server/bin agrees, and what changing costs.
bots_report() {
  local v built other want n
  v=$(variant_active)
  built=$(variant_binary_label) || built=""
  if [[ "$v" == bots ]]; then say "on - $(variant_field bots summary)"
  else say "off - $(variant_field stock summary)"; fi
  if [[ -n "$built" && "$built" != "$v" ]]; then
    warn "server/bin holds a $built build, so this install is mid-switch;
  finish it with: $0 bots $([[ "$v" == bots ]] && echo on || echo off)"
  fi
  if [[ "$v" == bots && -f "$BOT_CONF" ]]; then
    want=$(bot_count); n=$(bot_characters) || n=""
    say "cohort    $want asked for in aiplayerbot.conf${n:+, $n character(s) in the realm now}"
    [[ -f "$AHBOT_CONF" ]] \
      && say "auctions  $([[ "$(conf_get "$AHBOT_CONF" AhBot.Enabled)" == 1 ]] \
              && echo "run by the bots, buying and selling as their own characters" \
              || echo "off in ahbot.conf")"
  fi
  other=bots; [[ "$v" == bots ]] && other=stock
  if [[ -d "$(TWOW_VARIANT=$other variant_src)" && -d "$(TWOW_VARIANT=$other variant_build)" ]]; then
    say "$0 bots $([[ "$other" == bots ]] && echo on || echo off) switches in a minute; the $other tree is still here"
  else
    say "$0 bots $([[ "$other" == bots ]] && echo on || echo off) clones and compiles that core once, 10-20 minutes"
  fi
  return 0
}

# Switching is the same work setup does, aimed at the other core: check what it
# needs before an hour of compiling, build it, and only then write down which
# core this install runs, so a switch that fails partway leaves a record that
# still matches the binaries in server/bin.
bots_switch() {  # $1 target label, $2.. options
  local target=$1 count=""; shift
  while (( $# )); do
    case "$1" in
      --count) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--count needs a number"
               count=$2; shift 2 ;;
      *)       die "unknown option '$1'; bots takes --count <number>" ;;
    esac
  done
  [[ -x "$SERVER/bin/mangosd" ]] || die "not converted yet; run: $0 setup"
  assert_servers_stopped

  export TWOW_VARIANT="$target"
  say "switching to the $target core; accounts and characters are not touched"
  check_deps
  ensure_source
  ensure_ace
  ensure_binaries

  if [[ "$target" == bots ]]; then
    if [[ -n "$count" ]]; then BOT_COUNT=$count; else ask_bot_count; fi
    ensure_variant_conf "$BOT_COUNT"
  fi

  start_native_db
  ensure_db_credentials
  assert_own_database
  backup_before_migrations "$target"
  ensure_migrations
  [[ "$target" == stock ]] && offer_bot_purge

  say "this install now runs the $target core; start it with: $0 run"
  [[ "$target" == bots ]] \
    && say "the first boot builds the bots' caches and creates them, which takes a few minutes"
  return 0
}

# The bots and everything filed under them, cleared with the same sweep the
# repack's own accounts get. A cohort is bookkeeping rather than anybody's
# characters: the next boot writes it again, up to whatever the config asks for.
bots_purge() {  # $1 the --yes flag as given
  local prefix n c
  prefix=$(bot_prefix)
  n=$(bot_cohort) || n=0; c=$(bot_characters) || c=0
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) \
    || { say "no bot accounts in the realm"; return 0; }
  world_running && die "the world server is running, and it holds the bots; stop it first: $0 stop"
  confirm_destructive "the $n bot account(s) on this realm go, and the $c character(s)
  they hold with them. The next boot creates them again, up to the cohort
  aiplayerbot.conf asks for." "${1:-}" || return 0
  sweep_accounts "username LIKE '$prefix%'" \
    || die "the database refused the sweep; nothing is guaranteed removed"
  say "removed $n bot account(s) and the $c character(s) they held"
  return 0
}

# Bots left behind after a switch back log in nowhere, sit in every character
# backup, and mean nothing to the stock core. Clearing them is offered at the
# moment they stop belonging to anything.
offer_bot_purge() {
  local n
  n=$(bot_cohort) || return 0
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || return 0
  # Removing characters is answered for, never assumed: a run with no terminal
  # keeps them and says how they go.
  if [[ ! -t 0 ]]; then
    say "$n bot account(s) stay in the realm; clear them with: $0 bots --purge"
    return 0
  fi
  ui_intro "$n bot account(s) are still in the realm"
  ui_note "they belong to the other core; here they are characters nobody plays"
  ui_note "keeping them costs a slower backup, and they come back the moment bots are on again"
  ui_select "Remove them?" 0 \
    "Yes, remove the bots and their characters" \
    "No, leave them where they are"
  if (( ANSWER == 1 )); then ui_outro "left in place; clear them later with: $0 bots --purge"; return 0; fi
  ui_outro "clearing the bots"
  bots_purge --yes
}

# Packages the bots core needs and this system has not got. Tier and claim both
# come from the tables, so a second dependency for that core needs nothing here.
bots_deps_missing() {
  local row out=() d_label d_kind d_target d_tier d_deb d_fed d_suse d_arch d_pkg
  for row in "${DEPS[@]}"; do
    dep_parse "$row"
    [[ "$d_tier" == variant && " $(variant_claiming_dep "$d_label") " == *" bots "* ]] || continue
    dep_present "$d_kind" "$d_target" || out+=("$d_pkg")
  done
  printf '%s' "${out[*]}"
}

# Asked once, during the first setup, in the same breath as the realm name and
# the broadcast. Answering no is a keypress and is never asked again.
offer_bots() {
  [[ "$(variant_active)" == stock ]] || return 0
  # A question whose yes ends in a missing header twenty minutes later is worse
  # than no question: the packages are named instead, and the mode stays open.
  local absent; absent=$(bots_deps_missing)
  if [[ -n "$absent" ]]; then
    warn "AI players need $absent, which this system has not got.
  Install it and they are one command away: $INSTALL $absent
  then: $0 bots on"
    return 0
  fi
  ui_intro "AI players"
  ui_note "a cohort of bots that level, quest, group and trade, so the world is not empty"
  ui_note "they stock the auction house between them, as their own characters"
  ui_note "they run on a fork of the core, which is compiled once: 10-20 minutes"
  ui_select "Populate the world with AI players?" 0 \
    "No, just me and whoever I invite" \
    "Yes, add AI players"
  if (( ANSWER == 0 )); then
    ui_outro "no bots; '$0 bots on' adds them whenever"
    return 0
  fi
  ui_outro "switching to the core that carries them"
  bots_switch bots
}

# A migration reaches whichever database its stream belongs to, so the applier is
# asked which those are rather than turtle_world being assumed. These dumps keep
# a folder of their own: backup mode prunes to the newest BACKUP_KEEP of each
# database it names, and a dump taken to make a schema change reversible is not
# one of that rotation's to delete.
# $1 what to name them after, a commit or the core being switched to
backup_before_migrations() {
  local db backup stamp dbs=(); stamp=$(date +%Y%m%d-%H%M%S)
  mapfile -t dbs < <("$SERVER/apply-db-updates.sh" --databases)
  (( ${#dbs[@]} )) \
    || die "could not read which databases the migrations reach; nothing was touched"
  mkdir -p "$SERVER/backups/pre-migration"
  for db in "${dbs[@]}"; do
    backup="$SERVER/backups/pre-migration/$db-$stamp-$1.sql.gz"
    say "backing up $db before migrations"
    mariadb-dump -h "$TWOW_DB_HOST" -P "$TWOW_DB_PORT" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" \
        --routines --triggers "$db" | gzip > "$backup"
    # The dump is piped, so its own status is what matters, not gzip's.
    (( PIPESTATUS[0] == 0 )) || { rm -f "$backup"; die "dumping $db failed; not touching the database"; }
    say "backup: ${backup#"$ROOT"/}"
  done
}

# Replacing binaries or schema under a running world is what update and a core
# switch both have to refuse; realmd holds no state and is only in the way, so
# it is stopped rather than complained about.
assert_servers_stopped() {
  if world_running; then
    service_active && die "the world server is running as a service; stop it first:
  systemctl --user stop twow      (start it again after: systemctl --user start twow)
  Swapping schema under a live server is how characters get eaten."
    die "the world server is running; stop it first.
  In its console: Ctrl+C. Detached: $0 stop, or pkill -TERM -f '$WORLD_PROC'
  SIGINT is the core's restart signal; with pkill -INT the world is only restarted.
  Swapping schema under a live server is how characters get eaten."
  fi
  if realm_running; then
    local rpid
    for rpid in $(server_pids realmd); do kill -INT "$rpid" 2>/dev/null || true; done
    sleep 1
    say "stopped realmd (a running binary cannot be replaced)"
  fi
}

# -----------------------------------------------------------------------------
# Update: pull the latest source, rebuild incrementally, back up every database
# a migration can reach, apply what is new. Refuses while the world server is
# running.
# -----------------------------------------------------------------------------
update_all() {
  local v src build; v=$(variant_active); src=$(variant_src); build=$(variant_build)
  [[ -d "$src/.git" ]] || die "no source checkout in ${src#"$ROOT"/}; run: $0 setup"
  [[ -x "$SERVER/bin/mangosd" ]] || die "not converted yet; run: $0 setup"
  assert_servers_stopped

  say "pulling latest $(variant_field "$v" branch) source for the $v core"
  local before after
  before=$(git -C "$src" rev-parse --short HEAD)
  # The kit's own fixes come out before the pull and go back after it, so a
  # fast-forward is refused for local edits and never for these.
  variant_unapply_patches
  if ! git -C "$src" pull --ff-only; then
    # The checkout goes back to what it was, fixes and all, since nothing else
    # in this run will put them back.
    apply_source_patches
    die "git pull failed (local changes in ${src#"$ROOT"/}? no network?); nothing was touched"
  fi
  after=$(git -C "$src" rev-parse --short HEAD)
  apply_source_patches
  if [[ "$before" == "$after" ]]; then
    say "source already at $after; still checking build and migrations"
  else
    say "source updated: $before -> $after"
  fi

  say "rebuilding mangosd and realmd (incremental, only what changed)"
  # ninja re-runs cmake itself when the source's build files changed, and that
  # re-run needs the same ACE in the environment as the first configure
  select_ace
  local flags=(); read -ra flags <<< "$(variant_field "$v" cmake)"
  mkdir -p "$build"
  [[ -f "$build/build.ninja" ]] \
    || cmake -B "$build" -S "$src" -GNinja \
         -DCMAKE_BUILD_TYPE=Release -DDEBUG_SYMBOLS=OFF "${flags[@]}" > "$build/configure.log" 2>&1 \
    || die "cmake configure failed, see ${build#"$ROOT"/}/configure.log"
  local jobs; jobs=$(build_jobs)
  [[ -n "$jobs" ]] && say "holding the compile to $jobs job(s) to stay inside this cgroup's limits"
  local oom_before; oom_before=$(oom_kills)
  if ! ninja -C "$build" ${jobs:+-j"$jobs"} mangosd realmd; then
    (( $(oom_kills) > oom_before )) && die_out_of_memory "$jobs" "$(mem_limit)"
    die "compile failed; the installed binaries were not touched.
  Fix the error above or report it on the tortoise-wow GitHub."
  fi
  install_binaries "$build/src/mangosd/mangosd" "$build/src/realmd/realmd"
  say "installed updated binaries into server/bin/"
  # A core that brings its own config gains settings upstream, and the copy in
  # server/bin keeps its values while taking the new ones.
  ensure_variant_conf

  start_native_db
  backup_before_migrations "$after"
  ensure_migrations

  say "update complete; start the server with: $0 run"
}

# -----------------------------------------------------------------------------
# backups of what cannot be rebuilt
# -----------------------------------------------------------------------------
# turtle_world is rebuilt from the repack and the migrations, and turtle_logs is
# a record of what happened. Characters and accounts are neither: nothing here
# can recreate them, so they are what gets backed up. update mode already dumps
# turtle_world before touching its schema, which is a different job from this.
BACKUP_KEEP=${TWOW_BACKUP_KEEP:-10}
BACKUP_DBS=(turtle_char turtle_logon)

backup_all() {
  local dir="$SERVER/backups" stamp f
  mkdir -p "$dir"
  stamp=$(date +%Y%m%d-%H%M%S)
  # A dump taken while the world is running can catch a character mid-save.
  # --single-transaction gives InnoDB a consistent view without locking players
  # out, so this is safe to run on a live server.
  for f in "${BACKUP_DBS[@]}"; do
    say "backing up $f"
    mariadb-dump -h "$TWOW_DB_HOST" -P "$TWOW_DB_PORT" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" \
        --single-transaction --routines --triggers "$f" 2>/dev/null | gzip > "$dir/$f-$stamp.sql.gz"
    # The dump is piped, so its own status is what matters, not gzip's.
    (( PIPESTATUS[0] == 0 )) || { rm -f "$dir/$f-$stamp.sql.gz"; die "dumping $f failed; nothing was written"; }
    say "  ${dir#"$ROOT"/}/$f-$stamp.sql.gz ($(du -h "$dir/$f-$stamp.sql.gz" | cut -f1))"
  done
  # Oldest first, keeping the newest BACKUP_KEEP of each database.
  local old
  for f in "${BACKUP_DBS[@]}"; do
    # ls orders by modification time, which the names on their own cannot.
    # shellcheck disable=SC2012
    mapfile -t old < <(ls -1t "$dir/$f-"*.sql.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)))
    ((${#old[@]})) && { rm -f "${old[@]}"; say "pruned ${#old[@]} old $f backup(s), keeping $BACKUP_KEEP"; }
  done
  return 0
}

# Restoring overwrites live characters, so it refuses while the world is up and
# says plainly what it is about to replace.
restore_backup() {  # $1 path to a .sql.gz written by backup_all, $2 the --yes flag
  local file=$1 db
  [[ -f "$file" ]] || die "no such backup: $file
  Available: ls ${SERVER#"$ROOT"/}/backups/"
  db=${file##*/}; db=${db%%-*}
  case "$db" in
    turtle_char|turtle_logon) ;;
    *) die "'$file' does not look like a backup of turtle_char or turtle_logon";;
  esac
  world_running && die "the world server is running; stop it first: $0 stop
  Restoring under a live server would be overwritten by the next character save."
  confirm_destructive "everything in $db is replaced by the contents of
  ${file##*/}." "${2:-}" || { say "nothing restored"; return 0; }
  gzip -dc "$file" | DB "$db" || die "restore failed; $db may be half-written.
  Try another backup, or reseed with: $0 setup"
  say "$db restored from ${file##*/}"
}

# -----------------------------------------------------------------------------
# What is running, and stopping it
# -----------------------------------------------------------------------------
status_all() {
  local pid
  if [[ -d "$SERVER/db/mysql" ]] && mariadb_running; then
    resolve_db_port
    say "database  running on $TWOW_DB_HOST:$TWOW_DB_PORT"
  else
    warn "database  not running"
  fi
  local rp; rp=$(realm_port)
  pid=$(our_listener "$rp")
  if [[ -n "$pid" ]]; then say "realmd    running on $rp (pid $pid)"
  elif ss -tln 2>/dev/null | grep -q "[:.]$rp "; then warn "realmd    not ours; $rp is held by something else"
  else warn "realmd    not running"; fi
  local wp; wp=$(world_port)
  pid=$(our_listener "$wp")
  if [[ -n "$pid" ]]; then say "world     running on $wp (pid $pid)"
  elif world_running; then say "world     starting; not accepting connections yet"
  else warn "world     not running"; fi
  local v; v=$(variant_active)
  if [[ "$v" == bots ]]; then say "core      bots ($(bot_characters 2>/dev/null || echo '?') bot character(s))"
  else say "core      stock"; fi
  if [[ -f "$SERVICE_UNIT" ]] && command -v systemctl >/dev/null 2>&1; then
    say "service   $(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true), $(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || true) at boot"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# doctor: whether the install is correct, which is a different question from the
# one status answers. A server can run perfectly and still hand out an address
# it does not listen on, or carry an administrator whose password is its own
# name.
#
# Read-only throughout, so it is safe against a live server, and each finding
# carries the command that settles it. What the conversion has learned about
# this repack lives here as a check rather than as prose somebody has to read.
#
# bad  something that stops the server working, or lets in who should not be
# note worth knowing, breaks nothing
# -----------------------------------------------------------------------------
DOC_BAD=0 DOC_NOTE=0

dr_head() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RST"; }
dr_ok()   { printf '  %sok%s    %s\n' "$C_GREEN" "$C_RST" "$1"; }
dr_note() { printf '  %snote%s  %s\n' "$C_YELLOW" "$C_RST" "$1"; DOC_NOTE=$(( DOC_NOTE + 1 )); }
dr_skip() { printf '  %sskip  %s%s\n' "$C_DIM" "$1" "$C_RST"; }
# $1 what is wrong, $2 what settles it
dr_bad()  {
  printf '  %sbad%s   %s\n        %sfix: %s%s\n' "$C_RED" "$C_RST" "$1" "$C_DIM" "$2" "$C_RST"
  DOC_BAD=$(( DOC_BAD + 1 ))
}

# A count from the database, or empty when it cannot be had. Every database
# check goes through this so one unreachable server reads as skipped rather
# than as zero findings.
dr_count() {  # $1 sql returning one number
  local n
  n=$(DB -N -B -e "$1" 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$n"
}

doctor_install() {
  local M="$SERVER/bin/mangosd.conf" R="$SERVER/bin/realmd.conf" d missing=()
  dr_head "install"
  if [[ -x "$SERVER/bin/mangosd" && -x "$SERVER/bin/realmd" ]]; then
    dr_ok "mangosd and realmd are built"
  else
    dr_bad "server/bin has no built mangosd and realmd" "$0 setup"
  fi
  if [[ -f "$M" && -f "$R" ]]; then
    dr_ok "mangosd.conf and realmd.conf are in place"
  else
    dr_bad "server/bin is missing mangosd.conf or realmd.conf" "$0 setup"
  fi
  for d in "${MAPDATA_DIRS[@]}"; do [[ -d "$SERVER/data/$d" ]] || missing+=("$d"); done
  if (( ${#missing[@]} )); then
    dr_bad "server/data is missing ${missing[*]}, which mangosd needs to start" "$0 setup"
  else
    dr_ok "map data present (${MAPDATA_DIRS[*]})"
  fi
}

# Whether the database this install owns can be asked anything. db.env is what
# makes it this install's: without it the connection lands on whatever answers
# on 3306, whose state says nothing about the folder being examined.
dr_db_ready() {
  [[ -f "$SERVER/db.env" ]] || return 1
  dr_count "SELECT 1" >/dev/null
}

doctor_database() {
  local db n pending src absent=0
  dr_head "database"
  if ! dr_db_ready; then
    dr_skip "no database answering for this install, so its checks are left out ($0 run)"
    return 0
  fi
  dr_ok "the database answers on $TWOW_DB_HOST:${TWOW_DB_PORT:-3306}"
  for db in turtle_logon turtle_char turtle_world turtle_logs; do
    n=$(dr_count "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$db'") || n=0
    (( n )) || { dr_bad "the $db database is missing" "$0 setup"; absent=1; }
  done
  (( absent )) || dr_ok "all four game databases are present"

  # The migrations live under the checkout of the core this install runs, which
  # is where the applier looks for them too.
  src=$(variant_src); src=${src#"$ROOT"/}
  if [[ -x "$SERVER/apply-db-updates.sh" && -d "$ROOT/$src/sql" ]]; then
    if pending=$("$SERVER/apply-db-updates.sh" --check 2>/dev/null) && [[ "$pending" =~ ^[0-9]+$ ]]; then
      if (( pending )); then
        dr_note "$pending migration(s) from $src are not applied yet ($0 update)"
      else
        dr_ok "the databases are up to date with the migrations in $src"
      fi
    else
      dr_skip "the migration state could not be read"
    fi
  else
    dr_skip "no source checkout, so migrations are left out"
  fi
}

doctor_dump() {
  local n
  dr_head "what the repack's dump carries"
  if ! dr_db_ready; then
    dr_skip "no database answering for this install, so its checks are left out"
    return 0
  fi
  n=$(count_stock_accounts) || n=0
  if (( n )); then
    dr_bad "$n of the repack's own accounts are still here at their shipped password" "$0 setup"
  else
    dr_ok "the repack's ADMIN and TEST are gone"
  fi
  n=$(dr_count "SELECT COUNT(*) FROM turtle_logon.account WHERE \`rank\` >= 3 AND $SELF_PASS") || n=0
  if (( n )); then
    dr_note "$n game master account(s) have their own name as the password"
  else
    dr_ok "no game master account carries its own name as a password"
  fi
  n=$(count_orphan_characters) || n=0
  if (( n )); then
    dr_bad "$n character(s) belong to accounts that are not here" "$0 setup"
  else
    dr_ok "every character belongs to an account that exists"
  fi
  n=$(count_orphan_pets) || n=0
  if (( n )); then
    dr_bad "$n pet(s) have no owner, which the next character made inherits" "$0 setup"
  else
    dr_ok "every pet has an owner"
  fi
}

doctor_reach() {
  local R="$SERVER/bin/realmd.conf" M="$SERVER/bin/mangosd.conf" addr rbind mbind
  local f="$ROOT/client/realmlist.wtf" want cur be rc p closed=()
  dr_head "reach"
  [[ -f "$R" && -f "$M" ]] || { dr_skip "no configs yet, so reach is left out"; return 0; }

  # A world part way through its load answers nothing, which a client meets as a
  # hang on "Logging into game server". Asked first, since agreeing addresses
  # still leave that wait in front of them.
  if world_ready; then
    dr_ok "the world is accepting logins on $(world_port)"
  elif world_running; then
    dr_note "the world is still loading; logins are taken once it opens $(world_port)"
  else
    dr_skip "the world server is down, so logins are left out ($0 status)"
  fi
  # A session cannot move between tmux servers, so only a restart brings a
  # pre-socket console over to the kit's own.
  if world_running && ! console_running && legacy_console_running; then
    dr_note "the world console is on tmux's default socket, from an earlier kit; a
        restart moves it ($0 stop, then $0 run --detached)"
  fi

  rbind=$(conf_get "$R" BindIP); mbind=$(conf_get "$M" BindIP)
  if [[ "$rbind" != "$mbind" ]]; then
    dr_bad "realmd binds $rbind and mangosd binds $mbind" "$0 realm <address>"
  fi
  if ! addr=$(realm_address) || [[ -z "$addr" ]]; then
    dr_skip "the realm row could not be read, so the address is left out"
  elif [[ "$rbind" == 0.0.0.0 || "$rbind" == "$addr" ]]; then
    dr_ok "the realm advertises $addr and listens on $rbind"
  else
    dr_bad "the realm advertises $addr while listening only on $rbind, so nothing reaches it" \
           "$0 realm $addr"
  fi

  if [[ -d "$ROOT/client" ]] && [[ -n "${addr:-}" ]]; then
    want="set realmlist $addr"
    cur=$(head -1 "$f" 2>/dev/null | tr -d '\r')
    if [[ "$cur" == "$want" ]]; then
      dr_ok "client/realmlist.wtf points at $addr"
    else
      dr_bad "client/realmlist.wtf reads '${cur:-nothing}'" "$0 realm $addr"
    fi
  fi

  # Only a realm somebody else is meant to reach can be blocked in a way that
  # matters here.
  if [[ -n "${addr:-}" && "$addr" != 127.0.0.1 ]]; then
    be=$(fw_backend)
    if [[ -z "$be" ]]; then
      dr_ok "no firewall is running here"
    else
      for p in "$(realm_port)" "$(world_port)"; do
        rc=0; fw_port_state "$be" "$p" || rc=$?
        (( rc == 2 )) && { dr_skip "$be is running and reading it needs a password"; break; }
        (( rc == 1 )) && closed+=("$p")
      done
      if (( ${#closed[@]} )); then
        dr_bad "$be has tcp ${closed[*]} closed, which clients need" "$(fw_open_command "$be" "${closed[@]}")"
      elif (( rc != 2 )); then
        dr_ok "$be has the realm and world ports open"
      fi
    fi
  fi
}

doctor_config() {
  local M="$SERVER/bin/mangosd.conf"
  dr_head "configuration"
  [[ -f "$M" ]] || { dr_skip "no mangosd.conf yet"; return 0; }
  # The core defaults this on when the line is absent, which puts a listener on
  # 127.0.0.1:50000 that only the config turns off.
  if ! conf_has "$M" HttpApi.Enable; then
    dr_note "mangosd.conf names no HttpApi.Enable, and the core defaults it on"
  elif [[ "$(conf_get "$M" HttpApi.Enable)" == 0 ]]; then
    dr_ok "the HTTP API is off"
  else
    dr_note "the HTTP API is on, listening on $(conf_get "$M" HttpApi.BindIP):$(conf_get "$M" HttpApi.BindPort)"
  fi

  # Both of a client's realm list requests arrive in the same second on a local
  # network, so any delay above zero hangs the login.
  local R="$SERVER/bin/realmd.conf" d
  if [[ -f "$R" ]]; then
    d=$(conf_get "$R" MinRealmListDelay 2>/dev/null) || d=""
    if [[ "$d" == 0 ]]; then
      dr_ok "the realm list answers a client that asks twice"
    else
      dr_bad "realmd drops a second realm list request inside ${d:-1}s, which a client
  on this network makes; logins hang on 'Retrieving realm list'" \
        "set MinRealmListDelay = 0 in ${R#"$ROOT"/}, or re-run: $0 setup"
    fi
  fi
}

# Whether boot brings the server back, which neither status nor reach can see.
# Speaks only once a unit is installed, since starting by hand is the default.
doctor_service() {
  [[ -f "$SERVICE_UNIT" ]] || return 0
  dr_head "service"
  # Without a manager the checks below read nothing and every one of them would
  # report a fault the unit does not have, so this is the whole section.
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    dr_bad "this login runs no user manager, so nothing here can start the unit.
  $(user_manager_hint)" \
      "log in over ssh as $(id -un), and run: $0 doctor"
    return 0
  fi
  local cmd
  cmd=$(sed -n 's/^ExecStart=//p' "$SERVICE_UNIT" | head -1)
  if [[ "$cmd" == "\"$ROOT/twow.sh\" service watch" ]]; then
    dr_ok "the unit starts this install"
  else
    dr_bad "the unit starts $cmd, which is not this install" "$0 service install"
  fi
  if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    dr_ok "enabled, so boot starts it"
  else
    dr_bad "the unit is written but not enabled, so boot passes it by" \
      "systemctl --user enable $SERVICE_NAME"
  fi
  if [[ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" == yes ]]; then
    dr_ok "lingering is on, so the unit starts at boot rather than at login"
  else
    dr_bad "lingering is off, so the unit starts only at a login" "loginctl enable-linger"
  fi
}

# The one check that cannot be taken on trust: variant.env says which core this
# install runs, the binary says what it is, and a switch that stopped halfway is
# exactly where they disagree.
doctor_core() {
  local v built want have n f
  v=$(variant_active)
  dr_head "core"
  built=$(variant_binary_label) || built=""
  if [[ -z "$built" ]]; then
    dr_skip "no world server built yet, so the core is left out"
    return 0
  fi
  if [[ "$built" == "$v" ]]; then
    dr_ok "runs the $v core, and server/bin holds a $built build"
  else
    dr_bad "variant.env says $v, server/bin holds a $built build" \
      "$0 bots $([[ "$v" == bots ]] && echo on || echo off)"
  fi

  if [[ "$v" == bots ]]; then
    if [[ -f "$BOT_CONF" ]]; then
      dr_ok "aiplayerbot.conf sits beside mangosd.conf, where the core reads it"
      [[ "$(conf_get "$BOT_CONF" AiPlayerbot.Enabled)" == 1 ]] \
        || dr_bad "the bot subsystem is built but switched off in aiplayerbot.conf" \
             "set AiPlayerbot.Enabled = 1"
      [[ "$(conf_get "$BOT_CONF" AiPlayerbot.DeleteRandomBotAccounts)" == 1 ]] \
        && dr_bad "DeleteRandomBotAccounts is on, which wipes and rebuilds the cohort every boot" \
             "set AiPlayerbot.DeleteRandomBotAccounts = 0"
      # The accounts the core is told to create decide how many characters the
      # first boot writes, nine to an account, and the cohort is drawn from
      # those. A config whose accounts no longer follow the cohort is what
      # leaves thousands of characters in a realm that asked for twenty bots.
      want=$(bot_count); have=$(conf_get "$BOT_CONF" AiPlayerbot.RandomBotAccountCount)
      if [[ "$want" =~ ^[0-9]+$ && "$have" =~ ^[0-9]+$ ]]; then
        if (( have == $(bot_accounts_for "$want") )); then
          dr_ok "$have bot account(s) are asked for, which carries a cohort of $want"
        else
          dr_bad "the config creates $have bot account(s) for a cohort of $want, which is \
$(( have * BOT_CHARS_PER_ACCOUNT )) bot character(s)" "$0 bots --count $want"
        fi
      fi
    else
      dr_bad "no aiplayerbot.conf beside mangosd.conf, so the bots stay asleep" "$0 bots on"
    fi
    # The auction house is the same module and reads its own file from the same
    # place. It trades as the cohort's characters, so it is on with them.
    if [[ -f "$AHBOT_CONF" ]]; then
      if [[ "$(conf_get "$AHBOT_CONF" AhBot.Enabled)" == 1 ]]; then
        dr_ok "the bots run the auction house, buying and selling as their own characters"
      else
        dr_note "the auction house is switched off in ahbot.conf ($0 bots --count <n> turns it on with the cohort)"
      fi
    else
      dr_note "no ahbot.conf beside mangosd.conf, so the auction house stays quiet ($0 bots on)"
    fi
    for f in "$BOT_CONF" "$AHBOT_CONF"; do
      [[ -f "$f" ]] || continue
      n=$(bot_conf_missing "$f" | wc -l)
      (( n )) && dr_note "$n setting(s) have been added to ${f##*/} since it was copied ($0 update)"
    done
    if dr_db_ready; then
      n=$(bot_cohort) || n=0
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n )); then
        dr_ok "$n bot account(s) in the realm, holding $(bot_characters) character(s)"
      else
        dr_note "no bots in the realm yet; the next boot creates them"
      fi
    fi
  elif dr_db_ready; then
    n=$(bot_cohort) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] && (( n )) \
      && dr_note "$n bot account(s) from the other core are still here ($0 bots --purge clears them)"
  fi
  return 0
}

doctor_all() {
  DOC_BAD=0 DOC_NOTE=0
  doctor_install
  doctor_core
  doctor_database
  doctor_dump
  doctor_reach
  doctor_config
  doctor_service
  printf '\n'
  if (( DOC_BAD )); then
    printf '%s%d problem(s)%s, %d note(s)\n' "$C_RED" "$DOC_BAD" "$C_RST" "$DOC_NOTE"
    return 1
  fi
  printf '%sno problems%s, %d note(s)\n' "$C_GREEN" "$C_RST" "$DOC_NOTE"
  return 0
}

# Stopped in the order they depend on each other: the world writes characters
# back through the database, so the database outlives it, and realmd sits
# between them. Each step is skipped when that piece is already down, so this
# is safe to run twice.
stop_all() {
  local pid i
  if world_running; then
    say "stopping the world server"
    # SIGTERM is the core's clean shutdown (SIGINT is its restart signal, which
    # the run wrapper would answer by starting the world again). Signalled by
    # pid, so the signal reaches this install's world server and nothing else.
    for pid in $(server_pids mangosd); do kill -TERM "$pid" 2>/dev/null || true; done
    for i in $(seq 1 60); do world_running || break; sleep 1; done
    world_running && warn "the world server is still running; it may be saving characters"
  else
    say "world server already stopped"
  fi
  local rp; rp=$(realm_port)
  pid=$(our_listener "$rp")
  if [[ -n "$pid" ]]; then
    say "stopping realmd (pid $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 15); do [[ -n "$(our_listener "$rp")" ]] || break; sleep 1; done
  else
    say "realmd already stopped"
  fi
  if [[ -d "$SERVER/db/mysql" ]] && mariadb_running; then
    say "stopping the database"
    mariadb-admin --socket="$SERVER/db/mysql.sock" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" shutdown \
      >/dev/null 2>&1 || warn "the database did not accept the shutdown; it is still running"
  else
    say "database already stopped"
  fi
  say "everything this script starts is stopped"
}

# -----------------------------------------------------------------------------
# Run: DB (background) -> realmd (background) -> mangosd (foreground console)
# -----------------------------------------------------------------------------
# Each piece is started by the same numbered script the manual path uses, so
# there is one way to start a database and one way to start a login server. Only
# the ordering, the waiting and the handover are this function's own.
# mangosd reads its console from stdin and stops when that closes, so the world
# server needs a terminal for as long as it runs. tmux supplies one that outlives
# the shell which started it; a service would have to turn the console off
# instead.
# A step that cannot be undone is agreed to first. With no terminal there is
# nobody to ask, so --yes stands in for the answer.
# $1 what is about to happen, $2 the flag as it was given
confirm_destructive() {
  [[ "${2:-}" == --yes ]] && return 0
  [[ -t 0 ]] || die "$1
  There is no terminal here to ask on; pass --yes to mean it."
  ui_intro "this cannot be undone"
  ui_note "$1"
  ui_select "Go ahead?" 1 "Yes, do it" "No, leave everything alone"
  (( ANSWER == 0 )) || { ui_outro "nothing changed"; return 1; }
  return 0
}

# Empties the realm and leaves the build standing: every account goes, and with
# it every character and pet, the same way the repack's own pair is cleared.
reset_world() {  # $1 the --yes flag as given
  local n bots=0 mine
  n=$(DB -N -B -e "SELECT COUNT(*) FROM turtle_logon.account" 2>/dev/null) \
    || die "the database is not answering; start it with: $0 run"
  # Bots are counted apart from the people: a realm of twenty players and a
  # thousand bots would otherwise ask about a thousand and twenty accounts.
  bots=$(bot_cohort) || bots=0
  [[ "$bots" =~ ^[0-9]+$ ]] || bots=0
  mine=$(( n - bots ))
  confirm_destructive "every account on this realm ($mine, plus $bots the bots hold)
  goes, and every character and pet with them. The build, the world database and
  the client stay." "${1:-}" || return 0
  sweep_accounts "1 = 1" || die "the database refused the sweep; nothing is guaranteed removed"
  say "the realm is empty; the next account is id 1"
  say "make one with: $0 account"
  [[ "$(variant_active)" == bots ]] \
    && say "the bots are created again on the next boot, which takes a few minutes"
  return 0
}

# Back to a bare checkout: what setup generated goes, what was downloaded by
# hand stays. The client is many gigabytes and is never this script's to remove.
reset_all() {  # $1 the --yes flag as given
  local d
  confirm_destructive "src/, build/, deps/ and the converted server/ go, which is
  every part setup generated. client/ and the archives beside it stay, and
  setup builds the rest again from them." "${1:-}" || return 0
  # Stopped through systemd first, or the service starts the server back up
  # while its files are being removed.
  if service_active; then
    say "the service holds the server up; stopping it there first"
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  stop_all
  for d in src build deps; do
    [[ -d "$ROOT/$d" ]] || continue
    rm -rf "${ROOT:?}/$d" && say "removed $d/"
  done
  # server/ holds the kit's own scripts and its guide; the rest arrived with the
  # repack or was made from it.
  if [[ -d "$SERVER" ]]; then
    find "${SERVER:?}" -mindepth 1 -maxdepth 1 \
      ! -name '*.sh' ! -name 'README.linux.md' -exec rm -rf {} + 2>/dev/null || true
    say "emptied server/, keeping its scripts"
  fi
  say "ready for a fresh conversion: $0 setup"
}

# What 'logs' will show. Named here so the mode, its help and its error message
# all list the same set.
LOG_KINDS="world realmd errors db stderr"

# LogTimestamp puts the start time in the name, so mangosd's "server.log" is on
# disk as server_2026-08-09_21-41-17.log. The newest match is the running one.
newest_log() {  # $1 directory, $2 name from the config
  local base=${2%.*} ext=${2##*.} p
  [[ -f "$1/$2" ]] && { printf '%s\n' "$1/$2"; return 0; }
  # ls orders by modification time, which the stamped names alone cannot.
  # shellcheck disable=SC2012
  p=$(ls -1t "$1/${base}_"*".$ext" 2>/dev/null | head -1)
  [[ -n "$p" ]] && printf '%s\n' "$p"
}

# Where each log is, read from the configs so a renamed one still resolves. The
# servers run from bin/, which is what LogsDir is relative to; db is the kit's
# own capture of a background start.
log_path() {  # $1 kind
  local c key f d
  case "$1" in
    world)  c="$SERVER/bin/mangosd.conf"; key=LogFile ;;
    errors) c="$SERVER/bin/mangosd.conf"; key=DBErrorLogFile ;;
    realmd) c="$SERVER/bin/realmd.conf";  key=LogFile ;;
    db)     printf '%s\n' "$SERVER/logs/mysql.out"; return 0 ;;
    # Both are the kit's own capture rather than a file the core names, so the
    # path is fixed here instead of read from a config.
    stderr) printf '%s\n' "$SERVER/logs/stderr.log"; return 0 ;;
    *)      return 1 ;;
  esac
  [[ -f "$c" ]] || return 1
  f=$(conf_get "$c" "$key") && [[ -n "$f" ]] || return 1
  d=$(conf_get "$c" LogsDir) || d=""
  d=$(cd "$SERVER/bin/${d:-../logs}" 2>/dev/null && pwd) || return 1
  newest_log "$d" "$f"
}

show_logs() {  # $1 kind, $2 --follow
  local kind=${1:-world} p
  # An unknown name and a log not written yet are different answers, so the
  # name is checked against the list before the file is looked for.
  case " $LOG_KINDS " in
    *" $kind "*) ;;
    *) die "unknown log '$kind'; one of: $LOG_KINDS" ;;
  esac
  p=$(log_path "$kind") || p=""
  [[ -n "$p" && -f "$p" ]] \
    || die "no $kind log written yet; it appears once that server has run"
  if [[ "${2:-}" == -f || "${2:-}" == --follow ]]; then
    say "following ${p#"$ROOT"/}; Ctrl+C stops watching, the server keeps running"
    exec tail -f "$p"
  fi
  say "last 40 lines of ${p#"$ROOT"/}"
  tail -n 40 "$p"
}

# Back to a world console that is already running. Printed before attaching,
# since attaching replaces this process.
console_attach() {
  command -v tmux >/dev/null 2>&1 \
    || die "tmux is not installed, and the detached console is a tmux session.
  Install it, or start the world in this terminal with: $0 run"
  # A console from an earlier kit sits on tmux's default socket, where it still
  # works; attaching goes to it there. It is only taken for the console while
  # the world runs, since an exact-named session alone may be anyone's.
  local socket=(-L "$CONSOLE_SOCKET")
  if ! console_running; then
    if legacy_console_running && world_running; then
      socket=()
      say "this console predates the kit's own tmux socket; move it there when
  convenient with: $0 stop, then $0 run --detached"
    else
      world_running && die "the world server is running without a console session,
  so it was started in a terminal of its own; that terminal is its console."
      die "no world server is running. Start one with: $0 run --detached"
    fi
  fi
  # Ctrl+C is the reflex for leaving a terminal and is the one thing that
  # stops the server, so both ways out are spelled out before attaching.
  say "attaching to the world console; the mangos> prompt is the server's own"
  say "leave it running:  your tmux prefix (Ctrl+B by default), then d"
  if service_active; then
    say "stop the server:   systemctl --user stop twow; the service brings back
                   what ends any other way, Ctrl+C included"
  else
    say "stop the server:   Ctrl+C, or 'server shutdown 1' at the prompt"
  fi
  exec tmux ${socket[@]+"${socket[@]}"} attach -t "=$CONSOLE_SESSION"
}

# How long a detached start watches before it leaves the world to load on its
# own. Loading is seconds on warm hardware and longer on a cold first boot, so
# the cap is generous and reaching it reads as slow rather than as broken.
WORLD_WAIT=120

# How long a start is given before it is left to the console. A first boot on
# the bots core writes the cohort's characters before the world opens its port,
# which is minutes rather than seconds.
world_wait() {
  local n
  [[ "$(variant_active)" == bots ]] || { printf '%s' "$WORLD_WAIT"; return 0; }
  n=$(bot_cohort) || n=""
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) \
    && { printf '%s' "$WORLD_WAIT"; return 0; }
  printf '%s' "$(( WORLD_WAIT * 5 ))"
}

# Which of three things became of a world just handed to tmux: the realm opened
# its port, the console session ended while loading, or loading was still going
# at the cap. The session is what is watched, since 3-world-server.sh brings
# mangosd back after a crash and the process alone flaps in between.
wait_for_world() {
  local waited=0 p limit
  limit=$(world_wait)
  (( limit > WORLD_WAIT )) \
    && say "the bots' characters are written on this first boot, so the world takes longer to open"
  until world_ready; do
    if ! console_running; then
      warn "the world server stopped after ${waited}s, while it was still loading"
      p=$(log_path world) || p=""
      [[ -n "$p" && -f "$p" ]] && {
        say "last 15 lines of ${p#"$ROOT"/}:"
        tail -n 15 "$p" | sed 's/^/  /'
      }
      # A start that fails before the core opens its log file leaves its reason
      # on stderr alone, which is the one place that holds it.
      say "a start that got no further than its first message: $0 logs stderr"
      return 1
    fi
    (( waited < limit )) || {
      say "still loading after ${limit}s; watch it with: $0 console"
      return 0
    }
    sleep 1
    waited=$(( waited + 1 ))
  done
  say "the realm is accepting logins on $(world_port), after ${waited}s"
  return 0
}

run_all() {
  # A server systemd owns is started and stopped there, or the unit and the
  # ports disagree about who runs it. Handing an idle unit to systemctl keeps
  # stop-then-run one owner; the service's own watcher passes by.
  if [[ -z "${TWOW_SERVICE:-}" ]] && service_installed; then
    service_active && die "the server runs as a service, and systemd is holding it up.
  Attach with: $0 console      stop with: $0 stop"
    local a; for a in "$@"; do case "$a" in
      -d|--detached) ;;
      *) warn "the service starts the world its own way; '$a' does not apply" ;;
    esac; done
    say "the server runs as a service; starting it there"
    systemctl --user start "$SERVICE_NAME" \
      || die "the service did not start. What systemd says:
  systemctl --user status twow      journalctl --user -u twow"
    # The watcher brings the stack up in order, and the console session is the
    # first sign of it; wait_for_world reads the rest.
    local i; for i in $(seq 1 30); do
      console_running && break
      service_active || break
      sleep 1
    done
    console_running || die "the world console has not appeared. What systemd says:
  journalctl --user -u twow"
    wait_for_world || die "the service tries again in 30s. What it last said: $0 logs world"
    return 0
  fi
  [[ -x "$SERVER/bin/mangosd" ]] || die "no native binaries yet; run: $0 setup"
  # 3-world-server.sh takes at most a log level, which is whatever is left once
  # the flag is taken out.
  local s a detached=0 level=""
  for a in "$@"; do
    case "$a" in
      -d|--detached) detached=1 ;;
      *)             level="$a" ;;
    esac
  done
  for s in 1-start-mysql 2-realm-server 3-world-server; do
    [[ -x "$SERVER/$s.sh" ]] || die "$SERVER/$s.sh is missing or not executable;
  restore it from the repo (chmod +x)."
  done

  start_native_db
  say "MariaDB ready on $TWOW_DB_HOST:$TWOW_DB_PORT"

  local port; port=$(realm_port)
  assert_port_ours "$port" realmd
  if [[ -z "$(our_listener "$port")" ]]; then
    ( cd "$SERVER" && nohup ./2-realm-server.sh > "$SERVER/logs/realmd.out" 2>&1 & )
    local i; for i in $(seq 1 15); do [[ -n "$(our_listener "$port")" ]] && break; sleep 1; done
    [[ -n "$(our_listener "$port")" ]] || die "realmd did not come up. Last lines of ${SERVER#"$ROOT"/}/logs/realmd.out:

$(tail -n 15 "$SERVER/logs/realmd.out" 2>/dev/null | sed 's/^/  /')"
  fi
  say "realmd ready on $port (pid $(our_listener "$port"))"

  if (( detached )); then
    command -v tmux >/dev/null 2>&1 \
      || die "--detached keeps the world console in a tmux session, and tmux is not installed.
  Install it, or start the world in this terminal with: $0 run"
    console_running && die "a world console is already running: $0 console"
    # A world still held by a pre-socket console cannot be joined by a second
    # one; a stop closes that session with the server it holds.
    legacy_console_running && world_running \
      && die "a world console from an earlier kit is still running on tmux's default
  socket. Move it to the kit's own: $0 stop, then $0 run --detached"
    tmux -L "$CONSOLE_SOCKET" new-session -d -s "$CONSOLE_SESSION" -c "$SERVER" "./3-world-server.sh $level"
    # tmux reports success the moment the session exists, so a world that
    # refuses to start looks the same as one that came up, and one still loading
    # looks like one taking clients. Both are settled by watching.
    say "world console running in the background as tmux session '$CONSOLE_SESSION'"
    wait_for_world || die "start it in this terminal to see what it says: $0 run${level:+ $level}"
    return 0
  fi

  say "starting mangosd in the foreground; this terminal is the server console"
  say "first boot loads all maps and takes a few minutes; stop with Ctrl+C"
  # Called rather than exec'd, and the note printed after it rather than from an
  # EXIT trap: exec replaces this shell outright, so a trap set here would never
  # run and nothing would say what was left behind.
  local rc=0
  "$SERVER/3-world-server.sh" ${level:+"$level"} || rc=$?
  warn "world server stopped; realmd and MariaDB are still running.
  Stop them with: $0 stop     (or $0 status to see what is up)"
  return $rc
}

# -----------------------------------------------------------------------------
# service: the server at boot, as a systemd user unit
# -----------------------------------------------------------------------------
# A user unit rather than a system one, so everything keeps running as whoever
# converted the install and root owns none of it. Lingering keeps that user's
# manager alive outside logins, which is what makes "at boot" true.
SERVICE_NAME=twow.service
SERVICE_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE_NAME"

# Which logins carry no user manager, named once for the install refusal and
# the doctor finding alike. A manager comes with a login session, which su and
# sudo shells, 'pct enter' and a container's web console never open.
user_manager_hint() {
  printf '%s' "su and sudo shells, 'pct enter' and a container's web console open
  no login session, and a minimal container wants dbus and libpam-systemd before
  it can. On WSL, systemd turns on in /etc/wsl.conf; containers from docker/
  manage the server their own way (docker/README.md)."
}

# Whether a unit is installed for this login, and whether it is holding the
# server up now. Both quiet wherever systemd is absent, which is what a
# container answers.
service_installed() {
  command -v systemctl >/dev/null 2>&1 && [[ -f "$SERVICE_UNIT" ]]
}
service_active() {
  service_installed || return 1
  systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

# The unit, written whole on every install so a moved checkout heals itself.
# KillMode=mixed hands TERM to the watcher alone, whose trap stops world,
# realmd and database in that order; the final SIGKILL meets an empty group.
service_unit_text() {
  cat <<EOF
# Written by 'twow.sh service install', and rewritten whole by the next one.
[Unit]
Description=TurtleWoW server (twow-linux)
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=exec
ExecStart="$ROOT/twow.sh" service watch
Restart=on-failure
RestartSec=30
TimeoutStopSec=180
KillMode=mixed

[Install]
WantedBy=default.target
EOF
}

# What ExecStart runs: the same shape as docker/entrypoint.sh. The stack comes
# up detached, then this holds on the console session, which outlives a crashed
# world where the process alone flaps.
service_watch() {
  local stopped=0
  TWOW_SERVICE=1
  run_all --detached
  trap 'stopped=1; stop_all || true' TERM INT
  while console_running; do sleep 5 & wait $! || true; done
  (( stopped )) && exit 0
  die "the world console ended on its own; systemd tries again in 30s. What it
  last said: $0 logs world"
}

service_install() {
  command -v systemctl >/dev/null 2>&1 || die "no systemctl here; starting at boot needs systemd"
  systemctl --user show-environment >/dev/null 2>&1 \
    || die "systemd runs no user manager for this login, so a user unit has
  nowhere to go. $(user_manager_hint)
  A plain ssh login as $(id -un) brings one, and this runs from there."
  [[ -x "$SERVER/bin/mangosd" ]] || die "nothing to start at boot yet; run: $0 setup"
  command -v tmux >/dev/null 2>&1 \
    || die "the service keeps the world console in tmux, which is missing; install it first"
  mkdir -p "${SERVICE_UNIT%/*}"
  service_unit_text > "$SERVICE_UNIT"
  systemctl --user daemon-reload
  say "wrote ~/.config/systemd/user/$SERVICE_NAME"
  # Without lingering a user manager lives only inside logins, and the unit
  # would start at login rather than at boot.
  if [[ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" != yes ]]; then
    if loginctl enable-linger 2>/dev/null; then
      say "lingering enabled: this user's services start at boot and outlive logouts"
    else
      warn "lingering was refused, so the service starts at login rather than at boot.
  Grant it with: sudo loginctl enable-linger $(id -un)"
    fi
  fi
  # A server started by hand holds the ports the unit needs. It moves under the
  # service the way a pre-socket console moves: stopped, then started fresh.
  if world_running || realm_running || { [[ -d "$SERVER/db/mysql" ]] && mariadb_running; }; then
    say "moving the running server under the service"
    stop_all
  fi
  systemctl --user enable --now "$SERVICE_NAME" >/dev/null 2>&1 \
    || die "the unit was written but did not start. What systemd says:
  systemctl --user status twow      journalctl --user -u twow"
  say "the server now starts at boot, and is coming up"
  say "watch it:  systemctl --user status twow      $0 console"
  say "stop it:   $0 stop      start it:  $0 run      (both go through systemctl while installed)"
}

service_remove() {
  [[ -f "$SERVICE_UNIT" ]] || { say "no service is installed"; return 0; }
  # disable --now stops through the watcher's trap, so the shutdown is ordered.
  systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_UNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  say "service removed: the server is stopped, and starts by hand again ($0 run)"
  say "lingering stays as it was; retire it with: loginctl disable-linger"
}

service_status() {
  if [[ ! -f "$SERVICE_UNIT" ]]; then
    say "no service is installed; '$0 service install' starts the server at boot"
    return 0
  fi
  local ac en lg
  ac=$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null) || true
  en=$(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null) || true
  lg=$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null) || true
  say "unit      ~/.config/systemd/user/$SERVICE_NAME"
  say "state     ${ac:-unknown}, ${en:-unknown} at boot"
  if [[ "$lg" == yes ]]; then
    say "linger    on: starts at boot and outlives logouts"
  else
    warn "linger    off: starts only at a login ($0 service install grants it)"
  fi
}

# -----------------------------------------------------------------------------
# The notice the GPL asks an interactive program to carry, with the 'show w'
# and 'show c' it names answered in one place. Section 5d requires none of it,
# so it is a mode rather than a banner over every run.
show_license() {
  cat <<EOF

${C_BOLD}twow-linux${C_RST} - the SIGGZ TurtleWoW 1.18.1 repack, native on Linux
Copyright (C) 2026  Xapne

This program comes with ${C_BOLD}ABSOLUTELY NO WARRANTY${C_RST}, to the extent permitted by
applicable law; sections 15 and 16 of the license carry the whole of it.

This is free software, and you are welcome to redistribute it under the terms
of the GNU General Public License, version 3 or later. The full text sits in
LICENSE beside this script, and at <https://www.gnu.org/licenses/gpl-3.0.html>.

The server core is tortoise-wow, built here from
  $(variant_field "$(variant_active)" repo) ($(variant_field "$(variant_active)" branch))
and keeps its own GPL-2.0-or-later terms. The core that carries AI players
vendors cmangos/playerbots, under the same terms. The repack, the map data and
the game client come from elsewhere and are supplied by whoever runs this.

Contact: https://github.com/Xapne/twow-linux/issues or xapne@protonmail.ch

EOF
}

usage() {
  cat <<EOF

${C_BOLD}${C_CYAN}apne's all-in-one CLI${C_RST}${C_BOLD} for TurtleWoW 1.18.1 on Linux${C_RST}
Converts the SIGGZ Windows repack to a fully native Linux server and runs it.

${C_BOLD}Usage:${C_RST}  $0 [mode]

${C_BOLD}Modes:${C_RST}
  ${C_GREEN}(none)${C_RST}         convert whatever is missing, then start the server
  ${C_GREEN}setup${C_RST}          convert only: dependencies, repack, map data, source
                 checkout, ACE + server build, configs, database seed,
                 schema migrations; every step is skipped once done
  ${C_GREEN}run${C_RST} [level] [--detached]
                 start only: MariaDB and realmd in the background,
                 mangosd in the foreground as the server console
                 (Ctrl+C stops it); optional [level] is the mangosd
                 console log level, 0 (quiet) to 3 (debug).
                 ${C_DIM}--detached keeps the console in a tmux session instead, so
                 the server outlives the shell; '$0 console' returns to it.${C_RST}
  ${C_GREEN}console${C_RST}        attach to a detached world console.
                 ${C_DIM}Leave it running with the tmux prefix (Ctrl+B by default)
                 then d. Ctrl+C at that prompt stops the server.${C_RST}
  ${C_GREEN}logs${C_RST} [what] [-f]
                 last 40 lines of a log, or -f to follow it;
                 [what] is one of: world (default), realmd, errors, db,
                 stderr.
                 ${C_DIM}The console shows the world's own output and its prompt;
                 the errors the core also writes to stderr are kept in
                 'logs stderr', and in the world log beside them.${C_RST}
  ${C_GREEN}firstrun${C_RST}       the questions a finished install still has: a name for the
                 realm, who can reach it, whether the repack's timed broadcast
                 keeps running, and a game master account, each asked only
                 until it has been answered.
                 ${C_DIM}Part of setup already; twow-vm.sh calls it on its own
                 because its conversion runs without a terminal.${C_RST}
  ${C_GREEN}account${C_RST} [--list [--all] | --password <name> | --if-none]
                 create a game master account and log in as yourself
                 instead of the repack's shared ADMIN. Offered once at the
                 end of setup; this runs it again whenever you want.
                 --list shows who is here and at what level, leaving the
                 bots out until --all asks for them; --password
                 changes one, which the world console allows only from its
                 own prompt.
                 ${C_DIM}--if-none offers only while no account of your own
                 exists, which is what twow-vm.sh calls.${C_RST}
  ${C_GREEN}interactive${C_RST}    guided setup screen for the most common options:
                 realm name, LAN play, game type, XP/drop/honor rates,
                 MOTD, player limit, starting level.
                 ${C_DIM}Configuration only: builds and starts nothing, though
                 it does unpack the repack when that has not happened
                 yet, since the settings live in it. Restart the server
                 afterwards to apply.${C_RST}
  ${C_GREEN}deps${C_RST} [--packages]
                 what this system needs, what is already there, and the
                 one command that installs the rest; --packages prints
                 the bare list (twow-vm.sh provisions its guest with it)
  ${C_GREEN}backup${C_RST} [--restore <file> [--yes]]
                 dump characters and accounts into server/backups, keeping
                 the newest ${C_DIM}TWOW_BACKUP_KEEP${C_RST} of each (default 10). Safe to run
                 while the server is up. --restore puts one back, which asks
                 first and refuses while the world is running; --yes answers
                 for a run with no terminal.
                 ${C_DIM}turtle_world is not backed up here: setup and update
                 rebuild it. Characters and accounts cannot be rebuilt.${C_RST}
  ${C_GREEN}status${C_RST}         what is running: database, realmd, world, and their ports
  ${C_GREEN}doctor${C_RST}         whether the install is correct, which is the other question:
                 binaries and map data, the game databases and their pending
                 migrations, what the repack's dump left behind, whether the
                 realm listens where it advertises, and the firewall in front
                 of it. Reads only, and names the fix beside each finding.
                 ${C_DIM}Exits non-zero when something is wrong, so it scripts.${C_RST}
  ${C_GREEN}stop${C_RST}           stop the world, then realmd, then the database, in that
                 order; safe to run when some of them are already down
  ${C_GREEN}service${C_RST} [install | remove | status]
                 start the server at boot: install writes a systemd user unit,
                 grants this user lingering and starts it; remove undoes both
                 the unit and the running server; status says where it stands.
                 ${C_DIM}While installed, systemd keeps the server up: a crashed
                 world comes back, and 'run' and 'stop' go through systemctl.${C_RST}
  ${C_GREEN}reset${C_RST} --world | --all [--yes]
                 --world empties the realm: every account, character and pet
                 goes, and the build, the world database and the client stay.
                 --all removes what setup generated (src/, build/, deps/ and
                 the converted server/), keeping client/ and the archives.
                 ${C_DIM}Both ask first; --yes answers for a run with no terminal.${C_RST}
  ${C_GREEN}realm${C_RST} <address> [--bind <address>] | --name <name>
                 set what clients are told to connect to, writing both the
                 realm address and BindIP so the two agree. 127.0.0.1 keeps
                 the realm to this machine. --name sets what the realm list
                 calls this server, offered once during setup as well.
                 ${C_DIM}--bind overrides what the server listens on, which
                 only differs behind a port forward; twow-vm.sh passes
                 0.0.0.0 because qemu's forwards never reach the guest's
                 loopback.${C_RST}
  ${C_GREEN}bots${C_RST} [on | off | --count <n> | --purge]
                 populate the world with AI players: bots that level, quest,
                 group, trade and run the auction house between them. They
                 run on a fork of the core, which is compiled once; on and off
                 switch between the two, and each keeps its own checkout, so
                 switching back is quick.
                 ${C_DIM}Player accounts and characters are never touched.
                 --purge clears the bots' own, which the next boot writes
                 again. With no argument it says which core runs and what
                 changing costs.${C_RST}
  ${C_GREEN}update${C_RST}         after upstream changes: pull the latest source for the core
                 this install runs, rebuild only what changed, back up every
                 database a migration reaches, then apply the new ones.
                 ${C_DIM}Refuses while the world server is running; stop it
                 with Ctrl+C in its console first.${C_RST}
  ${C_GREEN}license${C_RST}        this program's warranty and redistribution terms
  ${C_GREEN}help${C_RST}           this text

${C_BOLD}Files:${C_RST}
  server/bin/mangosd.conf    world server settings (rates, game type, ...)
  server/bin/realmd.conf     login server settings
  server/bin/rate.conf       Turtle's per-level-bracket kill XP tuning
  server/README.linux.md     day-to-day operation guide

First boot: setup asks what 'firstrun' above lists, and points
client/realmlist.wtf at this realm. '$0 account' makes another account.
See README.md for what to download before the first run.

EOF
}

# run only when executed, not when sourced (keeps the functions testable)
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

detect_distro   # package names and the daemon hint, whatever mode we run

mode="${1:-all}"
# What a message suggesting an environment variable should tell the reader to
# re-run; the kit prints those and cannot know the mode by itself.
KIT_RERUN="$0 $mode"
case "$mode" in
  setup|all)
    check_deps; ensure_repack; ensure_mapdata; ensure_source; ensure_ace
    ensure_binaries; fix_configs; fix_client; ensure_database; clean_seed_leftovers
    ensure_migrations
    [[ -t 0 ]] && first_run_questions
    # Last, so the client follows an address the LAN question may have moved.
    sync_client_realmlist
    say "conversion complete"
    say "customize the server anytime with: $0 interactive"
    if [[ "$mode" == all ]]; then run_all "${@:2}"; fi
    ;;
  run) check_deps; run_all "${@:2}" ;;
  interactive) check_deps; ensure_repack; interactive_config ;;
  firstrun)
    check_deps; resolve_db_port; start_native_db; ensure_db_credentials; assert_own_database
    first_run_questions ;;
  account)
    check_deps; resolve_db_port; start_native_db; ensure_db_credentials; assert_own_database
    DB -N -e "SELECT 1 FROM turtle_logon.account LIMIT 1" >/dev/null 2>&1 \
      || die "the game databases are not seeded yet; run: $0 setup"
    # --if-none is what an installer asks for: offer once, on a server where
    # nobody has an account of their own yet, and say nothing on a re-run.
    # Without it the mode is the deliberate "make me another one".
    case "${2:-}" in
      "")         make_gm_account ;;
      --if-none)  if has_own_gm; then say "game master account already there"
                  else make_gm_account; fi ;;
      --list)     [[ -z "${3:-}" || "$3" == --all ]] \
                    || die "unknown option '$3'; --list takes --all, which includes the bots"
                  list_accounts "${3:-}" ;;
      --password) [[ -n "${3:-}" ]] || die "usage: $0 account --password <name>"
                  set_account_password "$3" ;;
      *)          die "unknown option '$2'; account takes --list [--all],
  --password <name>, --if-none, or nothing to create one" ;;
    esac ;;
  realm)
    check_deps; resolve_db_port; start_native_db; ensure_db_credentials; assert_own_database
    [[ -n "${2:-}" ]] \
      || die "usage: $0 realm <address> [--bind <address>]
         $0 realm --name <name>
  <address> is what clients are told to connect to; 127.0.0.1 keeps the realm
  to this machine. --bind overrides what the server listens on, which only
  differs behind a port forward. --name sets what the realm list calls it."
    if [[ "$2" == --name ]]; then
      # --if-default is what an installer asks for: offer once, on a realm still
      # carrying the name the repack shipped, and say nothing on a re-run.
      if [[ "${3:-}" == --if-default ]]; then offer_realm_name; exit 0; fi
      [[ -n "${3:-}" ]] || die "--name needs a realm name, or --if-default to offer one
  while the repack's own name is still in place"
      set_realm_name "$3" || exit 1
      say "the realm is called $3"
      say "restart the server to apply: $0 run"
      exit 0
    fi
    case "${3:-}" in
      "")     set_realm_address "$2" || exit 1 ;;
      --bind) [[ -n "${4:-}" ]] || die "--bind needs an address"
              set_realm_address "$2" "$4" || exit 1 ;;
      *)      die "unknown option '$3'; realm takes --bind <address> or nothing" ;;
    esac
    sync_client_realmlist
    say "realm answers at $2, listening on ${REALM_BIND:-?}"
    say "restart the server to apply: $0 run" ;;
  bots)
    KIT_TAG=bots
    case "${2:-}" in
      # Reporting starts nothing: the cohort is read if a database happens to be
      # up, and left unsaid when it is not.
      "")      resolve_db_port; bots_report ;;
      on)      resolve_db_port; bots_switch bots "${@:3}" ;;
      off)     resolve_db_port; bots_switch stock "${@:3}" ;;
      --count) [[ "$(variant_active)" == bots ]] \
                 || die "this install runs the stock core; turn bots on first: $0 bots on"
               [[ -f "$BOT_CONF" ]] || die "no aiplayerbot.conf yet; run: $0 bots on"
               if [[ -n "${3:-}" ]]; then
                 [[ "$3" =~ ^[0-9]+$ ]] || die "--count needs a number"
                 BOT_COUNT=$3
               else
                 ask_bot_count
               fi
               ensure_variant_conf "$BOT_COUNT"
               say "the realm asks for $BOT_COUNT bots; restart the server to apply: $0 run"
               # A cohort grows on the next boot and never shrinks on its own:
               # the core writes bot characters and leaves them where they are.
               # What the new count asks for is the pool its accounts hold, not
               # the cohort itself, which is drawn from that pool.
               written=$(bot_characters 2>/dev/null) || written=""
               pool=$(( $(bot_accounts_for "$BOT_COUNT") * BOT_CHARS_PER_ACCOUNT ))
               if [[ "$written" =~ ^[0-9]+$ ]] && (( written > pool )); then
                 say "$written bot character(s) are already written; the extra ones stay until: $0 bots --purge"
               else
                 say "the next boot writes what is missing, up to the new count"
               fi ;;
      --purge) resolve_db_port; start_native_db; ensure_db_credentials; assert_own_database
               bots_purge "${3:-}" ;;
      *) die "usage: $0 bots [on | off | --count <number> | --purge]
  on       switch this install to the core that carries AI players
  off      switch back to the core the repack is built from
  --count  how many bots the realm asks for
  --purge  remove the bots and their characters; the next boot writes them again
  nothing  which core is running, and what changing it costs" ;;
    esac ;;
  status)  status_all ;;
  doctor)  doctor_all ;;
  console) console_attach ;;
  logs)    show_logs "${2:-world}" "${3:-}" ;;
  # Stopped through systemd while it owns the server, or the watcher reads the
  # stop as a crash and starts everything back up.
  stop)
    if service_active; then
      say "the server runs as a service; stopping it there, or it comes right back"
      exec systemctl --user stop "$SERVICE_NAME"
    fi
    stop_all ;;
  service)
    case "${2:-status}" in
      install) service_install ;;
      remove)  service_remove ;;
      status)  service_status ;;
      watch)   service_watch ;;
      *) die "usage: $0 service [install | remove | status]
  install  write and enable a systemd user unit, so the server starts at boot
  remove   stop the server and take the unit away
  status   whether one is installed, enabled, and running" ;;
    esac ;;
  reset)
    check_deps; resolve_db_port
    case "${2:-}" in
      --world) start_native_db; ensure_db_credentials; assert_own_database
               reset_world "${3:-}" ;;
      --all)   reset_all "${3:-}" ;;
      *) die "usage: $0 reset --world | --all   [--yes]
  --world empties the realm: every account, character and pet goes, and the
          build, the world database and the client stay
  --all   removes what setup generated (src/, build/, deps/ and the converted
          server/), keeping client/ and the archives beside it" ;;
    esac ;;
  backup)
    check_deps; resolve_db_port; start_native_db; ensure_db_credentials; assert_own_database
    case "${2:-}" in
      "")        backup_all ;;
      --restore) [[ -n "${3:-}" ]] || die "usage: $0 backup --restore <file.sql.gz> [--yes]"
                 restore_backup "$3" "${4:-}" ;;
      *)         die "unknown option '$2'; backup takes --restore <file> [--yes] or nothing" ;;
    esac ;;
  update) check_deps; update_all ;;
  deps)
    case "${2:-}" in
      "")         deps_report ;;
      --packages) dep_packages ;;
      *)          die "unknown option '$2'; deps takes --packages or nothing" ;;
    esac ;;
  license) show_license ;;
  help|-h|--help) usage ;;
  *) warn "unknown mode '$mode'"; usage; exit 1 ;;
esac
