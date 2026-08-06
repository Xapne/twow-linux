#!/usr/bin/env bash
# Replaces "Import_World_DB.bat": drops and re-imports the turtle_world DB
# from turtle_world.sql. MySQL must be running first (./1-start-mysql.sh).
# WARNING: turtle_world.sql is a snapshot; the compiled server may expect a
# newer schema. Always run ./apply-db-updates.sh after this import.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# db.env carries the port setup-native.sh settled on, which is not 3306 when a
# system MariaDB already holds that one.
# shellcheck source=/dev/null
[ -f ./db.env ] && . ./db.env
TWOW_DB_HOST=${TWOW_DB_HOST:-127.0.0.1}
TWOW_DB_PORT=${TWOW_DB_PORT:-3306}
TWOW_DB_USER=${TWOW_DB_USER:-root}
TWOW_DB_PASS=${TWOW_DB_PASS:-mangos}

MYSQL=(mariadb -h "$TWOW_DB_HOST" -P "$TWOW_DB_PORT" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" --max-allowed-packet=128M)

echo "Dropping and recreating turtle_world..."
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS turtle_world; CREATE DATABASE turtle_world CHARACTER SET utf8mb4;"

echo "Importing turtle_world.sql (182 MB, this takes a while)..."
"${MYSQL[@]}" turtle_world < turtle_world.sql

echo "Import done."
