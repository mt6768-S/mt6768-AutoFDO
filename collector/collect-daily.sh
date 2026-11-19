#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

if "$ADB_AVAILABLE"; then
	for i in $(seq 1 96); do
		adb_shell "su -c 'mkdir -p $REMOTE_ROOT/daily; FILE=$REMOTE_ROOT/daily/daily-\$(date +%Y%m%d-%H%M%S).data; simpleperf record -e $PERF_EVENT -a -f ${PERF_INTERVAL:-49} --duration 900 -o \"\$FILE\"'"
		adb_pull_dir "$REMOTE_ROOT/daily"
	done
else
	echo "No adb device found. Run collector/device/daily.sh in Termux."
fi
