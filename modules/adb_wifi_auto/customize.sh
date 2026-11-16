SKIPUNZIP=0
ui_print "- 无线调试安全自启 v1.2（Wi-Fi 白名单 + 出门自动关闭版）"
OLD=/data/adb/modules/adb_wifi_auto
if [ -f "$OLD/config.conf" ] && ! grep -qE '^HOME_SSIDS="(\*|YOUR_HOME_WIFI)' "$OLD/config.conf"; then
  cp -f "$OLD/config.conf" "$MODPATH/config.conf"
  ui_print "- 已保留原来的自定义 Wi-Fi 名单 config.conf"
else
  ui_print "! 提示：请在安装后编辑 /data/adb/modules/adb_wifi_auto/config.conf"
  ui_print "  把 HOME_SSIDS 改成你自己的家里 Wi-Fi 名称（支持多行全屋漫游分支）"
fi
set_perm_recursive "$MODPATH" 0 0 0755 0644
