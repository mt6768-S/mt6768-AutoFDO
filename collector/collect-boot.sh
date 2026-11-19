#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

ACTION="${1:-enable}"
if "$ADB_AVAILABLE"; then
	case "$ACTION" in
		enable) adb_shell "su -c '/system/bin/simpleperf boot-record --enable \"-a -e $PERF_EVENT -f ${PERF_INTERVAL:-99} --duration 300 --exclude-perf\"'"; echo "Boot profiling scheduled for the next boot." ;;
		disable) adb_shell "su -c '/system/bin/simpleperf boot-record --disable'"; adb_pull_dir /data/simpleperf_boot_data ;;
		*) echo "Usage: collect-boot.sh [enable|disable]"; exit 1 ;;
	esac
else
	echo "No adb device found. Run collector/device/boot.sh enable|disable in Termux."
fi
