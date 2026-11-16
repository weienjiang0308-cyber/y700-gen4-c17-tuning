SKIPUNZIP=0
OLD=/data/adb/modules/sys_apps_autostart
if [ -f "$OLD/config.conf" ]; then
  cp -f "$OLD/config.conf" "$MODPATH/config.conf"
  ui_print "- 已保留原来的 config.conf"
fi
. "$MODPATH/config.conf"
ui_print "- 应用系统化 + 开机自启 v1.1"
for e in $APPS; do
  pkg=${e%%:*}; name=${e#*:}
  paths=$(pm path "$pkg" 2>/dev/null | sed 's/^package://')
  if [ -z "$paths" ]; then ui_print "! 没安装 $pkg，跳过"; continue; fi
  d="$MODPATH/system/app/$name"; mkdir -p "$d"
  for p in $paths; do cp -f "$p" "$d/$(basename "$p")"; done
  ui_print "- $pkg -> /system/app/$name（$(ls "$d" | wc -l) 个 apk）"
done
# 本模块自己在 post-fs-data 里挂载 system/app，告诉 KernelSU/元模块不要再挂一次
touch "$MODPATH/skip_mount"
set_perm_recursive "$MODPATH" 0 0 0755 0644
[ -d "$MODPATH/system" ] && set_perm_recursive "$MODPATH/system" 0 0 0755 0644 u:object_r:system_file:s0
sh "$MODPATH/desc.sh"
ui_print "- 开机自动连 WireGuard 隧道：在 KernelSU 管理器里点本模块的「操作」按钮开/关"
ui_print "- 重启后生效"
