SKIPUNZIP=0
ui_print "- 拯救者 Y700 四代 · C17 终极修复补丁 v2.4"
ui_print "  ① 刷新率  ② 桌面适配  ③ 音量条  ④ 新应用断网修复  ⑤ 网络优化  ⑥ 通用小核化"
ui_print "- 零外部依赖（无需 meta-overlayfs / LSPosed），开关：config.conf（改完重启生效）"

SDK=$(getprop ro.build.version.sdk)
[ "${SDK:-0}" -ge 37 ] 2>/dev/null || ui_print "! 提醒：当前不是安卓 17（SDK=$SDK），本模块按 ColorOS 17 写的，可能不完全适用"
[ -f /my_product/etc/oplus_vrr_config.json ] || ui_print "! 提醒：没找到 oplus_vrr_config.json，刷新率功能不会生效（其他五项功能不受影响）"

# 升级时保留用户改过的配置和游戏名单
OLD=/data/adb/modules/y700g4_c17_fix

# 第一次安装：问要不要把桌面设成 8×6（升级时不再问）
ui_print " "
ui_print "- 界面适配说明：桌面布局只针对 8×6 和 7×5 两种调过，其他布局不保证效果"
if [ ! -d "$OLD" ]; then
  ui_print "- 要把桌面设成 8×6 吗？（推荐，优化得最好）"
  ui_print "    音量加 = 设成 8×6      音量减 = 保持现在的布局"
  ui_print "    10 秒内不按，默认设成 8×6"
  key=""; end=$(( $(date +%s) + 10 ))
  while [ -z "$key" ] && [ "$(date +%s)" -lt "$end" ]; do
    ev=$(timeout 1 getevent -qlc 1 2>/dev/null)
    case "$ev" in
      *KEY_VOLUMEUP*DOWN*) key=up ;;
      *KEY_VOLUMEDOWN*DOWN*) key=down ;;
    esac
  done
  if [ "$key" = down ]; then
    ui_print "- 好的，保持现在的布局（以后可在桌面设置里自己切换）"
  else
    touch "$MODPATH/.set_grid_8x6"
    ui_print "- 好的，重启后桌面会设成 8×6（只设这一次，以后可自由切换）"
  fi
  ui_print " "
fi
[ -f "$OLD/.set_grid_8x6" ] && touch "$MODPATH/.set_grid_8x6"
if [ -f "$OLD/games.txt" ]; then cp -f "$OLD/games.txt" "$MODPATH/games.txt"; ui_print "- 已保留原来的 games.txt"; fi
# 配置：沿用旧文件里已有的值，新版本新增的配置项从新文件补进去
if [ -f "$OLD/config.conf" ]; then
  NEW="$MODPATH/config.conf"; cp -f "$OLD/config.conf" "$MODPATH/config.old"
  add=""; cmt=""
  while IFS= read -r l; do
    case "$l" in
      \#\ =====*) cmt="" ;;
      \#*) cmt="${cmt}${l}
" ;;
      [A-Z]*=*)
        k=${l%%=*}
        grep -qE "^[[:space:]]*$k=" "$MODPATH/config.old" || add="${add}${cmt}${l}
"
        cmt="" ;;
      *) cmt="" ;;
    esac
  done < "$NEW"
  cp -f "$MODPATH/config.old" "$NEW"; rm -f "$MODPATH/config.old"
  [ -n "$add" ] && printf '
# ===== 新版本新增的配置 =====
%s' "$add" >> "$NEW"
  ui_print "- 已保留原来的 config.conf（新增配置项连同说明已补到末尾）"
fi

# 旧的单独模块和本模块功能重复（两个刷新率守护会互相抢），装完重启时自动移除
for m in vrr_tune y700_launcher_fix y700_ipv6_fix net_tune_vps mod_littlecore; do
  if [ -d "/data/adb/modules/$m" ]; then
    touch "/data/adb/modules/$m/remove"
    ui_print "- 检测到旧模块 $m，已标记重启后移除（功能已合并进本模块）"
  fi
done

set_perm_recursive "$MODPATH" 0 0 0755 0644
