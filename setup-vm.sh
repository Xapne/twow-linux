#!/usr/bin/env bash
# =============================================================================
# TurtleWoW 1.18.1: from any Linux host to a live world console, one command.
# Parent of twow-linux/setup-native.sh: births a headless Debian VM, provisions
# it, pushes the repack + map data in, runs the whole conversion, and hands
# this terminal over as the mangos world console. Every step is idempotent.
#
# Layout it expects (and creates) under the work dir (default ~/twow-vm):
#   debian-cloud.qcow2   downloaded automatically (cloud.debian.org)
#   TurtleWoW_1.18.zip   you bring this (SIGGZ repack)
#   data.zip             you bring this (pre-made map data)
#   turtle.qcow2, seed.iso, vmkey[.pub], logs/
#   vm.id                marks the dir as holding a VM built here, which is
#                        what 'vms' lists and what 'destroy' is allowed to remove
#
# Usage: ./setup-vm.sh help
# =============================================================================
set -euo pipefail

WORKDIR="${TWOW_VM_DIR:-$HOME/twow-vm}"
IMG_URL=https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
IMG=debian-cloud.qcow2
DISK=turtle.qcow2
DISK_SIZE="${TWOW_VM_DISK:-40G}"
SSH_PORT="${TWOW_SSH_PORT:-2222}" REALM_PORT=3724 WORLD_PORT=8091
# Hardware: adapt to the host, override with TWOW_VM_CPUS / TWOW_VM_MEM.
# Cores speed up the one big compile; 4 GB is enough to build and run, more
# only helps the world server cache maps.
VM_CPUS="${TWOW_VM_CPUS:-$(( $(nproc) < 8 ? $(nproc) : 8 ))}"
host_mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
VM_MEM="${TWOW_VM_MEM:-$(( host_mem_gb / 2 < 12 ? (host_mem_gb / 2 < 4 ? 4 : host_mem_gb / 2) : 12 ))G}"
KIT_REPO=https://github.com/Xapne/twow-linux.git
# on-screen form of the work dir: never print the expanded home directory
WD="${WORKDIR/#$HOME/\~}"

# --- VM identity --------------------------------------------------------------
# One VM per work dir, named after a digest of that dir's path: the same
# directory always produces the same name, and two work dirs never collide.
# The name is handed to qemu with -name, which places it in the process list,
# and that is what tells a VM booted from here apart from every other VM on the
# host. The marker file records the same for a VM that is powered off, and the
# registry remembers work dirs so they can be listed from anywhere.
VM_NAME="twow-$(printf '%s' "$WORKDIR" | sha1sum | cut -c1-6)"
MARKER=vm.id
REGISTRY="${XDG_STATE_HOME:-$HOME/.local/state}/twow-vm/workdirs"

# --- looks and prompts: shared with setup-native.sh, see lib/ui.sh ----------
# shellcheck source=lib/ui.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

# Log helpers stay here: setup-native.sh prints "[setup]" lines that convert()
# parses for the progress bar, so the two scripts speak differently on purpose.
say()  { printf '%s\n%s  %s\n' "$GUT" "${C_GREEN}◇${C_RST}" "$*"; }
note() { printf '%s  %s\n' "$GUT" "${C_DIM}$*${C_RST}"; }
warn() { printf '%s  %s\n' "$GUT" "${C_YELLOW}$*${C_RST}"; }
die()  { printf '%s\n%s  %s\n' "$GUT" "${C_RED}✖${C_RST}" "$*" >&2; exit 1; }

