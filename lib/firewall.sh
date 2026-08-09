# shellcheck shell=bash
# Firewall help, shared by setup-native.sh and setup-vm.sh. Expects lib/ui.sh to
# be sourced already, for ui_select, and the including script's say/warn.
#
# Only ufw and firewalld are handled. Both can be asked what they are doing and
# both have exactly one supported way to open a port. A raw nftables or iptables
# ruleset is left alone on purpose: a guessed rule dropped into the middle of
# somebody's own chain is worse than no rule, and harder to find later.
#
# Neither can normally be queried without root, and asking for a password
# merely to look would be rude. So the running state is read where it is
# readable without privileges, and the port rules are allowed to be unknown.
# Opening a port is idempotent in both tools, so offering while unsure costs a
# duplicate rule at worst.

# Which firewall is actually running here. Empty when none is, or when it is
# one this cannot speak for.
fw_backend() {
  if command -v ufw >/dev/null 2>&1; then
    # ufw status needs root; its unit and its config file do not.
    if [[ "$(systemctl is-active ufw 2>/dev/null)" == active ]] \
       || grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
      printf 'ufw'; return 0
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    printf 'firewalld'; return 0
  fi
  return 0
}

# 0 open, 1 closed, 2 cannot tell without a password.
fw_port_state() {  # $1 backend, $2 port
  local out
  case "$1" in
    ufw)
      out=$(sudo -n ufw status 2>/dev/null) || return 2
      grep -qE "^$2(/tcp)?[[:space:]]+ALLOW" <<<"$out" && return 0
      return 1;;
    firewalld)
      firewall-cmd --query-port="$2/tcp" >/dev/null 2>&1 && return 0
      return 1;;
  esac
  return 2
}

fw_open_command() {  # $1 backend, $2.. ports
  local be=$1; shift
  local p out=""
  case "$be" in
    ufw)       for p in "$@"; do out+="sudo ufw allow $p/tcp; "; done;;
    firewalld) for p in "$@"; do out+="sudo firewall-cmd --permanent --add-port=$p/tcp; "; done
               out+="sudo firewall-cmd --reload";;
  esac
  printf '%s' "${out%; }"
}

# Offers to open the ports a realm needs, when a firewall is running and they
# are not already open. Says nothing at all when there is no firewall, or when
# everything is open, so the common case stays quiet.
fw_offer_ports() {  # $@ ports
  local be closed=() unsure=0 p rc cmd
  be=$(fw_backend)
  [[ -n "$be" ]] || return 0
  for p in "$@"; do
    # A closed port and an unreadable one are answers, not failures. Taking the
    # status from a bare call lets set -e end the run on both, which is every
    # case this function exists for.
    rc=0; fw_port_state "$be" "$p" || rc=$?
    (( rc == 0 )) && continue
    (( rc == 2 )) && unsure=1
    closed+=("$p")
  done
  ((${#closed[@]})) || return 0
  cmd=$(fw_open_command "$be" "${closed[@]}")
  if (( unsure )); then
    warn "$be is running here. Clients on the LAN need tcp ${closed[*]} open,
  and checking whether they already are needs a password, so this cannot say."
  else
    warn "$be is running here and tcp ${closed[*]} $( ((${#closed[@]}>1)) && echo are || echo is) closed;
  clients on the LAN cannot reach this realm until opened."
  fi
  ui_select "Open ${closed[*]} now?  ($cmd)" 0 \
    "Yes, run it (asks for your password)" "No, I will do it myself"
  if (( ANSWER != 0 )); then
    say "left alone; open them later with:  $cmd"
    return 0
  fi
  if eval "$cmd"; then
    say "opened tcp ${closed[*]}"
  else
    warn "that did not succeed; run it by hand:  $cmd"
  fi
  return 0
}
