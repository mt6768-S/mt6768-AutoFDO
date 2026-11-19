#!/system/bin/sh
SP=/system/bin/simpleperf
PACKAGE="${1:?Usage: game.sh PACKAGE [SECONDS]}"
DURATION="${2:-300}"
OUT=/storage/emulated/0/profiles
[ "$(id -u)" = 0 ] || { echo 'Run as root!'; exit 1; }
mkdir -p "$OUT"
while ! pidof "$PACKAGE" >/dev/null 2>&1; do sleep 2; done
sleep 10
"$SP" record -e cpu-cycles:k -a -f 99 --duration "$DURATION" -o "$OUT/game-$(date +%Y%m%d-%H%M%S).data"