# --- smart progress bar ------------------------------------------------------
# bar <percent> <label>  - redraws in place on one gutter line
bar() {
  local pct=$1 label=$2 width=24 filled empty fstr estr
  (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 )); empty=$(( width - filled ))
  printf -v fstr '%*s' "$filled" ''; fstr=${fstr// /█}
  printf -v estr '%*s' "$empty"  ''; estr=${estr// /░}
  printf '\r\033[2K%s  %s%s%s%s%s %3d%%  %s' "$GUT" \
    "$C_CYAN" "$fstr" "$C_GRAY" "$estr" "$C_RST" "$pct" "${C_DIM}${label}${C_RST}"
}
bar_done() { printf '\r\033[2K'; say "$1"; }

# --- ssh plumbing -------------------------------------------------------------
SSHOPTS=(-p "$SSH_PORT" -i "$WORKDIR/vmkey" -o StrictHostKeyChecking=accept-new
         -o UserKnownHostsFile="$WORKDIR/known_hosts" -o LogLevel=ERROR)
vm()   { ssh  "${SSHOPTS[@]}" turtle@127.0.0.1 "$@"; }
vmtty(){ ssh -t "${SSHOPTS[@]}" turtle@127.0.0.1 "$@"; }
vm_up(){ vm -o ConnectTimeout=3 true 2>/dev/null; }

# =============================================================================
# host dependencies, reactive on the distro
# =============================================================================
host_deps() {
  local need=(qemu-system-x86_64 qemu-img xorriso curl ssh scp ss sha1sum)
  local missing=() c
  for c in "${need[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]} == 0)); then say "host tools present"; return; fi

  local id pm="" pkgs=""
  id=$(. /etc/os-release 2>/dev/null && echo "${ID:-} ${ID_LIKE:-}") || id=""
  case " $id " in
    *" arch "*|*" manjaro "*|*" endeavouros "*) pm="sudo pacman -S --needed"; pkgs="qemu-full libisoburn openssh iproute2 coreutils curl";;
    *" debian "*|*" ubuntu "*)                  pm="sudo apt update && sudo apt install -y"; pkgs="qemu-system-x86 qemu-utils xorriso openssh-client iproute2 coreutils curl";;
    *" fedora "*|*" rhel "*|*" centos "*)       pm="sudo dnf install -y"; pkgs="qemu-kvm qemu-img xorriso openssh-clients iproute coreutils curl";;
    *" suse "*|*" opensuse "*)                  pm="sudo zypper install -y"; pkgs="qemu-kvm qemu-tools xorriso openssh iproute2 coreutils curl";;
  esac
  [[ -n "$pm" ]] || die "missing host tools: ${missing[*]}
  Unrecognized distro - install the equivalents of: qemu, qemu-img, xorriso, openssh, curl"

  warn "missing host tools: ${missing[*]}"
  ui_select "Install them now? ($pm $pkgs)" 0 "Yes, run it (needs sudo)" "No, I'll do it myself"
  (( ANSWER == 0 )) || die "install them, then run $0 again: $pm $pkgs"
  eval "$pm $pkgs" || die "package install failed"
  say "host tools installed"
}

kvm_check() {
  [[ -e /dev/kvm ]] || die "/dev/kvm missing - enable virtualization in BIOS/UEFI"
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "no access to /dev/kvm - add yourself to the kvm group and re-login:
  sudo usermod -aG kvm $USER"
  say "KVM available"
}

# host has to fit the VM's memory and ~15 GB of disk for image + zips + guest
resource_check() {
  if (( host_mem_gb < 6 )); then
    warn "only ${host_mem_gb} GB RAM on this host; the VM gets $VM_MEM"
    note "trying anyway - the compile is the tight part, and it may swap or"
    note "run out of memory. If it dies: TWOW_VM_CPUS=2 $0 (fewer parallel"
    note "compile jobs need less memory), or build on a bigger machine."
  fi
  local free_gb
  free_gb=$(df -BG --output=avail "$WORKDIR" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -n "$free_gb" ]] && (( free_gb < 15 )); then
    warn "only ${free_gb} GB free in $WD - image, zips and the guest need about 15 GB"
    ui_select "Continue anyway?" 1 "Yes, continue" "No, stop here"
    (( ANSWER == 0 )) || die "free some space, or point elsewhere: TWOW_VM_DIR=/other/disk $0"
  fi
  say "host resources: $VM_CPUS cores and $VM_MEM for the VM"
}

# =============================================================================
# the payload zips - find them or ask
# =============================================================================
find_payload() {
  local f
  for f in TurtleWoW_1.18.zip data.zip; do
    if [[ ! -f "$WORKDIR/$f" ]]; then
      local guess=""
      for d in . "$HOME/Downloads" "$HOME"; do [[ -f "$d/$f" ]] && { guess="$d/$f"; break; }; done
      if [[ -n "$guess" ]]; then
        ui_select "$f found at $guess - use it?" 0 "Yes, copy it into $WD" "No, I'll give a path"
        if (( ANSWER == 0 )); then cp --reflink=auto "$guess" "$WORKDIR/"; else
          ui_text "Path to $f" ""
          [[ -f "$ANSWER" ]] || die "$ANSWER does not exist"
          cp --reflink=auto "$ANSWER" "$WORKDIR/$f"
        fi
      else
        ui_text "Path to $f (SIGGZ repack + map data, see the video description)" ""
        [[ -f "$ANSWER" ]] || die "$ANSWER does not exist"
        cp --reflink=auto "$ANSWER" "$WORKDIR/$f"
      fi
    fi
  done
  say "payload in place: TurtleWoW_1.18.zip + data.zip"
}

