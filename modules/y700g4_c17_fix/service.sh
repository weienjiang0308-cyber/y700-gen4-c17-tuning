#!/system/bin/sh
# Y700 四代 ColorOS 17 综合修复 —— 开机后启动各项功能
# 注意：KernelSU 用自带 busybox 跑本脚本，busybox 的 ip 没有 monitor，所以 IPv6 部分固定用 /system/bin/ip
MODDIR=${0%/*}
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
VRR=1; LAUNCHER_FIX=1; PORT_IND_DOWN_DP=10; IPV6_FIX=1; SHOW_REFRESH=0; DENSITY=420; VOLUME_MARGIN_DP=4; VOLUME_UP_DP=148; LABEL_SP_LAND=10; LITTLECORE=1; NET_TUNE=1; CNSS_DIAG_OFF=1
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
IP=/system/bin/ip
ts() { date '+%m-%d %H:%M:%S'; }
stop_bg() {
  [ -f "$MODDIR/bg.pids" ] || return 0
  for bp in $(cat "$MODDIR/bg.pids" 2>/dev/null); do
    [ -n "$bp" ] && [ "$bp" != "$1" ] || continue
    for cp in $(ps -A -o PID=,PPID= | awk -v p="$bp" '$2==p {print $1}'); do kill -TERM "$cp" 2>/dev/null; done
    kill -TERM "$bp" 2>/dev/null
  done
  rm -f "$MODDIR/bg.pids"
}
stop_bg ""

# 封禁 Scene 的刷新率管理（防止 scene-daemon 通过 SurfaceFlinger 后门抢 60Hz，不影响 Scene 调度/充电等其他功能；仅开机执行，0 常驻开销）
ban_scene_vrr() {
  SD=/data/data/com.omarea.vtools/files/features
  SF=$SD/refresh_rate.conf
  [ -d "$SD" ] || return 0
  if [ "$VRR" = 1 ]; then
    /system/bin/chattr -i "$SF" 2>/dev/null
    if [ -f "$SF" ]; then
      if grep -q '^enable=1' "$SF" 2>/dev/null; then
        sed 's/^enable=1.*/enable=0/' "$SF" > "$MODDIR/.sc.tmp" && cat "$MODDIR/.sc.tmp" > "$SF"
        rm -f "$MODDIR/.sc.tmp"
        echo "$(ts) 已自动关闭并封禁 Scene 刷新率管理" >> "$MODDIR/vrr.log"
      fi
    else
      owner=$(stat -c '%u:%g' "$SD" 2>/dev/null)
      echo "enable=0" > "$SF"
      [ -n "$owner" ] && chown "$owner" "$SF" 2>/dev/null
      chmod 600 "$SF" 2>/dev/null
    fi
    /system/bin/chattr +i "$SF" 2>/dev/null
  else
    /system/bin/chattr -i "$SF" 2>/dev/null
  fi
}

# ---------- ① 刷新率守护（post-fs-data 覆盖成功才启动，否则会和 ColorOS 抢）----------
ban_scene_vrr
if [ "$VRR" = 1 ] && [ ! -f "$MODDIR/.no_override" ]; then
  [ -f "$MODDIR/daemon.pid" ] && kill -TERM -"$(cat "$MODDIR/daemon.pid")" 2>/dev/null
  setsid /system/bin/sh "$MODDIR/refresh_daemon.sh" >/dev/null 2>&1 &
fi

