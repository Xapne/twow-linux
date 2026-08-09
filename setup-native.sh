#!/usr/bin/env bash
# =============================================================================
# TurtleWoW 1.18.1: convert the SIGGZ Windows repack to a native Linux server
# and run it, in one command. Works on any Linux distro; every step is idempotent,
# so re-running only does what is missing.
#
# Layout it expects (and creates) under the folder this script lives in:
#   server/   the repack (from TurtleWoW_1.18.zip), native db in server/db
#   client/   the 1.18.1 game client (only needed to play, not to convert)
#   src/      Penqle/tortoise-wow source, branch 1181dev
#   build/    native build tree
#   deps/     locally built ACE library, where the distro packages none
#   lib/      terminal prompts shared with setup-vm.sh
#
# Usage: ./setup-native.sh help
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$ROOT/server"
# shellcheck source=lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=lib/firewall.sh
. "$ROOT/lib/firewall.sh"
# Logging, the database handle, and the port, process and config questions this
# script shares with the scripts in server/. Both used to carry a copy.
# shellcheck source=lib/kit.sh
. "$ROOT/lib/kit.sh"
# Overrides the compile job count worked out below, for a machine the
# measurement no longer fits.
TWOW_BUILD_JOBS=${TWOW_BUILD_JOBS:-}
export TWOW_BUILD_JOBS
ACE_VER=8.0.3
BRANCH=1181dev
REPO=https://github.com/Penqle/tortoise-wow.git