# =============================================================================
# image, seed, disk, boot
# =============================================================================
fetch_image() {
  [[ -f "$WORKDIR/$IMG" ]] && { say "cloud image already downloaded"; return; }
  say "downloading Debian's official cloud image (~330 MB)"
  note "$IMG_URL"
  curl -fL --progress-bar -o "$WORKDIR/$IMG.part" "$IMG_URL" || die "download failed"
  mv "$WORKDIR/$IMG.part" "$WORKDIR/$IMG"
}

make_seed() {
  [[ -f "$WORKDIR/seed.iso" && -f "$WORKDIR/vmkey" ]] && { say "cloud-init seed ready"; return; }
  say "building the cloud-init seed (user turtle / turtle)"
  [[ -f "$WORKDIR/vmkey" ]] || ssh-keygen -t ed25519 -N '' -q -f "$WORKDIR/vmkey" -C twow-vm
  cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: turtle
users:
  - name: turtle
    plain_text_passwd: turtle
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$WORKDIR/vmkey.pub")
ssh_pwauth: true
EOF
  printf 'instance-id: turtle-01\nlocal-hostname: turtle\n' > "$WORKDIR/meta-data"
  ( cd "$WORKDIR" && xorriso -as mkisofs -quiet -o seed.iso -V cidata -J -r user-data meta-data )
}

make_disk() {
  [[ -f "$WORKDIR/$DISK" ]] && { say "VM disk exists (delete $WD/$DISK for a clean rebuild)"; return; }
  say "creating $DISK_SIZE overlay disk on top of the stock image"
  qemu-img create -q -f qcow2 -b "$IMG" -F qcow2 "$WORKDIR/$DISK" "$DISK_SIZE"
  ( cd "$WORKDIR" && qemu-img rebase -u -b "$IMG" -F qcow2 "$DISK" 2>/dev/null || true )
  vm_register
}

boot_vm() {
  vm_register   # also marks work dirs that predate the marker
  if vm_up; then say "VM already running"; return; fi
  for p in "$SSH_PORT" "$REALM_PORT" "$WORLD_PORT"; do
    ss -tln | grep -q ":$p " && die "port $p is already in use on this host - something else is running there"
  done
  say "booting the VM headless as $VM_NAME ($VM_CPUS cores, $VM_MEM, ports $SSH_PORT/$REALM_PORT/$WORLD_PORT)"
  # -name puts the identity in the process list, which is how this VM is found
  # again later without matching on a disk filename every work dir shares.
  ( cd "$WORKDIR" && qemu-system-x86_64 -enable-kvm -cpu host -smp "$VM_CPUS" -m "$VM_MEM" \
      -name "$VM_NAME" \
      -drive file="$DISK",if=virtio \
      -drive file=seed.iso,media=cdrom \
      -nic user,model=virtio-net-pci,hostfwd=tcp::"$SSH_PORT"-:22,hostfwd=tcp::"$REALM_PORT"-:3724,hostfwd=tcp::"$WORLD_PORT"-:"$WORLD_PORT" \
      -serial file:logs/serial.log -display none -daemonize -pidfile qemu.pid )
  local i spin='|/-\'
  for i in $(seq 1 60); do
    vm_up && { printf '\r\033[2K'; say "VM is up, ssh answering on $SSH_PORT"; return; }
    printf '\r%s  %s waiting for first boot %s' "$GUT" "${C_DIM}cloud-init runs once${C_RST}" "${spin:i%4:1}"
    sleep 3
  done
  die "VM did not come up - check $WD/logs/serial.log"
}

