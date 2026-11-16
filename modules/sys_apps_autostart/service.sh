#!/system/bin/sh
# 开机解锁、连上网络后自动连接 WireGuard 隧道
MODDIR=${0%/*}
. "$MODDIR/config.conf"
LOG="$MODDIR/autostart.log"
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
renice -n 19 -p $$ >/dev/null 2>&1
[ -f "$MODDIR/disable" ] && exit 0
sh "$MODDIR/desc.sh"
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
# ColorOS 开机后会重写自启动白名单，等它写完再补加一次
( sleep 60; W=/data/oplus/os/startup/autostart_white_list.txt
  [ -f "$W" ] && for e in $APPS; do p=${e%%:*}; grep -qx "$p" "$W" || { echo "$p" >> "$W"; log "开机后补加自启白名单：$p"; }; done ) &
[ "$WG_AUTOCONNECT" = "1" ] || exit 0
case "$WG_TUNNEL" in ""|YOUR_TUNNEL_NAME) log "未配置 WG_TUNNEL 隧道名，跳过自动连接"; exit 0 ;; esac
pm path com.wireguard.android >/dev/null 2>&1 || { log "没安装 WireGuard"; exit 0; }
# 等用户解锁（WireGuard 的配置在加密存储里，解锁前读不到）
until [ "$(getprop sys.user.0.ce_available)" = "true" ]; do sleep 5; done
# 打开 WireGuard 的「允许其他应用控制隧道」（只改这一项；WireGuard 没在运行时才改）
PB=/data/data/com.wireguard.android/files/datastore/settings.preferences_pb
KEY=616c6c6f775f72656d6f74655f636f6e74726f6c5f696e74656e7473
if [ -f "$PB" ] && ! pidof com.wireguard.android >/dev/null; then
  H=$(xxd -p "$PB" | tr -d '\n')
  case "$H" in *${KEY}12020800*)
    O=$(stat -c '%u:%g' "$PB")
    echo "$H" | sed "s/${KEY}12020800/${KEY}12020801/" | xxd -r -p > "$PB.tmp" && cat "$PB.tmp" > "$PB"; rm -f "$PB.tmp"
    chown "$O" "$PB"; log "已打开 WireGuard「允许其他应用控制隧道」" ;;
  esac
fi
# 等网络连上（支持双公网 IP 探测 + 禁 ICMP 网络默认路由连续就绪兜底）
i=0; rt=0
while [ $i -lt "$NET_WAIT" ]; do
  if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then break; fi
  if /system/bin/ip route show table all 2>/dev/null | grep -q '^default '; then
    rt=$((rt + 1))
    [ "$rt" -ge 3 ] && break
  else
    rt=0
  fi
  sleep 4; i=$((i + 5))
done
am broadcast -a com.wireguard.android.action.SET_TUNNEL_UP -e tunnel "$WG_TUNNEL" -n 'com.wireguard.android/.model.TunnelManager$IntentReceiver' >/dev/null 2>&1
sleep 5
if ip link show "$WG_TUNNEL" >/dev/null 2>&1 || ip -br link | grep -q 'wg\|tun'; then log "WireGuard 隧道 $WG_TUNNEL 已连接"; else log "已发送连接请求（隧道 $WG_TUNNEL），未检测到接口，可能还在建立"; fi