# ---------- 音量条（尽早做，赶在第一次按音量键之前）----------
# SystemUI 的音量条位置是尺寸值（dimen），系统命令改不了，用模块自带的 fab.dex（源码 Fab.java）直接调系统接口。
# 每个改值一次提交、一次生效，不会出现「改了一半」的样子。不等开机完成，overlay 服务一就绪就做。
#  ① 边距：volume_recyclerview_tablet_margin_to_parent 34dp -> VOLUME_MARGIN_DP（横竖屏都生效）
#  ② 竖屏上移 N dp 对齐实体音量键：布局里容器固定放在「从上往下 25%」处，比例改不了，所以
#     容器加高 4N（顶边上移 N）、底部内边距加 4N（音量条长度不变、贴在上方）、「…」按钮偏移上拉 4N，
#     喇叭图标钉在容器最底部、画在自己框的顶端：把它的框高改成 4N+25dp，图标正好回到音量条底部。
#     只在竖屏（port）生效，横屏不变。
#     原值：容器 224dp、底部内边距 8dp、按钮偏移 -44dp。
FAB() { CLASSPATH="$MODDIR/fab.dex" app_process /system/bin Fab --enable "$@" >/dev/null 2>&1; }
U=com.android.systemui
i=0; until service check overlay 2>/dev/null | grep -q ': found' || [ $i -ge 120 ]; do sleep 1; i=$((i+1)); done

# ---------- ② 桌面适配（纯 FAB 原子提交，开机赶在桌面启动前完成）----------
# 注意：桌面声明了转屏不重建 Activity，3 个尺寸项（cell_layout_padding_top / landscape_workspace_icon_text_size / CellLayout_icon_padding_top）
# 只在桌面进程启动时读一次；若限定 land，竖屏开机就会漏读，转横屏后第 6 行下沉压住 Dock，因此拆成无方向限定（-）的 y700_lau。
L=com.android.launcher
# 清理旧版本遗留的碎片覆盖，统一收敛为 y700_port、y700_land 和 y700_lau
for old_o in y700_ind_land y700_ind_port y700_gridup y700_lau_land y700_try y700_ind_port2; do
  cmd overlay disable com.android.shell:$old_o >/dev/null 2>&1
done
if [ "$LAUNCHER_FIX" = 1 ]; then
  # 竖屏原子提交：左右边距 12dp（对齐 Dock）+ 压小容器高度让页码点下移 PORT_IND_DOWN_DP
  if [ "${PORT_IND_DOWN_DP:-0}" -gt 0 ] 2>/dev/null; then
    IND_H=$((30 - PORT_IND_DOWN_DP * 2))
    [ "$IND_H" -lt 6 ] && IND_H=6
    IND_DIM=$(( (IND_H << 8) | 1 ))
    FAB y700_port $L port \
      $L:integer/oplusLayoutWorkspacePaddingHorBigScreenDp 16 12 \
      $L:integer/oplusLayoutIndicatorMarginBottomDp 16 1 \
      $L:dimen/workspace_page_indicator_height 5 "$IND_DIM" \
      $L:dimen/workspace_page_indicator_breeno_entry_height 5 "$IND_DIM"
  else
    FAB y700_port $L port \
      $L:integer/oplusLayoutWorkspacePaddingHorBigScreenDp 16 12
  fi
  # 横屏整数覆盖（转屏动态重读）：Dock 底边距 22dp + 页码点顶置 690dp
  FAB y700_land $L land \
    $L:integer/oplusLayoutHotseatMarginBottomGestureDp 16 22 \
    $L:integer/oplusLayoutIndicatorMarginBottomDp 16 690
  # 全方向尺寸覆盖（启动读一次，避免竖屏开机漏读）：网格上移 -9dp + 格内上边距 1dp + 横屏图标文字 10sp
  GRID_UP=$(( ((-9 & 0xFFFFFF) << 8) | 1 ))
  if [ "${LABEL_SP_LAND:-0}" -gt 0 ] 2>/dev/null; then
    FAB y700_lau $L - \
      $L:dimen/cell_layout_padding_top 5 "$GRID_UP" \
      $L:dimen/landscape_workspace_icon_text_size 5 $(( (LABEL_SP_LAND << 8) | 2 )) \
      $L:dimen/CellLayout_icon_padding_top 5 $(( (1 << 8) | 1 ))
  else
    FAB y700_lau $L - \
      $L:dimen/cell_layout_padding_top 5 "$GRID_UP" \
      $L:dimen/CellLayout_icon_padding_top 5 $(( (1 << 8) | 1 ))
  fi