# =============================================================================
# Dependencies: the single source of truth
# =============================================================================
# Every dependency is declared once in DEPS. The missing-dependency report, the
# install command shown on failure, the `deps` mode and setup-vm.sh's guest
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
#             optional  missing only costs build time
#             seed      needed once, for the initial database seed
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
  "wine|cmd|wine|seed|wine|wine|wine|wine"
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
# setup-vm.sh provisions its guest with.
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
      optional) ace_built || later+=("no system ACE; it gets built from source here, which costs
  a few minutes on the first run. Skip that with: $INSTALL $d_pkg") ;;
      seed)     seeded || later+=("the one-time database seed further down needs wine,
  which is missing. Install it before then: $INSTALL $d_pkg") ;;
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
ensure_mapdata() {
  local ok=1 d
  for d in dbc maps mmaps vmaps; do [[ -d "$SERVER/data/$d" ]] || ok=0; done
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
  if [[ -f "$ROOT/src/CMakeLists.txt" ]]; then say "source already in src/"; return; fi
  say "cloning $REPO ($BRANCH)"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$ROOT/src" \
    || die "git clone failed. Check network access and that branch '$BRANCH' still exists."
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
ensure_binaries() {
  if [[ -x "$SERVER/bin/mangosd" && -x "$SERVER/bin/realmd" ]]; then
    say "native binaries already in server/bin/"; return
  fi
  say "configuring and compiling the server (10-20 min on first run)"
  cmake -B "$ROOT/build" -S "$ROOT/src" -GNinja \
    -DCMAKE_BUILD_TYPE=Release -DDEBUG_SYMBOLS=OFF > "$ROOT/build-configure.log" 2>&1 \
    || die "cmake configure failed, see $ROOT/build-configure.log"
  local jobs; jobs=$(build_jobs)
  [[ -n "$jobs" ]] && say "holding the compile to $jobs job(s) to stay inside this cgroup's limits"
  local oom_before; oom_before=$(oom_kills)
  if ! ninja -C "$ROOT/build" ${jobs:+-j"$jobs"} mangosd realmd; then
    (( $(oom_kills) > oom_before )) && die_out_of_memory "$jobs" "$(mem_limit)"
    die "compile failed. Scroll up for the first error; report it on the tortoise-wow GitHub."
  fi
  install_binaries "$ROOT/build/src/mangosd/mangosd" "$ROOT/build/src/realmd/realmd"
  say "installed native mangosd and realmd"
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
  # The repack ships mangosd at LogLevel 3 with the SQL echo on, which buries the
  # console under every statement the core runs. Errors only here; the log file
  # keeps its own detail through LogFileLevel, and 'run <level>' overrides it.
  set_console_level 1
  write_db_env
  say "configs checked (database $TWOW_DB_HOST:$TWOW_DB_PORT, DataDir lowercase)"
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

# Where the realm answers is settled once, in turtle_logon.realmlist, which
# interactive mode writes when it asks about LAN play. The client reads
# client/realmlist.wtf, so it is brought to the same address rather than asked
# again; a client carried over from the live game points at Turtle's own login
# server otherwise, and connects there instead of here.
sync_client_realmlist() {
  local f="$ROOT/client/realmlist.wtf" addr cur want
  [[ -d "$ROOT/client" ]] || return 0
  addr=$(DB -N -B -e "SELECT address FROM turtle_logon.realmlist ORDER BY id LIMIT 1" 2>/dev/null) \
    || return 0
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
  cur=$(DB -N -B -e "SELECT address FROM turtle_logon.realmlist ORDER BY id LIMIT 1" 2>/dev/null) || cur=""
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

# What a finished install still has to ask, listed once. setup-vm.sh runs the
# conversion detached, which leaves it without a terminal, and calls this over
# one afterwards, so a question added here reaches every path.
#
# Each is asked only until it has been answered: a repeated run is silent.
first_run_questions() {
  offer_realm_name
  has_own_gm || make_gm_account
}

# The repack ships ADMIN and TEST at rank 4, so the server never lacks a game
# master; what a new one lacks is an account belonging to whoever set it up.
# Asking only while there is none keeps a repeated setup quiet.
STOCK_ACCOUNTS="'ADMIN','TEST'"
has_own_gm() {
  local n
  n=$(DB -N -B -e "SELECT COUNT(*) FROM turtle_logon.account
        WHERE \`rank\` >= 3 AND username NOT IN ($STOCK_ACCOUNTS)" 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] && ((n > 0))
}

# Vanilla sends SHA1 of USER:PASS upper-cased, so that is what the column
# holds. The name is restricted to what the client can type anyway, which also
# keeps it out of the statement below as anything but a plain word.
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
  hash=$(printf '%s:%s' "$acc" "$pass" | sha1sum | cut -d' ' -f1 | tr a-z A-Z)
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
  local i; for i in $(seq 1 30); do [[ -S "$SERVER/db/mysql.sock" ]] && break; sleep 1; done
  [[ -S "$SERVER/db/mysql.sock" ]] || die "MariaDB did not come up. Last lines of ${SERVER#"$ROOT"/}/logs/mysql.out:

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
clean_seed_leftovers() {
  local before after stock
  stock=$(DB -N -B -e "SELECT COUNT(*) FROM turtle_logon.account
      WHERE username IN ('ADMIN','TEST')
        AND sha_pass_hash = UPPER(SHA1(CONCAT(username, ':', username)))" 2>/dev/null) || stock=0
  before=$(DB -N -B -e "SELECT
      (SELECT COUNT(*) FROM turtle_logon.account
         WHERE username IN ('ADMIN','TEST')
           AND sha_pass_hash = UPPER(SHA1(CONCAT(username, ':', username))))
    + (SELECT COUNT(*) FROM turtle_char.characters c
         LEFT JOIN turtle_logon.account a ON a.id = c.account WHERE a.id IS NULL)
    + (SELECT COUNT(*) FROM turtle_char.character_pet p
         LEFT JOIN turtle_char.characters c ON c.guid = p.owner WHERE c.guid IS NULL)" 2>/dev/null) || return 0
  [[ "$before" =~ ^[0-9]+$ ]] || return 0
  (( before > 0 )) || return 0

  DB turtle_char <<'SQL' >/dev/null 2>&1 || { warn "could not clear what the repack's dump left behind; ADMIN and TEST may still be able to log in"; return 0; }
CREATE TEMPORARY TABLE twow_stock (id INT UNSIGNED PRIMARY KEY);
INSERT INTO twow_stock
  SELECT id FROM turtle_logon.account
   WHERE username IN ('ADMIN','TEST')
     AND sha_pass_hash = UPPER(SHA1(CONCAT(username, ':', username)));

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

  after=$(DB -N -B -e "SELECT
      (SELECT COUNT(*) FROM turtle_logon.account
         WHERE username IN ('ADMIN','TEST')
           AND sha_pass_hash = UPPER(SHA1(CONCAT(username, ':', username))))
    + (SELECT COUNT(*) FROM turtle_char.characters c
         LEFT JOIN turtle_logon.account a ON a.id = c.account WHERE a.id IS NULL)
    + (SELECT COUNT(*) FROM turtle_char.character_pet p
         LEFT JOIN turtle_char.characters c ON c.guid = p.owner WHERE c.guid IS NULL)" 2>/dev/null) || after=0
  say "cleared $(( before - after )) row(s) the repack's dump arrived with; the realm starts empty"
  (( stock > 0 )) && say "ADMIN and TEST are gone with it; an account keeps its place here once its password is changed"
  return 0
}

# -----------------------------------------------------------------------------
# bring the world DB schema up to what the compiled source expects
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
# The prompts themselves live in lib/ui.sh, shared with setup-vm.sh.
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
    if rname="$(DB -N -e 'SELECT name FROM turtle_logon.realmlist LIMIT 1' 2>/dev/null)"; then
      have_db=1
      raddr="$(DB -N -e 'SELECT address FROM turtle_logon.realmlist LIMIT 1' 2>/dev/null)" || raddr=""
    fi
  fi

  ui_banner "apne's all-in-one CLI" "for TurtleWoW on Linux"
  ui_intro "server configuration"
  ui_note "Enter keeps the shown value · pick from lists with ↑/↓ + Enter · Ctrl+C quits"

  if (( have_db )); then
    ui_text "Realm name (shown in the in-game realm list)" "$rname"
    set_realm_name "$ANSWER" || ui_warn "the realm name is still $rname"

    local defidx=0; [[ -n "$raddr" && "$raddr" != 127.0.0.1 ]] && defidx=1
    ui_select "Who can connect?" "$defidx" \
      "Only this machine (127.0.0.1)" \
      "My local network (LAN play)"
    if (( ANSWER == 1 )); then
      local lanip=""
      [[ -n "$raddr" && "$raddr" != 127.0.0.1 ]] && lanip="$raddr"
      [[ -n "$lanip" ]] || lanip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
      ui_text "This machine's LAN IP (clients connect here)" "${lanip:-192.168.?.?}"
      if set_realm_address "$ANSWER"; then
        # Only now: a realm nobody outside can reach is the point of the
        # question just answered, and a firewall is the usual reason it stays
        # unreachable after everything here is set correctly.
        fw_offer_ports "$(realm_port)" "$(world_port)"
      else
        ui_warn "leaving the realm address unchanged"
      fi
    else
      set_realm_address 127.0.0.1
    fi
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
# Update: pull the latest source, rebuild incrementally, back up the world DB,
# apply new migrations. Refuses while the world server is running.
# -----------------------------------------------------------------------------
update_all() {
  [[ -d "$ROOT/src/.git" ]] || die "no source checkout in src/; run: $0 setup"
  [[ -x "$SERVER/bin/mangosd" ]] || die "not converted yet; run: $0 setup"
  # mangosd renames its main thread, so its /proc comm is "MainThread" and
  # pgrep -x never matches it; match the command line instead.
  if world_running; then
    die "the world server is running; stop it first.
  In its console: Ctrl+C. Detached: pkill -TERM -f 'mangosd -c'
  SIGINT is the core's restart signal; with pkill -INT the world is only restarted.
  Swapping schema under a live server is how characters get eaten."
  fi
  if pgrep -f 'realmd -c' >/dev/null 2>&1; then
    pkill -INT -f 'realmd -c'; sleep 1
    say "stopped realmd (a running binary cannot be replaced)"
  fi

  say "pulling latest $BRANCH source"
  local before after
  before=$(git -C "$ROOT/src" rev-parse --short HEAD)
  git -C "$ROOT/src" pull --ff-only \
    || die "git pull failed (local changes in src/? no network?); nothing was touched"
  after=$(git -C "$ROOT/src" rev-parse --short HEAD)
  if [[ "$before" == "$after" ]]; then
    say "source already at $after; still checking build and migrations"
  else
    say "source updated: $before -> $after"
  fi

  say "rebuilding mangosd and realmd (incremental, only what changed)"
  # ninja re-runs cmake itself when the source's build files changed, and that
  # re-run needs the same ACE in the environment as the first configure
  select_ace
  [[ -f "$ROOT/build/build.ninja" ]] \
    || cmake -B "$ROOT/build" -S "$ROOT/src" -GNinja \
         -DCMAKE_BUILD_TYPE=Release -DDEBUG_SYMBOLS=OFF > "$ROOT/build-configure.log" 2>&1 \
    || die "cmake configure failed, see $ROOT/build-configure.log"
  local jobs; jobs=$(build_jobs)
  [[ -n "$jobs" ]] && say "holding the compile to $jobs job(s) to stay inside this cgroup's limits"
  local oom_before; oom_before=$(oom_kills)
  if ! ninja -C "$ROOT/build" ${jobs:+-j"$jobs"} mangosd realmd; then
    (( $(oom_kills) > oom_before )) && die_out_of_memory "$jobs" "$(mem_limit)"
    die "compile failed; the installed binaries were not touched.
  Fix the error above or report it on the tortoise-wow GitHub."
  fi
  install_binaries "$ROOT/build/src/mangosd/mangosd" "$ROOT/build/src/realmd/realmd"
  say "installed updated binaries into server/bin/"

  start_native_db
  mkdir -p "$SERVER/backups"
  local backup="$SERVER/backups/turtle_world-$(date +%Y%m%d-%H%M%S)-$after.sql.gz"
  say "backing up turtle_world before migrations"
  mariadb-dump -h "$TWOW_DB_HOST" -P "$TWOW_DB_PORT" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" \
      --routines --triggers turtle_world | gzip > "$backup" \
    || die "backup failed; not touching the database"
  say "backup: ${backup#"$ROOT"/}"
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
    mapfile -t old < <(ls -1t "$dir/$f-"*.sql.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)))
    ((${#old[@]})) && { rm -f "${old[@]}"; say "pruned ${#old[@]} old $f backup(s), keeping $BACKUP_KEEP"; }
  done
  return 0
}

# Restoring overwrites live characters, so it refuses while the world is up and
# says plainly what it is about to replace.
restore_backup() {  # $1 path to a .sql.gz written by backup_all
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
  warn "about to replace everything in $db with the contents of ${file##*/}"
  ui_select "This cannot be undone. Continue?" 1 "Yes, restore it" "No, stop here"
  (( ANSWER == 0 )) || { say "nothing restored"; return 0; }
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
    # the run wrapper would answer by starting the world again).
    pkill -TERM -f 'mangosd -c' 2>/dev/null || true
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
run_all() {
  [[ -x "$SERVER/bin/mangosd" ]] || die "no native binaries yet; run: $0 setup"
  local s
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

  say "starting mangosd in the foreground; this terminal is the server console"
  say "first boot loads all maps and takes a few minutes; stop with Ctrl+C"
  # Called rather than exec'd, and the note printed after it rather than from an
  # EXIT trap: exec replaces this shell outright, so a trap set here would never
  # run and nothing would say what was left behind.
  local rc=0
  "$SERVER/3-world-server.sh" "$@" || rc=$?
  warn "world server stopped; realmd and MariaDB are still running.
  Stop them with: $0 stop     (or $0 status to see what is up)"
  return $rc
}

# -----------------------------------------------------------------------------
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
  ${C_GREEN}run${C_RST} [level]    start only: MariaDB and realmd in the background,
                 mangosd in the foreground as the server console
                 (Ctrl+C stops it); optional [level] is the mangosd
                 console log level, 0 (quiet) to 3 (debug)
  ${C_GREEN}firstrun${C_RST}       the questions a finished install still has: a name for the
                 realm and a game master account, each asked only until it
                 has been answered.
                 ${C_DIM}Part of setup already; setup-vm.sh calls it on its own
                 because its conversion runs without a terminal.${C_RST}
  ${C_GREEN}account${C_RST} [--if-none]
                 create a game master account and log in as yourself
                 instead of the repack's shared ADMIN. Offered once at the
                 end of setup; this runs it again whenever you want.
                 ${C_DIM}--if-none offers only while no account of your own
                 exists, which is what setup-vm.sh calls.${C_RST}
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
                 the bare list (setup-vm.sh provisions its guest with it)
  ${C_GREEN}backup${C_RST} [--restore <file>]
                 dump characters and accounts into server/backups, keeping
                 the newest ${C_DIM}TWOW_BACKUP_KEEP${C_RST} of each (default 10). Safe to run
                 while the server is up. --restore puts one back, which
                 refuses while the world is running.
                 ${C_DIM}turtle_world is not backed up here: setup and update
                 rebuild it. Characters and accounts cannot be rebuilt.${C_RST}
  ${C_GREEN}status${C_RST}         what is running: database, realmd, world, and their ports
  ${C_GREEN}stop${C_RST}           stop the world, then realmd, then the database, in that
                 order; safe to run when some of them are already down
  ${C_GREEN}realm${C_RST} <address> [--bind <address>] | --name <name>
                 set what clients are told to connect to, writing both the
                 realm address and BindIP so the two agree. 127.0.0.1 keeps
                 the realm to this machine. --name sets what the realm list
                 calls this server, offered once during setup as well.
                 ${C_DIM}--bind overrides what the server listens on, which
                 only differs behind a port forward; setup-vm.sh passes
                 0.0.0.0 because qemu's forwards never reach the guest's
                 loopback.${C_RST}
  ${C_GREEN}update${C_RST}         after upstream changes: pull the latest 1181dev source,
                 rebuild only what changed, back up the world database,
                 then apply any new schema migrations.
                 ${C_DIM}Refuses while the world server is running; stop it
                 with Ctrl+C in its console first.${C_RST}
  ${C_GREEN}help${C_RST}           this text

${C_BOLD}Files:${C_RST}
  server/bin/mangosd.conf    world server settings (rates, game type, ...)
  server/bin/realmd.conf     login server settings
  server/bin/rate.conf       Turtle's per-level-bracket kill XP tuning
  server/README.linux.md     day-to-day operation guide

First boot: setup offers a name for the realm and a game master account of your
own, and points client/realmlist.wtf at this realm. '$0 account' makes another.
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
    sync_client_realmlist
    [[ -t 0 ]] && first_run_questions
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
      "")        make_gm_account ;;
      --if-none) has_own_gm && say "game master account already there" || make_gm_account ;;
      *)         die "unknown option '$2'; account takes --if-none or nothing" ;;
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
  status) status_all ;;
  stop)   stop_all ;;
  backup)
    check_deps; resolve_db_port; start_native_db; ensure_db_credentials; assert_own_database
    case "${2:-}" in
      "")        backup_all ;;
      --restore) [[ -n "${3:-}" ]] || die "usage: $0 backup --restore <file.sql.gz>"
                 restore_backup "$3" ;;
      *)         die "unknown option '$2'; backup takes --restore <file> or nothing" ;;
    esac ;;
  update) check_deps; update_all ;;
  deps)
    case "${2:-}" in
      "")         deps_report ;;
      --packages) dep_packages ;;
      *)          die "unknown option '$2'; deps takes --packages or nothing" ;;
    esac ;;
  help|-h|--help) usage ;;
  *) warn "unknown mode '$mode'"; usage; exit 1 ;;
esac
