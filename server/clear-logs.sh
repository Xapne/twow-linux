#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Replaces "Clear logs.bat": deletes everything under logs/, recursively.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
find logs -mindepth 1 -delete
echo "logs/ cleared."
