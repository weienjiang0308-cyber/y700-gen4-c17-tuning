#!/system/bin/sh
# 把当前「自动连隧道」开关状态写进模块描述，KernelSU 管理器里一眼就能看到
MODDIR=${0%/*}
. "$MODDIR/config.conf"
if [ "$WG_AUTOCONNECT" = "1" ]; then S="开机自动连隧道 $WG_TUNNEL：✅ 开"; else S="开机自动连隧道：❌ 关"; fi
sed -i "s|^description=.*|description=【$S｜点「操作」按钮切换】Scene、WireGuard 已挂成系统应用（/system/app）并加入 ColorOS 自启动白名单。禁用或卸载后重启即恢复。|" "$MODDIR/module.prop"
