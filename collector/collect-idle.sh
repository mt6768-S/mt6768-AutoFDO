#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
DURATION="${DURATION_SECONDS:-1800}"
collect_profile idle "$DURATION"
