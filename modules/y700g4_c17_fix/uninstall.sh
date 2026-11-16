#!/system/bin/sh
MODDIR=${0%/*}
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
# 刷新率与后台循环：停守护，交还系统
[ -f "$MODDIR/daemon.pid" ] && kill -TERM -"$(cat "$MODDIR/daemon.pid")" 2>/dev/null
if [ -f "$MODDIR/bg.pids" ]; then
  for bp in $(cat "$MODDIR/bg.pids" 2>/dev/null); do
    [ -n "$bp" ] || continue
    for cp in $(ps -A -o PID=,PPID= | awk -v p="$bp" '$2==p {print $1}'); do kill -TERM "$cp" 2>/dev/null; done
    kill -TERM "$bp" 2>/dev/null
  done
  rm -f "$MODDIR/bg.pids"
fi
service call SurfaceFlinger 1035 i32 -1 >/dev/null 2>&1
# 桌面与音量条适配：关掉覆盖
for o in y700_port y700_land y700_lau y700_vol y700_volport y700_ind_land y700_ind_port y700_gridup y700_lau_land; do
  cmd overlay disable com.android.shell:$o >/dev/null 2>&1
done
# IPv6：恢复
for f in /proc/sys/net/ipv6/conf/wlan*/disable_ipv6; do echo 0 > "$f"; done
# 音量条、Scene 锁：恢复
resetprop --delete persist.oplus.software.audio.right_volume_key 2>/dev/null
/system/bin/chattr -i /data/data/com.omarea.vtools/files/features/refresh_rate.conf 2>/dev/null