# =============================================================================
# provision the guest (Debian deps + the two quirk fixes + the kit)
# =============================================================================
provision() {
  if vm 'command -v ninja >/dev/null && command -v mariadbd >/dev/null && test -d twow' 2>/dev/null; then
    say "guest already provisioned"; return
  fi
  say "provisioning the guest (apt + the kit)"
  note "full log: $WD/logs/provision.log"
  vm "KIT_REPO='$KIT_REPO' bash -s" > "$WORKDIR/logs/provision.log" 2>&1 <<'GUEST' || die "provisioning failed, see $WD/logs/provision.log"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get full-upgrade -y -qq
# The kit names its own dependencies (the DEPS table in setup-native.sh is the
# only list of them), so it is cloned first and then asked what to install.
sudo apt-get install -y -qq git
[ -d twow ] || git clone -q "$KIT_REPO" twow
sudo apt-get install -y -qq $(twow/setup-native.sh deps --packages)
# quirk 1: Debian autostarts a system mariadb on 3306; the kit runs its own
sudo systemctl disable --now mariadb
GUEST
  say "guest provisioned"
}

push_payload() {
  local stale=0 f
  for f in TurtleWoW_1.18.zip data.zip; do
    local lsize rsize
    lsize=$(stat -c%s "$WORKDIR/$f")
    rsize=$(vm "stat -c%s twow/$f 2>/dev/null" || echo 0)
    [[ "$lsize" == "$rsize" ]] || stale=1
  done
  (( stale )) || { say "payload already inside the VM"; return; }
  say "pushing the repack + map data into the VM (1.4 GB)"
  scp -q -P "$SSH_PORT" -i "$WORKDIR/vmkey" -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$WORKDIR/known_hosts" -o LogLevel=ERROR \
    "$WORKDIR/TurtleWoW_1.18.zip" "$WORKDIR/data.zip" turtle@127.0.0.1:twow/
  say "payload delivered"
}

# =============================================================================
# the conversion, with a live progress bar parsed from setup.log
# =============================================================================
convert() {
  if vm 'test -x twow/server/bin/mangosd && grep -q "conversion complete" twow/setup.log 2>/dev/null'; then
    say "already converted"; return
  fi
  say "running the conversion (this is the long one: full compile + db seed)"
  vm 'cd twow && rm -f setup.log && (nohup ./setup-native.sh setup > setup.log 2>&1 & echo started)' >/dev/null

  local t=0 pct=2 label="checking dependencies" tail="" poll="" alive=""
  while :; do
    sleep 3; t=$((t+3))
    # one ssh per poll, carrying the log tail AND the liveness flag together;
    # an empty poll is a transient ssh hiccup, never a verdict
    poll=$(vm 'tail -n 30 twow/setup.log 2>/dev/null | tr -d "\r"; pgrep -f setup-native.sh >/dev/null && echo "==ALIVE==" || echo "==DEAD=="' 2>/dev/null) || poll=""
    [[ -z "$poll" ]] && continue
    if grep -q '==DEAD==' <<<"$poll"; then alive=no; else alive=yes; fi
    # '|| true': on the first polls the log can still be empty, leaving only
    # the marker line - a fully filtered grep exits 1 and set -e would kill us
    tail=$(grep -v '^==\(ALIVE\|DEAD\)==$' <<<"$poll" || true)
    if grep -q '\[error\]' <<<"$tail"; then
      printf '\n'; die "conversion failed inside the VM:
$(grep -A3 '\[error\]' <<<"$tail")"
    fi
    if grep -q 'conversion complete' <<<"$tail"; then
      bar 100 "conversion complete"; printf '\n'; break
    fi
    # milestones -> percent; the compile maps its [n/total] onto 35..85
    local ninja
    ninja=$(grep -oE '^\[[0-9]+/[0-9]+\]' <<<"$tail" | tail -1 | tr -d '[]' || true)
    if   [[ -n "$ninja" ]]; then
      local done_n=${ninja%/*} total_n=${ninja#*/}
      pct=$(( 35 + done_n * 50 / (total_n>0?total_n:1) )); label="compiling mangosd + realmd [$ninja]"
    elif grep -q 'migration'                <<<"$tail"; then pct=95; label="applying database migrations"
    elif grep -q 'seeding databases'        <<<"$tail"; then pct=90; label="seeding databases through wine (one time)"
    elif grep -q 'native MariaDB'           <<<"$tail"; then pct=87; label="starting the native database"
    elif grep -q 'compiling the server'     <<<"$tail"; then pct=35; label="configuring the build"
    elif grep -q 'building ACE'             <<<"$tail"; then pct=28; label="building the ACE library"
    elif grep -q 'cloning'                  <<<"$tail"; then pct=22; label="cloning the 1181dev source"
    elif grep -q 'map data'                 <<<"$tail"; then pct=12; label="unpacking map data"
    elif grep -q 'extracting repack'        <<<"$tail"; then pct=6;  label="extracting the repack"
    fi
    bar "$pct" "$label  ${C_GRAY}$((t/60))m$((t%60))s${C_RST}"
    if [[ "$alive" == no ]]; then
      # confirmed dead in the same poll that read the log: re-check the log
      # once for a completion we may have raced, then fail for real
      sleep 2
      vm 'grep -q "conversion complete" twow/setup.log' 2>/dev/null \
        || { printf '\n'; die "setup-native.sh stopped early - last log lines:
$(vm 'tail -n 15 twow/setup.log' 2>/dev/null)"; }
      bar 100 "conversion complete"; printf '\n'; break
    fi
  done
}

# =============================================================================
# open the server to the qemu port forwards
# The repack binds to 127.0.0.1 inside the VM, which the forwards cannot
# reach (they target the VM's 10.0.2.15). BindIP 0.0.0.0 opens it while the
# realm keeps advertising 127.0.0.1 - correct for a client on this host.
# =============================================================================
open_forwards() {
  vm 'sed -i "s/^BindIP.*/BindIP = \"0.0.0.0\"/" twow/server/bin/realmd.conf twow/server/bin/mangosd.conf'
  # advertise this host's LAN address: works for LAN clients AND for a client
  # on this host (it reaches its own LAN IP through the same forwards)
  local lanip
  lanip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)
  if [[ -n "$lanip" ]]; then
    vm "mariadb --socket=twow/server/db/mysql.sock -u root -pmangos turtle_logon -e \"UPDATE realmlist SET address='$lanip'\""
    say "realm reachable from this host and the LAN: set realmlist $lanip"
    note "if a firewall runs here, open tcp $REALM_PORT and $WORLD_PORT"
  else
    say "no LAN address detected - realm stays at 127.0.0.1 (this host only)"
  fi
}

