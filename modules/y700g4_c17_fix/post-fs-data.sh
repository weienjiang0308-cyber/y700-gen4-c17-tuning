#!/system/bin/sh
# 【刷新率】开机早期：关掉 ColorOS / 高通所有会自动改刷新率的机制，之后由 refresh_daemon.sh 全权控制。
# 全部只在内存里生效（bind mount 覆盖配置 + resetprop），不写系统分区；禁用或卸载模块后重启即恢复原厂。
#
# 1) /my_product/etc/oplus_vrr_config.json（ColorOS 刷新率服务配置）
#    touch_idle / hw_enable / sw_enable -> false   触摸空闲降帧（画面变化时会压到 60）
#    refreshrate_director -> false                 刷新率总调度（其中 OVFR 放视频时锁 60）
#    cvt / frtc -> false                           按内容/视频帧率自动调刷新率
#    feature_hybrid_acc -> false, feature_osync -> 0
# 2) /my_product/etc/refresh_rate_config.xml（按应用刷新率名单，2138 条）：清空 <item>，只留全局 <config>
# 3) 属性：ro.oplus.media.ovfr=false；高通 vendor.display 的三个动态帧率开关 = 0
MODDIR=${0%/*}
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
VRR=1; VOLUME_RIGHT=1; DENSITY=420
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
# 【音量条位置】底包按 Pad mini 写了「音量键在顶部」但没写哪一侧，音量条默认出现在左边。
# Y700 四代的音量键在右侧，这里告诉 SystemUI 在右边显示（要在 SystemUI 启动前设置）；若设为 0 则清除持久化属性恢复原厂左侧
if [ "$VOLUME_RIGHT" = 1 ]; then
  resetprop persist.oplus.software.audio.right_volume_key true
else
  resetprop --delete persist.oplus.software.audio.right_volume_key 2>/dev/null
fi
# 【屏幕密度】直接改出厂密度（和 C16 包的做法一样），系统和「设置」都把它当默认值，不会再被清回 440。
# 必须在 system_server 启动前改，所以放在 post-fs-data。
[ "${DENSITY:-0}" -gt 0 ] 2>/dev/null && resetprop ro.sf.lcd_density "$DENSITY"
# 刷新率功能关闭：什么都不覆盖，守护也不启动
if [ "$VRR" != 1 ]; then touch "$MODDIR/.no_override"; exit 0; fi
SRC=/my_product/etc/oplus_vrr_config.json
OUT=$MODDIR/oplus_vrr_config.json
LOG=$MODDIR/vrr.log
read -r UP _ < /proc/uptime
echo "$(date '+%m-%d %H:%M:%S') post-fs-data start（开机后 ${UP%.*} 秒）" > "$LOG"

[ -f "$SRC" ] || { echo "原厂配置不存在：$SRC，跳过（守护不会启动）" >> "$LOG"; touch "$MODDIR/.no_override"; exit 0; }
if ! grep -q '"touch_idle": true' "$SRC" || ! grep -q '"refreshrate_director": true' "$SRC"; then
  echo "原厂配置格式变了（找不到 touch_idle / refreshrate_director），为安全起见不覆盖，守护不会启动" >> "$LOG"
  touch "$MODDIR/.no_override"; exit 0
fi
rm -f "$MODDIR/.no_override"

sed -e 's/"touch_idle": true/"touch_idle": false/' \
    -e 's/"hw_enable": true/"hw_enable": false/' \
    -e 's/"sw_enable": true/"sw_enable": false/' \
    -e 's/"refreshrate_director": true/"refreshrate_director": false/' \
    -e 's/"cvt": true/"cvt": false/' \
    -e 's/"frtc": true/"frtc": false/' \
    -e 's/"mvt_enable": true/"mvt_enable": false/' \
    -e 's/"mvt": true/"mvt": false/' \
    -e 's/"limit_fps_when_app_exit": true/"limit_fps_when_app_exit": false/' \
    -e 's/"feature_hybrid_acc" *: *true/"feature_hybrid_acc": false/' \
    -e 's/"feature_osync": [0-9]*/"feature_osync": 0/' "$SRC" > "$OUT"
grep -q '"touch_idle": false' "$OUT" && grep -q '"refreshrate_director": false' "$OUT" \
  || { echo "生成失败，不覆盖" >> "$LOG"; rm -f "$OUT"; touch "$MODDIR/.no_override"; exit 0; }

CTX=$(ls -Z "$SRC" | awk '{print $1}')
chmod 644 "$OUT"; chown root:root "$OUT"; chcon "$CTX" "$OUT"
if mount --bind "$OUT" "$SRC"; then
  echo "已覆盖 vrr 配置：touch_idle/hw/sw/director/cvt/frtc/mvt/exit_limit/hybrid_acc 全关，osync=0" >> "$LOG"
else
  echo "bind mount 失败，守护不会启动" >> "$LOG"; touch "$MODDIR/.no_override"; exit 0
fi

RSRC=/my_product/etc/refresh_rate_config.xml
ROUT=$MODDIR/refresh_rate_config.xml
if [ -f "$RSRC" ] && grep -q '</refresh_rate_config>' "$RSRC"; then
  N=$(grep -c '<item ' "$RSRC")
  grep -v '^[[:space:]]*<item ' "$RSRC" | sed \
    -e 's/defaultRateId="[^"]*"/defaultRateId="7-7-7-7-7"/' \
    -e 's/enableAppSwitchBoost="true"/enableAppSwitchBoost="false"/' \
    -e 's/voiceSceneLowRate="true"/voiceSceneLowRate="false"/' > "$ROUT"
  chmod 644 "$ROUT"; chown root:root "$ROUT"; chcon "$(ls -Z "$RSRC" | awk '{print $1}')" "$ROUT"
  mount --bind "$ROUT" "$RSRC" && echo "已清空应用刷新率名单（原 $N 条）并锁定默认高刷" >> "$LOG"
fi

resetprop ro.oplus.media.ovfr false
# SurfaceFlinger 自带的「触摸计时器 + 按内容选刷新率」：抬手后它会按画面内容自己降到 60，和守护抢，关掉
resetprop ro.surface_flinger.set_touch_timer_ms 0
resetprop ro.surface_flinger.use_content_detection_for_refresh_rate false
resetprop vendor.display.enable_dpps_dynamic_fps 0
resetprop vendor.display.enable_optimal_refresh_rate 0
resetprop vendor.display.enable_idle_content_fps_hint 0
echo "已设置属性：touch_timer=$(getprop ro.surface_flinger.set_touch_timer_ms) content_detection=$(getprop ro.surface_flinger.use_content_detection_for_refresh_rate) ro.oplus.media.ovfr=$(getprop ro.oplus.media.ovfr) dpps/optimal/idle_hint=$(getprop vendor.display.enable_dpps_dynamic_fps)$(getprop vendor.display.enable_optimal_refresh_rate)$(getprop vendor.display.enable_idle_content_fps_hint)" >> "$LOG"