else
  for o in y700_port y700_land y700_lau; do cmd overlay disable com.android.shell:$o >/dev/null 2>&1; done
fi
LAU_NOW=$(pidof $L)      # 在全部 FAB 提交完再查桌面是否已启动，避免执行期间拉起漏掉重启
[ "$LAUNCHER_FIX" = 1 ] && [ -n "$LAU_NOW" ] && am force-stop $L
LAULOG="$(ts) 桌面适配=$LAUNCHER_FIX（桌面$([ -n "$LAU_NOW" ] && echo 已先启动，已重启一次 || echo 还没启动，不用重启)）"

if [ "${VOLUME_MARGIN_DP:-0}" -gt 0 ] 2>/dev/null; then
  FAB y700_vol $U - $U:dimen/volume_recyclerview_tablet_margin_to_parent 5 $(( (VOLUME_MARGIN_DP << 8) | 1 ))
else
  cmd overlay disable com.android.shell:y700_vol >/dev/null 2>&1
fi
if [ "${VOLUME_UP_DP:-0}" -gt 0 ] 2>/dev/null; then
  D=$((VOLUME_UP_DP * 4))
  FAB y700_volport $U port     $U:dimen/volume_vertical_recyclerview_height 5 $(( ((224 + D) << 8) | 1 ))     $U:dimen/oplus_volume_elevation_padding_bottom 5 $(( ((8 + D) << 8) | 1 ))     $U:dimen/oplus_volume_dialog_button_margin_top 5 $(( ((-44 - D) << 8) | 1 ))     $U:dimen/volume_row_icon_height 5 $(( ((D + 25) << 8) | 1 ))
else
  cmd overlay disable com.android.shell:y700_volport >/dev/null 2>&1
fi
VOLLOG="$(ts) 音量条：边距=${VOLUME_MARGIN_DP}dp 竖屏上移=${VOLUME_UP_DP}dp（等 overlay 服务 ${i} 秒）"



until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
ban_scene_vrr
# 保底：开机完成后检查音量条改值还在不在，没有就再提交一次
OL=$(cmd overlay list $U 2>/dev/null)
if [ "${VOLUME_MARGIN_DP:-0}" -gt 0 ] 2>/dev/null && ! echo "$OL" | grep -q '\[x\] com.android.shell:y700_vol$'; then
  FAB y700_vol $U - $U:dimen/volume_recyclerview_tablet_margin_to_parent 5 $(( (VOLUME_MARGIN_DP << 8) | 1 )); VOLLOG="$VOLLOG 边距补提交"
fi
if [ "${VOLUME_UP_DP:-0}" -gt 0 ] 2>/dev/null && ! echo "$OL" | grep -q '\[x\] com.android.shell:y700_volport'; then
  D=$((VOLUME_UP_DP * 4))
  FAB y700_volport $U port $U:dimen/volume_vertical_recyclerview_height 5 $(( ((224 + D) << 8) | 1 )) $U:dimen/oplus_volume_elevation_padding_bottom 5 $(( ((8 + D) << 8) | 1 )) $U:dimen/oplus_volume_dialog_button_margin_top 5 $(( ((-44 - D) << 8) | 1 )) $U:dimen/volume_row_icon_height 5 $(( ((D + 25) << 8) | 1 ))
  VOLLOG="$VOLLOG 上移补提交"
fi
# 本脚本剩下的部分都放小核、低优先级（双 cgroup 组，后续衍生进程直接继承）
echo $$ > /dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ > /dev/cpuctl/background/cgroup.procs 2>/dev/null
renice -n 10 -p $$ >/dev/null 2>&1

