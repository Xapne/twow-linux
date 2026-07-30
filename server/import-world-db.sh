#!/usr/bin/env bash
# Replaces "Import_World_DB.bat": drops and re-imports the turtle_world DB
# from turtle_world.sql. MySQL must be running first (./1-start-mysql.sh).
# WARNING: turtle_world.sql is a snapshot; the compiled server may expect a
# newer schema. Always run ./apply-db-updates.sh after this import.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=root
DB_PASS=mangos

MYSQL=(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --max-allowed-packet=128M)

echo "Dropping and recreating turtle_world..."
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS turtle_world; CREATE DATABASE turtle_world CHARACTER SET utf8mb4;"

echo "Importing turtle_world.sql (182 MB, this takes a while)..."
"${MYSQL[@]}" turtle_world < turtle_world.sql

echo "Import done."
