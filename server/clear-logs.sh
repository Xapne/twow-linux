#!/usr/bin/env bash
# Replaces "Clear logs.bat": deletes everything under logs/, recursively.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
find logs -mindepth 1 -delete
echo "logs/ cleared."
