#!/system/bin/sh
SP=/system/bin/simpleperf
[ "$(id -u)" = 0 ] || { echo 'Run as root!'; exit 1; }
case "${1:-enable}" in
 enable) "$SP" boot-record --enable '-a -e cpu-cycles:k -f 99 --duration 300 --call-graph fp --exclude-perf' ;;
 disable) "$SP" boot-record --disable ;;
 *) echo 'Usage: boot.sh [enable|disable]'; exit 1 ;;
esac