# ---------- ⑥ 网络优化 + ③ 新应用断网修复（合并保底循环降开销）----------
# 上传：拥塞控制 cubic（支持时启用，C17 内核只有 reno/bbr）；下载：TCP 接收窗口 4MB/32MB；停高通 WiFi 诊断日志 vendor.cnss_diag。
# 全零 IPv6 前缀检测：部分路由器下发 ::/64 导致安卓 17 本地网络保护误杀 SDK 37 应用，检测到就关闭该 Wi-Fi 接口 IPv6。
if [ "$CNSS_DIAG_OFF" = 1 ] && [ "$(getprop init.svc.vendor.cnss_diag)" = running ]; then
  setprop ctl.stop vendor.cnss_diag; echo "$(ts) 已停掉 vendor.cnss_diag（WiFi 诊断日志）" >> "$MODDIR/net.log"
fi
RMEM=$(printf '4096\t4194304\t33554432'); RMEM_W="4096 4194304 33554432"
CC=cubic; CC_OK=0
if [ "$NET_TUNE" = 1 ]; then
  read AV < /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
  case " $AV " in *" $CC "*) CC_OK=1 ;; esac
fi
netcheck() {
  [ "$NET_TUNE" = 1 ] || return
  if [ "$CC_OK" = 1 ]; then
    read cur_cc < /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
    [ "$cur_cc" != "$CC" ] && echo "$CC" > /proc/sys/net/ipv4/tcp_congestion_control && echo "$(ts) 拥塞控制 $cur_cc -> $CC" >> "$MODDIR/net.log"
  fi
  cur=$(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)      # mksh 的 read 读这个文件只得到首字符，必须用 cat
  if [ "$cur" != "$RMEM" ]; then
    echo "$RMEM_W" > /proc/sys/net/ipv4/tcp_rmem && echo "$(ts) 接收窗口 -> $RMEM_W" >> "$MODDIR/net.log"
    [ -f "$MODDIR/net.log" ] && [ "$(wc -l < "$MODDIR/net.log")" -gt 200 ] && tail -n 100 "$MODDIR/net.log" > "$MODDIR/net.tmp" && mv "$MODDIR/net.tmp" "$MODDIR/net.log"
  fi
}
v6log() { echo "$(ts) $*" >> "$MODDIR/ipv6.log"; }
v6check() {
  for f in /proc/sys/net/ipv6/conf/wlan*/disable_ipv6; do
    [ -f "$f" ] || continue
    d=""; read -r d < "$f" 2>/dev/null
    [ "$d" = 0 ] || continue
    i=${f#/proc/sys/net/ipv6/conf/}; i=${i%/disable_ipv6}
    if $IP -6 addr show dev "$i" scope global 2>/dev/null | grep -qE 'inet6 ::[0-9a-f]+:'; then
      echo 1 > "$f"
      v6log "$i 收到全零 IPv6 前缀，已关闭该接口的 IPv6"
    fi
  done
}
[ "$NET_TUNE" = 1 ] && netcheck
if [ "$IPV6_FIX" = 1 ]; then
  [ -f "$MODDIR/ipv6.log" ] && [ "$(wc -l < "$MODDIR/ipv6.log")" -gt 200 ] && \
    tail -n 100 "$MODDIR/ipv6.log" > "$MODDIR/ipv6.log.tmp" && mv "$MODDIR/ipv6.log.tmp" "$MODDIR/ipv6.log"
  v6log "启动"
  v6check
fi
: > "$MODDIR/bg.pids"
if [ "$NET_TUNE" = 1 ] || [ "$IPV6_FIX" = 1 ]; then
  ( MYPID=$(sh -c 'echo $PPID')
    renice -n 19 -p "$MYPID" >/dev/null 2>&1
    while true; do
      sleep 30
      if [ -f "$MODDIR/disable" ]; then
        [ "$IPV6_FIX" = 1 ] && for f in /proc/sys/net/ipv6/conf/wlan*/disable_ipv6; do [ -f "$f" ] && echo 0 > "$f"; done
        stop_bg "$MYPID"
        exit 0
      fi
      netcheck
      [ "$IPV6_FIX" = 1 ] && v6check
    done ) &
  echo "$!" >> "$MODDIR/bg.pids"
fi
if [ "$IPV6_FIX" = 1 ]; then
  ( MYPID=$(sh -c 'echo $PPID')
    renice -n 19 -p "$MYPID" >/dev/null 2>&1
    while [ ! -f "$MODDIR/disable" ]; do
      $IP monitor address 2>/dev/null | while read -r l; do
        [ -f "$MODDIR/disable" ] && break
        case "$l" in *inet6*) v6check; netcheck ;; esac
      done
      [ -f "$MODDIR/disable" ] && exit 0
      sleep 5
    done ) &
  echo "$!" >> "$MODDIR/bg.pids"