# =============================================================================
# GM account - do it for them, and teach the console way
# =============================================================================
make_account() {
  ui_intro "game master account"
  note "how it works in the world console:  account create <name> <pass>"
  note "                                    account set gmlevel <name> 3"
  ui_select "Create a GM account now, before the world starts?" 0 \
    "Yes, create one for me" "Skip, I'll do it in the console"
  (( ANSWER == 0 )) || { ui_outro "skipped - use the console commands above once the world is up"; return; }
  ui_text "Account name" "apostle"
  local acc=${ANSWER^^}
  ui_text "Password" "mysecret"
  local pass=${ANSWER^^}
  local hash
  hash=$(printf '%s:%s' "$acc" "$pass" | sha1sum | cut -d' ' -f1 | tr a-z A-Z)
  vm "mariadb --socket=twow/server/db/mysql.sock -u root -pmangos turtle_logon -e \"
    INSERT INTO account (username, sha_pass_hash, joindate) VALUES ('$acc','$hash',NOW())
      ON DUPLICATE KEY UPDATE sha_pass_hash='$hash';
    UPDATE account SET rank = 3 WHERE username = '$acc';\"" \
    || { warn "database insert failed - create it in the console instead (commands above)"; return; }
  ui_outro "GM account ready: ${C_BOLD}${acc,,}${C_RST} (rank 3) - log in with it from the client"
}

# =============================================================================
# handoff - this terminal becomes the world console
# =============================================================================
handoff() {
  ui_intro "starting the world"
  note "realmd + MariaDB stay in the background; mangosd runs in THIS terminal"
  note "first boot loads every map - give it a few minutes"
  note "prove it is alive:   server info   (console log level is 1 = errors only)"
  note "make a GM account:   account create <name> <pass>  +  account set gmlevel <name> 3"
  note "stop the world:      Ctrl+C   (VM keeps running; '$0 console' returns here)"
  note "make it yours:       $0 tune   (realm name, rates, LAN play)"
  ui_outro "handing over in 3 seconds"
  sleep 3
  exec ssh -t "${SSHOPTS[@]}" turtle@127.0.0.1 'cd twow && ./setup-native.sh run 1'
}

# =============================================================================
status() {
  ui_intro "status"
  if vm_up; then note "VM: running (ssh $SSH_PORT)"; else note "VM: not running"; fi
  if vm_up; then
    vm 'test -x twow/server/bin/mangosd' 2>/dev/null && note "conversion: done" || note "conversion: not done"
    vm 'ss -tln | grep -q ":3724 "' 2>/dev/null && note "realmd: up (3724)" || note "realmd: down"
    vm "ss -tln | grep -q ':$WORLD_PORT '" 2>/dev/null && note "mangosd: up ($WORLD_PORT)" || note "mangosd: down"
  fi
  ui_outro "work dir: $WD"
}

