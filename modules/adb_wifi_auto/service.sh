#!/system/bin/sh
[ -z "$KSH_VERSION" ] && [ -x /system/bin/sh ] && exec /system/bin/sh "$0" "$@"
# 无线调试安全自启守护 v1.3（事件驱动零开销版）：
# 平时挂在 /system/bin/ip monitor link address 内核事件上完全睡眠（0% CPU），只在 wlan 网络变化瞬间醒来检查；
# 辅以 180 秒一次的超长低频兜底，将原 20 秒轮询的常驻 CPU 开销砍掉 90% 以上，同时响应速度提升至秒级。
MODDIR=${0%/*}
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
IP=/system/bin/ip
LOG="$MODDIR/adbwifi.log"
HOME_SSIDS=""
AUTO_CLOSE_OUTSIDE=1
INTERVAL=180
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
  [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 200 ] && tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

echo $$ > "$MODDIR/daemon.pid"
echo $$ > /dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ > /dev/cpuctl/background/cgroup.procs 2>/dev/null
renice -n 19 -p $$ >/dev/null 2>&1
trap 'trap - TERM INT HUP; rm -f "$MODDIR/daemon.pid"; kill -9 0' TERM INT HUP

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 3; done
sleep 5
case "$HOME_SSIDS" in
  ""|*YOUR_HOME_WIFI*)
    log "未配置自家 Wi-Fi 名单（仍是默认占位符），请在 config.conf 填写 HOME_SSIDS 后重启生效"
    exit 0 ;;
esac
if [ "$HOME_SSIDS" = "*" ]; then
  log "启动 v1.3（事件驱动）：允许所有保存过的 Wi-Fi（兜底 ${INTERVAL}s）"
else
  log "启动 v1.3（事件驱动，仅家里 Wi-Fi，出门自动关=${AUTO_CLOSE_OUTSIDE}）：$(echo "$HOME_SSIDS" | tr '\n' '|' | sed 's/|$//')（兜底 ${INTERVAL}s）"
fi

CR=$(printf '\r')
SSID=""
get_ssid() {
  SSID=$(cmd wifi status 2>/dev/null | sed -n 's/^Wifi is connected to "\(.*\)"$/\1/p' | head -n 1)
}
is_home_ssid() {
  [ -n "$1" ] || return 1
  [ "$HOME_SSIDS" = "*" ] && return 0
  OLD_IFS=$IFS; IFS='
'
  for h in $HOME_SSIDS; do
    h=${h%$CR}
    if [ -n "$h" ] && [ "$1" = "$h" ]; then IFS=$OLD_IFS; return 0; fi
  done
  IFS=$OLD_IFS
  return 1
}

check_once() {
  [ -f "$MODDIR/disable" ] && { rm -f "$MODDIR/daemon.pid"; log "模块已禁用，退出"; kill -TERM 0; exit 0; }
  cur=$(settings get global adb_wifi_enabled 2>/dev/null)
  get_ssid
  if is_home_ssid "$SSID"; then
    if [ "$cur" != "1" ]; then
      settings put global adb_wifi_enabled 1
      log "在家（Wi-Fi：$SSID）-> 已自动打开无线调试"
    fi
  elif [ "$AUTO_CLOSE_OUTSIDE" = "1" ] && [ "$cur" = "1" ]; then
    if [ -n "$SSID" ]; then
      settings put global adb_wifi_enabled 0
      log "连上外部 Wi-Fi（$SSID）-> 已立即关闭无线调试保安全"
    else
      # 可能是家里全屋漫游切换节点瞬断，等 5 秒再确认一次
      sleep 5
      get_ssid
      if ! is_home_ssid "$SSID"; then
        settings put global adb_wifi_enabled 0
        log "已离开家里 Wi-Fi（当前：${SSID:-未连接}）-> 已自动关闭无线调试"
      fi
    fi
  fi
}

check_once

# 超长周期低频兜底（防在家时手动误关或安卓偶发静默关闭）
( while [ ! -f "$MODDIR/disable" ]; do
    sleep "$INTERVAL"
    check_once
  done ) &

# 主通道：内核网络事件实时驱动（平时 0 唤醒、0 CPU；wlan 发生连接/断开/地址变更时合并 2s 防抖后执行一次）
LAST_TS=0
while [ ! -f "$MODDIR/disable" ]; do
  $IP monitor link address 2>/dev/null | while read -r line; do
    [ -f "$MODDIR/disable" ] && break
    case "$line" in
      *wlan*)
        read -r now _ < /proc/uptime; now=${now%.*}
        if [ $((now - LAST_TS)) -ge 2 ]; then
          sleep 1
          read -r now _ < /proc/uptime; LAST_TS=${now%.*}
          check_once
        fi ;;
    esac
  done
  [ -f "$MODDIR/disable" ] && break
  sleep 10
done
rm -f "$MODDIR/daemon.pid"