fi

# ---------- ⑦ 模块进程小核化（通用全自动：读取系统后台小核范围，自动纳管所有已装与新刷模块）----------
# 通过 cmdline + exe + cwd 自动发现所有 /data/adb/ 下的模块进程及其全部子孙进程，
# 从 /dev/cpuset/background/cpus 读取当前芯片的小核范围（如 0-3 或 0-1），用 cpuset + taskset 连同多线程一起锁进小核，
# nice 调到 10（本身设了负值高优先级的如 uperf -20 只锁小核不改优先级）。
if [ "$LITTLECORE" = 1 ]; then
  ( CS=/dev/cpuset/background/cgroup.procs; CT=/dev/cpuset/background/tasks
    CC=/dev/cpuctl/background/cgroup.procs; CCT=/dev/cpuctl/background/tasks; LNICE=10
    [ -w "$CS" ] || exit 0
    MYPID=$(sh -c 'echo $PPID')
    renice -n 19 -p "$MYPID" >/dev/null 2>&1
    lc_scan() {
      # 每次扫描动态重读当前 /dev/cpuset/background/cpus（例如开机后 uperf 会将后台核从 0-5 收紧为 0-2），确保始终锁在最窄的小核范围
      BG_CPUS="0-3"
      [ -r /dev/cpuset/background/cpus ] && read -r BG_CPUS < /dev/cpuset/background/cpus 2>/dev/null
      [ -z "$BG_CPUS" ] && BG_CPUS="0-3"
      MASK_DEC=0; OLD_IFS=$IFS; IFS=,
      for seg in $BG_CPUS; do
        case "$seg" in
          *-*) a=${seg%-*}; b=${seg#*-}; c=$a; while [ "$c" -le "$b" ]; do MASK_DEC=$((MASK_DEC | (1 << c))); c=$((c + 1)); done ;;
          [0-9]*) MASK_DEC=$((MASK_DEC | (1 << seg))) ;;
        esac
      done
      IFS=$OLD_IFS
      [ "$MASK_DEC" -le 0 ] && MASK_DEC=15
      BG_MASK=$(printf '%x' "$MASK_DEC")
      ROOTS=""
      for f in $(grep -l '/data/adb/' /proc/[0-9]*/cmdline 2>/dev/null); do
        p=${f#/proc/}; p=${p%/cmdline}
        [ -r "$f" ] || continue
        case "$({ tr '\0' ' ' < "$f"; } 2>/dev/null)" in *ksud*|'') ;; *) ROOTS="$ROOTS $p" ;; esac
      done
      for p in $(ls -l /proc/[0-9]*/exe /proc/[0-9]*/cwd 2>/dev/null | awk '$NF ~ /^\/data\/adb\// && $NF !~ /ksud$/ && $(NF-2) ~ /^\/proc\/[0-9]+\/(exe|cwd)$/ {split($(NF-2),a,"/"); print a[3]}'); do
        ROOTS="$ROOTS $p"
      done
      [ -n "$ROOTS" ] || return
      ALL=$(ps -A -o PID=,PPID= | awk -v r="$ROOTS" 'BEGIN{n=split(r,a," "); for(i=1;i<=n;i++) if(a[i]!="") s[a[i]]=1}
            {pp[$1]=$2} END{ch=1; while(ch){ch=0; for(p in pp) if(!(p in s) && (pp[p] in s)){s[p]=1; ch=1}} for(p in s) print p}')
      n=0; m=0; tot=0
      for p in $ALL; do
        [ -d "/proc/$p" ] || continue
        tot=$((tot + 1))
        moved=0; niced=0
        cur=""; read -r cur < "/proc/$p/cpuset" 2>/dev/null
        [ "$cur" != "/background" ] && { echo "$p" > "$CS" 2>/dev/null && moved=1; [ -w "$CC" ] && echo "$p" > "$CC" 2>/dev/null; }
        for td in "/proc/$p/task/"[0-9]*; do
          [ -d "$td" ] || continue
          tid=${td##*/}
          tcs=""; read -r tcs < "$td/cpuset" 2>/dev/null
          tal=""
          while IFS=: read -r k v; do
            case "$k" in Cpus_allowed_list) tal=${v#"${v%%[! 	]*}"}; break ;; esac
          done < "$td/status" 2>/dev/null
          if [ "$tcs" != "/background" ] || [ "$tal" != "$BG_CPUS" ]; then
            echo "$tid" > "$CT" 2>/dev/null
            [ -w "$CCT" ] && echo "$tid" > "$CCT" 2>/dev/null
            /system/bin/taskset -p "$BG_MASK" "$tid" >/dev/null 2>&1
            moved=1
          fi
          tst=""; read -r tst < "$td/stat" 2>/dev/null || continue
          trest=${tst##*) }; set -- $trest; tni=${17:-0}
          if [ "$tni" -ge 0 ] && [ "$tni" -lt "$LNICE" ]; then renice -n "$LNICE" -p "$tid" >/dev/null 2>&1 && niced=1; fi
        done
        [ "$moved" = 1 ] && n=$((n + 1))
        [ "$niced" = 1 ] && m=$((m + 1))
      done
      { [ "$n" -gt 0 ] || [ "$m" -gt 0 ]; } && echo "$(ts) 小核($BG_CPUS) 挪入/锁核 $n 个、降优先级 $m 个（共 $tot 个模块进程）" >> "$MODDIR/littlecore.log"
      [ -f "$MODDIR/littlecore.log" ] && [ "$(wc -l < "$MODDIR/littlecore.log")" -gt 200 ] && tail -n 100 "$MODDIR/littlecore.log" > "$MODDIR/lc.tmp" && mv "$MODDIR/lc.tmp" "$MODDIR/littlecore.log"
    }
    sleep 15; [ -f "$MODDIR/disable" ] && exit 0; lc_scan
    sleep 45; [ -f "$MODDIR/disable" ] && exit 0; lc_scan
    while [ ! -f "$MODDIR/disable" ]; do sleep 600; [ -f "$MODDIR/disable" ] && exit 0; lc_scan; done ) &
  echo "$!" >> "$MODDIR/bg.pids"
fi

# ---------- 屏幕密度 ----------
# 出厂密度已在 post-fs-data 改成 $DENSITY；如果还留着以前用 wm density 设的强制密度，清掉它，避免两套设置打架
if [ "${DENSITY:-0}" -gt 0 ] 2>/dev/null; then
  f=$(settings get secure display_density_forced 2>/dev/null)
  case "$f" in ''|null) ;; *) wm density reset; echo "$(ts) 清掉旧的强制密度 $f，改用出厂密度 $(getprop ro.sf.lcd_density)" >> "$MODDIR/launcher.log" ;; esac
