#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
PACKAGE="${1:?Usage: collect-game.sh PACKAGE [SECONDS]}"
DURATION="${2:-300}"
WAIT_TIMEOUT="${WAIT_TIMEOUT_SECONDS:-600}"

if "$ADB_AVAILABLE"; then
	adb_shell "su -c 'mkdir -p $REMOTE_ROOT/game; i=0; while ! pidof $PACKAGE >/dev/null 2>&1; do [ \"\$i\" -lt $WAIT_TIMEOUT ] || exit 124; sleep 2; i=\$((i+2)); done; sleep 10; FILE=$REMOTE_ROOT/game/game-\$(date +%Y%m%d-%H%M%S).data; simpleperf record -e $PERF_EVENT -a -f ${PERF_INTERVAL:-99} --duration $DURATION -o \"\$FILE\"'"
	adb_pull_dir "$REMOTE_ROOT/game"
else
	echo "No adb device found. Run collector/device/game.sh $PACKAGE $DURATION in Termux."
fi
