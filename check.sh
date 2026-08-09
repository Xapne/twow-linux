#!/usr/bin/env bash
# =============================================================================
# The kit's check gate: shell syntax, shellcheck, and the tests in tests/.
# .github/workflows/check.yml runs this same script, so a green run here is a
# green run there.
#
# Usage: ./check.sh
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

# The logging is written out here rather than sourced from lib/: a broken
# lib/kit.sh is one of the things this gate exists to report.
ok()   { printf '  \033[1;32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; RC=1; }
skip() { printf '  \033[1;33mskip\033[0m  %s\n' "$*"; }
stage(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
RC=0

# Every shell script in the kit, found rather than listed, so one added
# tomorrow is covered without an edit here.
mapfile -t SCRIPTS < <(find . -name '*.sh' -not -path './.git/*' | sort)
(( ${#SCRIPTS[@]} )) || { printf 'no shell scripts found under %s\n' "$ROOT" >&2; exit 1; }

stage "syntax (${#SCRIPTS[@]} scripts)"
for s in "${SCRIPTS[@]}"; do
  if out=$(bash -n "$s" 2>&1); then ok "${s#./}"; else bad "${s#./}"; printf '%s\n' "$out"; fi
done

stage "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # -x follows sourced files, and SCRIPTDIR resolves each 'source=' directive
  # against the script holding it.
  if out=$(shellcheck -x -P SCRIPTDIR "${SCRIPTS[@]}" 2>&1); then
    ok "$(shellcheck --version | sed -n 's/^version: /shellcheck /p'), no findings"
  else
    bad "shellcheck findings"
    printf '%s\n' "$out"
  fi
else
  skip "shellcheck is absent; it ships as 'shellcheck' in every major distro"
fi

stage "tests"
mapfile -t TESTS < <(find tests -name '*.sh' -not -name '_*' 2>/dev/null | sort)
if (( ${#TESTS[@]} )); then
  for t in "${TESTS[@]}"; do
    if out=$(bash "$t" 2>&1); then ok "${t#./}"; else bad "${t#./}"; printf '%s\n' "$out"; fi
  done
else
  skip "no tests in tests/"
fi

printf '\n'
if (( RC )); then printf '\033[1;31mcheck failed\033[0m\n'; else printf '\033[1;32mcheck passed\033[0m\n'; fi
exit $RC