fi

# ---------- ② 桌面适配（用系统动态资源覆盖，不改分区）----------
#  竖屏：图标区左右边距 80 -> 12dp，与 Dock 对齐，页码点下移
#  横屏：Dock 底边距（手势导航）26 -> 22dp（配合网格上移，最后一行文字到 Dock、Dock 到手势条各约 30 像素）
#  横屏：页码点底边距 0(自动) -> 690dp（最顶上，和状态栏同一行），移到顶部、第一行上方（放在底部必然压住最后一行）
# 桌面的改值已在开机早期（桌面启动前）做好，这里只处理「第一次安装切 8×6」
L=com.android.launcher
if pm path $L >/dev/null 2>&1; then
  # 第一次安装时选了 8×6：只做一次。改桌面两个设置文件（用 cat 覆盖写入，保留原文件的归属和权限；若首次开机文件尚未生成或未含对应键也能正确处理）
  if [ -f "$MODDIR/.set_grid_8x6" ]; then
    P=/data/user_de/0/$L/shared_prefs
    PF1=$P/com.android.launcher3.prefs.xml
    PF2=$P/com.android.launcher_unique_shared_prefs.xml
    w=0; while [ ! -f "$PF1" ] && [ "$w" -lt 30 ]; do sleep 2; w=$((w + 2)); done
    if [ -f "$PF1" ]; then
      if ! grep -q '"idp_grid_name">8_by_6<' "$PF1"; then
        am force-stop $L
        if grep -q 'name="idp_grid_name"' "$PF1"; then
          sed 's#<string name="idp_grid_name">[^<]*</string>#<string name="idp_grid_name">8_by_6</string>#' "$PF1" > "$MODDIR/.grid.tmp" && cat "$MODDIR/.grid.tmp" > "$PF1"
        else
          sed 's#</map>#    <string name="idp_grid_name">8_by_6</string>\n</map>#' "$PF1" > "$MODDIR/.grid.tmp" && cat "$MODDIR/.grid.tmp" > "$PF1"
        fi
        if [ -f "$PF2" ]; then
          cp -f "$PF2" "$MODDIR/.grid.tmp"
          if grep -q 'name="layout_cellcount_x"' "$MODDIR/.grid.tmp"; then
            sed -i 's#<int name="layout_cellcount_x" value="[0-9]*" />#<int name="layout_cellcount_x" value="8" />#' "$MODDIR/.grid.tmp"
          else
            sed -i 's#</map>#    <int name="layout_cellcount_x" value="8" />\n</map>#' "$MODDIR/.grid.tmp"
          fi
          if grep -q 'name="layout_cellcount_y"' "$MODDIR/.grid.tmp"; then
            sed -i 's#<int name="layout_cellcount_y" value="[0-9]*" />#<int name="layout_cellcount_y" value="6" />#' "$MODDIR/.grid.tmp"
          else
            sed -i 's#</map>#    <int name="layout_cellcount_y" value="6" />\n</map>#' "$MODDIR/.grid.tmp"
          fi
          cat "$MODDIR/.grid.tmp" > "$PF2"
        fi
        rm -f "$MODDIR/.grid.tmp"
        echo "$(ts) 第一次安装：桌面已设成 8×6" >> "$MODDIR/launcher.log"
      fi
      rm -f "$MODDIR/.set_grid_8x6"
    else
      echo "$(ts) 第一次安装：桌面配置尚未生成，保留标记待下次开机设置" >> "$MODDIR/launcher.log"
    fi
  fi
  echo "$VOLLOG $(cmd overlay list com.android.systemui | grep -oE 'y700_vol[a-z]*' | tr '
' ' ')" >> "$MODDIR/launcher.log"
  echo "$LAULOG $(cmd overlay list $L | grep -E 'y700_(port|land|lau)$' | tr '\n' ' ')" >> "$MODDIR/launcher.log"
fi

# ---------- 刷新率：开机信息 ----------
if [ "$VRR" = 1 ]; then
  # 切换到系统高刷档位(3)，消除智能档(0)下桌面/负一屏窗口投出 60Hz 基础帧率导致的偶发闪 60
  cur_rr=$(settings get secure oplus_customize_screen_refresh_rate 2>/dev/null)
  [ "$cur_rr" != "3" ] && settings put secure oplus_customize_screen_refresh_rate 3
  sleep 10
  [ "$SHOW_REFRESH" = 1 ] && service call SurfaceFlinger 1034 i32 1 >/dev/null 2>&1
  echo "$(ts) ColorOS 已加载：$(dumpsys oplus_vrr_service 2>/dev/null | grep -oE 'TouchIdleBean\{mEnable=[a-z]+' | head -1) 档位=$(settings get secure oplus_customize_screen_refresh_rate)" >> "$MODDIR/vrr.log"
fi
wait
