# shellcheck shell=bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
# Shared terminal UI: palette, gutter language and the clack-style prompts
# =============================================================================
# Sourced by twow.sh and twow-vm.sh, which both draw the same screens.
# Kept here because the two had a copy each and the copies had already drifted
# apart: only one of them survived a piped stdin, and only one restored the
# cursor after Ctrl+C.
#
# The log helpers (say/warn/die) deliberately stay in the two scripts: the
# "[setup]" prefixes twow.sh prints are parsed by twow-vm.sh to drive
# its progress bar, so the two are different on purpose.
#
# Every prompt writes its result to ANSWER; a caller reads it right after.

C_RST=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
# C_RED is read by twow-vm.sh, which sources this file.
# shellcheck disable=SC2034
C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m'
C_CYAN=$'\033[1;36m' C_GRAY=$'\033[90m'
GUT="${C_GRAY}│${C_RST}"

# $1 highlighted name, $2 the rest of the title; the box is sized to fit.
ui_banner() {
  local rule
  printf -v rule '─%.0s' $(seq 1 $(( ${#1} + ${#2} + 5 )))
  printf '\n%s\n' "${C_GRAY}╭${rule}╮${C_RST}"
  printf '%s\n'   "${C_GRAY}│${C_RST}  ${C_BOLD}${C_CYAN}$1${C_RST} ${C_BOLD}$2${C_RST}  ${C_GRAY}│${C_RST}"
  printf '%s\n'   "${C_GRAY}╰${rule}╯${C_RST}"
}

ui_intro() { printf '%s\n%s\n' "${C_GRAY}┌${C_RST}  ${C_BOLD}$1${C_RST}" "$GUT"; }
ui_outro() { printf '%s\n%s\n\n' "$GUT" "${C_GRAY}└${C_RST}  $1"; }
ui_note()  { printf '%s  %s\n' "$GUT" "${C_DIM}$1${C_RST}"; }
ui_warn()  { printf '%s  %s\n' "$GUT" "${C_YELLOW}$1${C_RST}"; }

# $1 label, $2 current value -> ANSWER; Enter keeps the current value. A
# non-tty stdin is read as one plain line, so the prompts can be scripted.
ui_text() {
  printf '%s\n' "$GUT"
  if [[ ! -t 0 ]]; then
    IFS= read -r ANSWER || ANSWER=""
    [[ -n "$ANSWER" ]] || ANSWER="$2"
  else
    printf '%s  %s\n' "${C_CYAN}◆${C_RST}" "$1"
    IFS= read -rep '│  ' -i "$2" ANSWER || ANSWER="$2"
    [[ -n "$ANSWER" ]] || ANSWER="$2"
    printf '\033[2A\r'
  fi
  printf '\033[2K%s  %s\n\033[2K%s  %s\n' \
    "${C_GREEN}◇${C_RST}" "$1" "$GUT" "${C_DIM}$ANSWER${C_RST}"
}

# Like ui_text, but asks again until the answer is a number.
ui_num() {
  while :; do
    ui_text "$1" "$2"
    [[ "$ANSWER" =~ ^[0-9]+([.][0-9]+)?$ ]] && return 0
    ui_warn "that is not a number, try again"
  done
}

# $1 label, $2 default index, $3.. options -> ANSWER = chosen index. Arrow keys
# or j/k move and wrap around; a non-tty stdin is read as the index itself.
ui_select() {
  local label="$1" idx="$2"; shift 2
  local opts=("$@") n=$# key rest i
  printf '%s\n' "$GUT"
  if [[ ! -t 0 ]]; then
    IFS= read -r key || key=""
    [[ "$key" =~ ^[0-9]+$ && "$key" -lt "$n" ]] && idx="$key"
  else
    printf '\033[?25l%s  %s\n' "${C_CYAN}◆${C_RST}" "$label"
    while :; do
      for i in "${!opts[@]}"; do
        if (( i == idx )); then
          printf '\033[2K%s  %s %s\n' "${C_CYAN}│${C_RST}" "${C_GREEN}●${C_RST}" "${opts[i]}"
        else
          printf '\033[2K%s  %s %s\n' "$GUT" "${C_GRAY}○${C_RST}" "${C_DIM}${opts[i]}${C_RST}"
        fi
      done
      IFS= read -rsn1 key || key=""
      if [[ "$key" == $'\x1b' ]]; then
        rest=""; IFS= read -rsn2 -t 0.05 rest || true; key+="$rest"
      fi
      case "$key" in
        $'\x1b[A'|k) idx=$(( (idx + n - 1) % n )) ;;
        $'\x1b[B'|j) idx=$(( (idx + 1) % n )) ;;
        $'\x03')     printf '\033[?25h\n'; exit 130 ;;
        '')          break ;;
      esac
      printf '\033[%dA' "$n"
    done
    printf '\033[%dA\r' $(( n + 1 ))
  fi
  ANSWER="$idx"
  printf '\033[2K%s  %s\n\033[2K%s  %s\n\033[0J\033[?25h' \
    "${C_GREEN}◇${C_RST}" "$label" "$GUT" "${C_DIM}${opts[idx]}${C_RST}"
}
