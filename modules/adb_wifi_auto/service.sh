#!/system/bin/sh
# 无线调试安全自启守护 v1.2：
# 1) 连着 HOME_SSIDS 里的家里 Wi-Fi 且无线调试关着 -> 自动打开
# 2) 连上名单外的任何外部 Wi-Fi -> 立即强制关闭无线调试
# 3) 断开 Wi-Fi（等 5 秒防全屋漫游切换瞬断）仍未连回自家 Wi-Fi -> 自动关闭无线调试
MODDIR=${0%/*}
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
LOG="$MODDIR/adbwifi.log"
HOME_SSIDS=""
AUTO_CLOSE_OUTSIDE=1
INTERVAL=20
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
  [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 200 ] && tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

echo $$ > "$MODDIR/daemon.pid"
echo $$ > /dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ > /dev/cpuctl/background/cgroup.procs 2>/dev/null
renice -n 19 -p $$ >/dev/null 2>&1

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 3; done
sleep 5
case "$HOME_SSIDS" in
  ""|*YOUR_HOME_WIFI*)
    log "未配置自家 Wi-Fi 名单（仍是默认占位符），请在 config.conf 填写 HOME_SSIDS 后重启生效"
    exit 0 ;;
esac
if [ "$HOME_SSIDS" = "*" ]; then
  log "启动 v1.2：允许所有保存过的 Wi-Fi，每 ${INTERVAL}s 检查"
else
  log "启动 v1.2（仅家里 Wi-Fi，出门自动关=${AUTO_CLOSE_OUTSIDE}）：$(echo "$HOME_SSIDS" | tr '\n' '|' | sed 's/|$//')（每 ${INTERVAL}s 检查）"
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

while true; do
  [ -f "$MODDIR/disable" ] && { rm -f "$MODDIR/daemon.pid"; log "模块已禁用，退出"; exit 0; }
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
      log "连上外部 Wi-Fi（$SSID）-> 已强制关闭无线调试保安全"
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
  sleep "$INTERVAL"
done