# =============================================================================
# discovering VMs: this script's, and everyone else's
# =============================================================================
# Ownership is proved by the marker file, never by a filename: every work dir
# calls its disk turtle.qcow2, so matching on that would sweep up a second VM
# from here and any unrelated qemu process that happens to mention it.
vm_register() {
  mkdir -p "$(dirname "$REGISTRY")"
  cat > "$WORKDIR/$MARKER" <<EOF
# Written by setup-vm.sh. Its presence marks this directory as holding a VM
# that setup-vm.sh created, and is what permits 'setup-vm.sh destroy' to
# remove it.
name=$VM_NAME
disk=$DISK
EOF
  grep -qxF "$WORKDIR" "$REGISTRY" 2>/dev/null || printf '%s\n' "$WORKDIR" >> "$REGISTRY"
}

# Work dirs holding a VM from here, with vanished ones dropped from the registry.
vm_known_dirs() {
  local d keep=()
  if [[ -f "$REGISTRY" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" && -f "$d/$MARKER" ]] || continue
      [[ " ${keep[*]-} " == *" $d "* ]] && continue
      keep+=("$d")
    done < "$REGISTRY"
  fi
  if [[ -f "$WORKDIR/$MARKER" && " ${keep[*]-} " != *" $WORKDIR "* ]]; then
    keep+=("$WORKDIR")
  fi
  if ((${#keep[@]})); then
    mkdir -p "$(dirname "$REGISTRY")"
    printf '%s\n' "${keep[@]}" > "$REGISTRY"
    printf '%s\n' "${keep[@]}"
  fi
}

vm_name_of() { { sed -n 's/^name=//p' "$1/$MARKER" 2>/dev/null || true; } | head -1; }

# The qemu pid for one name, empty when that VM is not running. Absence is a
# normal answer here, so a failed pgrep must not surface as a failed command.
vm_pid_of() { { pgrep -f -- "-name $1( |\$)" 2>/dev/null || true; } | head -1; }

# The qemu pid for a work dir. VMs booted before -name was passed carry no
# identity in their command line, so the pidfile answers for those, checked
# against /proc so a stale pid cannot be mistaken for a live VM.
vm_pid_in() {
  local d=$1 n pid=""
  n=$(vm_name_of "$d")
  [[ -n "$n" ]] && pid=$(vm_pid_of "$n")
  if [[ -z "$pid" && -f "$d/qemu.pid" ]]; then
    pid=$(cat "$d/qemu.pid" 2>/dev/null || true)
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null \
       || ! grep -qa qemu "/proc/$pid/cmdline" 2>/dev/null; then
      pid=""
    fi
  fi
  printf '%s' "$pid"
}

# Work dirs built before the marker existed. The overlay disk beside this
# script's own ssh key is a combination nothing else leaves behind, so such a
# directory is adopted rather than reported as belonging to someone else.
vm_adopt_legacy() {
  [[ -f "$WORKDIR/$MARKER" ]] && return 0
  [[ -f "$WORKDIR/$DISK" && -f "$WORKDIR/vmkey" ]] || return 0
  vm_register
  note "adopted the VM already in $WD"
}

# Everything else running under qemu on this host. Read-only, and listed purely
# so it is visible that these stay untouched.
vm_foreign() {
  pgrep -af 'qemu-system' 2>/dev/null | grep -v -- '-name twow-' || true
}

vm_libvirt() {
  command -v virsh >/dev/null 2>&1 || return 0
  timeout 2 virsh list --all --name 2>/dev/null | sed '/^$/d' || true
}

vms() {
  ui_intro "virtual machines on this host"
  vm_adopt_legacy
  local dirs=() d n pid state disk sz count=0 ours=" "
  mapfile -t dirs < <(vm_known_dirs)
  if ((${#dirs[@]})); then
    note "created by this script - '$0 destroy' can remove these:"
    for d in "${dirs[@]}"; do
      n=$(vm_name_of "$d"); pid=$(vm_pid_in "$d")
      state=stopped; [[ -n "$pid" ]] && { state="running"; ours+="$pid "; }
      disk="$d/$DISK"; sz="no disk"
      [[ -f "$disk" ]] && sz=$(du -h "$disk" 2>/dev/null | cut -f1)
      count=$((count + 1))
      printf '%s  %s %-14s %-9s %-6s %s\n' "$GUT" "${C_GREEN}●${C_RST}" "$n" \
        "$state" "$sz" "${C_DIM}${d/#$HOME/\~}${C_RST}"
    done
  else
    note "created by this script: none"
  fi

  # A VM booted before -name was passed is identified by its pidfile above, so
  # its process is dropped here rather than counted a second time as a stranger.
  local foreign=() lv=() raw=() line p
  mapfile -t raw < <(vm_foreign)
  for line in "${raw[@]-}"; do
    [[ -n "$line" ]] || continue
    p=${line%% *}
    [[ "$ours" == *" $p "* ]] && continue
    foreign+=("$line")
  done
  mapfile -t lv < <(vm_libvirt)
  if ((${#foreign[@]})) || ((${#lv[@]})); then
    printf '%s\n' "$GUT"
    note "other VMs on this host - never touched by this script:"
    for d in "${foreign[@]}"; do
      [[ -n "$d" ]] || continue
      printf '%s  %s %s\n' "$GUT" "${C_GRAY}○${C_RST}" "${C_DIM}qemu pid ${d%% *}${C_RST}"
    done
    for d in "${lv[@]}"; do
      [[ -n "$d" ]] || continue
      printf '%s  %s %s\n' "$GUT" "${C_GRAY}○${C_RST}" "${C_DIM}libvirt domain '$d'${C_RST}"
    done
  fi
  ui_outro "$count from here, $(( ${#foreign[@]} + ${#lv[@]} )) belonging to something else"
}

# =============================================================================
# removal
# =============================================================================
# Refuses any directory without the marker, and refuses $HOME and / whatever a
# marker claims, since the deep option deletes the directory outright.
vm_removable() {
  local d=$1
  [[ -f "$d/$MARKER" ]] || { warn "$d holds no VM from this script - skipped"; return 1; }
  case "$d" in
    "$HOME"|/|"") warn "refusing to remove $d"; return 1;;
  esac
  return 0
}

vm_remove() {  # $1 work dir, $2 "vm" or "all"
  local d=$1 scope=$2 n pid
  vm_removable "$d" || return 0
  n=$(vm_name_of "$d"); pid=$(vm_pid_in "$d")
  if [[ -n "$pid" ]]; then
    say "stopping $n (pid $pid)"
    kill "$pid" 2>/dev/null || true
    local i; for i in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && { kill -9 "$pid" 2>/dev/null || true; sleep 1; }
  fi
  if [[ "$scope" == all ]]; then
    rm -rf "$d"
    say "removed $n and everything in ${d/#$HOME/\~}"
  else
    rm -f "$d/$DISK" "$d/seed.iso" "$d/known_hosts" "$d/qemu.pid" "$d/$MARKER"
    say "removed $n; downloads and zips kept in ${d/#$HOME/\~}"
  fi
  if [[ -f "$REGISTRY" ]]; then
    grep -vxF "$d" "$REGISTRY" > "$REGISTRY.tmp" 2>/dev/null || true
    mv -f "$REGISTRY.tmp" "$REGISTRY" 2>/dev/null || true
  fi
}

# Speaks up only when a new VM is about to be built while older ones from this
# script are still around, so the usual re-run in an existing work dir stays
# silent. Old test machines otherwise sit there holding disk and memory.
check_existing_vms() {
  vm_adopt_legacy
  [[ -f "$WORKDIR/$MARKER" ]] && return 0     # reusing this work dir's own VM
  local dirs=() others=() d n
  mapfile -t dirs < <(vm_known_dirs)
  for d in "${dirs[@]-}"; do
    [[ -n "$d" && "$d" != "$WORKDIR" ]] && others+=("$d")
  done
  ((${#others[@]})) || return 0

  warn "a new VM is about to be built in $WD, and this script has ${#others[@]} already:"
  for d in "${others[@]}"; do
    n=$(vm_name_of "$d")
    note "  $n  ${d/#$HOME/\~}$([[ -n "$(vm_pid_in "$d")" ]] && printf '  (running)')"
  done
  ui_select "How do you want to go on?" 0 \
    "Build the new one in $WD and leave those alone" \
    "Remove one of them first" \
    "Stop here, change nothing"
  case "$ANSWER" in
    1) destroy;;
    2) die "nothing changed. '$0 vms' lists them, '$0 destroy' removes one";;
  esac
}

destroy() {
  local dirs=() d n pid labels=() i
  vm_adopt_legacy
  mapfile -t dirs < <(vm_known_dirs)
  if ((${#dirs[@]} == 0)); then
    ui_intro "destroy"
    note "no VM created by this script was found"
    ui_outro "nothing to remove"
    return 0
  fi

  ui_intro "destroy a VM"
  for d in "${dirs[@]}"; do
    n=$(vm_name_of "$d"); pid=$(vm_pid_in "$d")
    labels+=("$n  ${pid:+(running)}${pid:-(stopped)}  ${d/#$HOME/\~}")
  done
  labels+=("Cancel, change nothing")
  ui_select "Which VM?" 0 "${labels[@]}"
  i=$ANSWER
  (( i < ${#dirs[@]} )) || { ui_outro "cancelled"; return 0; }
  d="${dirs[$i]}"

  ui_warn "this is FULLY DESTRUCTIVE: the VM is powered off and its disk deleted."
  ui_warn "Everything inside it - the server, its database, characters - is gone,"
  ui_warn "and none of it can be recovered."
  ui_select "How much of ${d/#$HOME/\~} goes?" 1 \
    "The VM only - keep the Debian image and the zips, so a rebuild is quick" \
    "Cancel, change nothing" \
    "Everything, the whole directory including the downloaded image and your zips"
  case "$ANSWER" in
    0) vm_remove "$d" vm;;
    2) vm_remove "$d" all;;
    *) ui_outro "cancelled"; return 0;;
  esac
  ui_outro "'$0' builds a fresh one whenever you want"
}

usage() {
  ui_banner "apne's vm deployer" "for TurtleWoW on Linux"
  cat <<EOF

${C_BOLD}Usage:${C_RST}  $0 [mode]

${C_BOLD}Modes:${C_RST}
  ${C_GREEN}(none)${C_RST}     do everything: host deps, VM, provisioning, payload,
             conversion (live progress), GM account, world console
  ${C_GREEN}console${C_RST}    reattach this terminal to the world console
  ${C_GREEN}tune${C_RST}       run the kit's interactive config inside the VM
  ${C_GREEN}ssh${C_RST}        plain shell inside the VM
  ${C_GREEN}status${C_RST}     what is running
  ${C_GREEN}vms${C_RST}        every VM this script built, running or not, and a note
             of the VMs on this host that belong to something else
  ${C_GREEN}destroy${C_RST}    pick one of this script's VMs and remove it
             ${C_DIM}Fully destructive: the disk goes and the server, database
             and characters inside it go with it. Only VMs built here
             are ever offered.${C_RST}
  ${C_GREEN}help${C_RST}       this

Bring ${C_BOLD}TurtleWoW_1.18.zip${C_RST} and ${C_BOLD}data.zip${C_RST}; everything else is automatic.
Work dir: ${C_DIM}$WD${C_RST} (override with TWOW_VM_DIR=...)

EOF
}

# =============================================================================
main() {
  case "${1:-}" in
    help|-h|--help) usage; exit 0;;
    status)  status; exit 0;;
    vms)     ui_banner "apne's vm deployer" "for TurtleWoW on Linux"; vms; exit 0;;
    destroy) ui_banner "apne's vm deployer" "for TurtleWoW on Linux"; destroy; exit 0;;
    ssh)     exec ssh -t "${SSHOPTS[@]}" turtle@127.0.0.1;;
    console) exec ssh -t "${SSHOPTS[@]}" turtle@127.0.0.1 'cd twow && ./setup-native.sh run 1';;
    tune)    exec ssh -t "${SSHOPTS[@]}" turtle@127.0.0.1 'cd twow && ./setup-native.sh interactive';;
    "") ;;
    *) usage; die "unknown mode: $1";;
  esac

  # interactive installer: refuse to guess answers without a human attached
  [[ -t 0 && -t 1 ]] || die "run me in a terminal - I ask before touching your system"

  mkdir -p "$WORKDIR/logs"
  ui_banner "apne's vm deployer" "for TurtleWoW on Linux"
  ui_intro "zero to world console"
  check_existing_vms
  host_deps
  kvm_check
  resource_check
  find_payload
  fetch_image
  make_seed
  make_disk
  boot_vm
  provision
  push_payload
  convert
  open_forwards
  make_account
  handoff
}

# run only when executed, not when sourced (keeps functions testable)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
