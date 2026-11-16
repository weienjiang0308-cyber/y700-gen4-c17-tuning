#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/daemon.pid" ] && kill -TERM -"$(cat "$MODDIR/daemon.pid")" "$(cat "$MODDIR/daemon.pid")" 2>/dev/null
rm -f "$MODDIR/daemon.pid"
