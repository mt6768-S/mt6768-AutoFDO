#!/system/bin/sh
SP=/system/bin/simpleperf
OUT=/storage/emulated/0/profiles
[ "$(id -u)" = 0 ] || { echo 'Run as root!'; exit 1; }
mkdir -p "$OUT"
i=0
while [ "$i" -lt 96 ]; do
  "$SP" record -e cpu-cycles:k -a -f 49 --duration 900 -o "$OUT/daily-$(date +%Y%m%d-%H%M%S).data" || exit 1
  i=$((i+1))
done
