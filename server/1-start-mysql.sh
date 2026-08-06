#!/usr/bin/env bash
# Replaces "1.Start mysql.bat": runs native MariaDB with the project-local
# data directory (server/db), config in server/my.cnf.
# Ready when the log says "ready for connections".
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# The daemon lives in /usr/bin on Arch, /usr/sbin on Debian and /usr/libexec on
# Fedora, and sbin is usually missing from a normal user's PATH. Look around
# instead of hardcoding one of them.
for d in "$(command -v mariadbd || true)" "$(command -v mysqld || true)" \
         /usr/sbin/mariadbd /usr/libexec/mariadbd /usr/local/sbin/mariadbd \
         /usr/sbin/mysqld /usr/libexec/mysqld /usr/local/sbin/mysqld; do
  [ -x "$d" ] && exec "$d" --defaults-file="$PWD/my.cnf"
done

echo "no mariadbd/mysqld found; install your distro's MariaDB server package" >&2
exit 1
