#!/system/bin/sh
# KernelSU 管理器里点模块的「操作」按钮：切换「开机自动连接 WireGuard 隧道」
MODDIR=${0%/*}
CONF="$MODDIR/config.conf"
. "$CONF"
if [ "$WG_AUTOCONNECT" = "1" ]; then NEW=0; else NEW=1; fi
sed -i "s/^WG_AUTOCONNECT=.*/WG_AUTOCONNECT=$NEW/" "$CONF"
sh "$MODDIR/desc.sh"
if [ "$NEW" = "1" ]; then
  echo "开机自动连接 WireGuard 隧道（$WG_TUNNEL）：已开启"
  echo "下次开机、解锁并联网后会自动连接。"
else
  echo "开机自动连接 WireGuard 隧道：已关闭"
  echo "下次开机不会自动连接（不影响你手动连接）。"
fi
