#!/usr/bin/env bash
set -Eeuo pipefail

PERF_EVENT="${PERF_EVENT:-cpu-cycles:k}"
PERF_INTERVAL="${PERF_INTERVAL:-99}"
DEVICE="${ADB_SERIAL:-}"
REMOTE_ROOT="${REMOTE_ROOT:-/data/local/tmp/mt6768-autofdo}"
LOCAL_DIR="${PROFILE_DIR:-profiles/devices/${PROFILE_DEVICE:-selene}}"

adb_args=()
[ -n "$DEVICE" ] && adb_args=(-s "$DEVICE")
ADB_AVAILABLE=false
if command -v "${ADB:-adb}" >/dev/null 2>&1 && "${ADB:-adb}" "${adb_args[@]}" get-state >/dev/null 2>&1; then
	ADB_AVAILABLE=true
fi

adb_shell() { "${ADB:-adb}" "${adb_args[@]}" shell "$@"; }
adb_pull_dir() { mkdir -p "$LOCAL_DIR"; "${ADB:-adb}" "${adb_args[@]}" pull "$1" "$LOCAL_DIR/"; }

record_remote() {
	local name="$1" duration="$2" frequency="${3:-$PERF_INTERVAL}"
	local remote="$REMOTE_ROOT/$name"
	adb_shell "mkdir -p '$remote'; FILE='$remote/$name-\$(date +%Y%m%d-%H%M%S).data'; simpleperf record -e '$PERF_EVENT' -a -f '$frequency' --duration '$duration' -o \"\$FILE\"; echo \"\$FILE\" > '$remote/latest'"
	adb_pull_dir "$remote"
}

record_local() {
	local name="$1" duration="$2" frequency="${3:-$PERF_INTERVAL}"
	local out="${DEVICE_PROFILE_DIR:-/storage/emulated/0/profiles}"
	mkdir -p "$out"
	simpleperf record -e "$PERF_EVENT" -a -f "$frequency" --duration "$duration" -o "$out/$name-$(date +%Y%m%d-%H%M%S).data"
}
