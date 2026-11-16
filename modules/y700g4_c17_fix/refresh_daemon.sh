#!/system/bin/sh
# 必须由安卓原生 mksh 运行（busybox ash 的 read -t 超时返回 1 会被误判为管道 EOF 导致消费者退出卡在 165Hz）
[ -z "$KSH_VERSION" ] && [ -x /system/bin/sh ] && exec /system/bin/sh "$0" "$@"
# 刷新率守护 v4.5 —— ColorOS 的触摸空闲降帧 / 刷新率总调度 / OVFR 等已在 post-fs-data 关掉，这里全权控制
#   手指/笔按下          -> 立刻 TOUCH_HZ（165），按着期间保持
#   抬起后 IDLE_SEC 秒，按优先级：
#     前台应用在 games.txt                 -> GAME_HZ（165）
#     正在解码视频                         -> VIDEO_HZ（120，能整除 24/30/60 帧）
#     GPU 负载连续 2 次 ≥ GAME_GPU%（游戏）-> GAME_HZ（165）
#     GPU 负载 ≥ CONTENT_GPU%（滚动文字、动画等画面在动）-> CONTENT_HZ（120）
#     其他                                 -> IDLE_HZ（30）
#   之后每 CHECK_SEC 秒复查；熄屏 -> 交还系统，并改成每 OFF_SEC 秒看一次
#   屏幕要旋转（v4.1+）   -> 在旋转动画开始前立刻 ROTATE_HZ（165），保持 ROTATE_SEC 秒再回到正常判断
#     信号：WindowManager 的 onProposedRotationChanged（方向传感器判定要转 -> 系统决定转屏的第一步，
#     比旋转动画早约 30-50ms）。开机时打开 ProtoLog WM_DEBUG_ORIENTATION 让它输出到 logcat，
#     logcat 只订阅 system 缓冲区里 system_server 进程的这一行（过滤在 logcat 内部完成，shell 不处理其他日志）。
#     转屏时系统会重新下发刷新率策略、可能盖掉强制值，所以切换后 0.3s、0.9s 各补发一次（后台，不阻塞）。
# 切换：service call SurfaceFlinger 1035 i32 <模式序号>（序号 = DisplayManager 模式 id - 1）
#
# 省电设计：复查时只用 shell 内置命令读几个很小的系统文件，不起任何子进程：
#   视频解码计数  /sys/kernel/irq/<号>/per_cpu_count（一行）
#   GPU 负载      /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage
#   前台应用      /dev/cpuset/top-app/cgroup.procs + /proc/<pid>/cmdline
#   屏幕亮灭      /sys/class/backlight/*/brightness
# 触摸只接收「按下/抬起」两个事件（grep 在底层丢掉滑动坐标）；刷新率要变、或有动静需要补发时才调用一次 service。
# 整个守护跑在小核（cpuset background）上，nice=10。
MODDIR=${0%/*}
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH"
LOG="$MODDIR/vrr.log"
TOUCH_HZ=165; IDLE_HZ=30; VIDEO_HZ=120; GAME_HZ=165; CONTENT_HZ=120
ROTATE_HZ=165; ROTATE_SEC=5; ROTATE_DETECT=1; IDLE_SEC=5; CHECK_SEC=2; OFF_SEC=10; GAME_GPU=30; CONTENT_GPU=3; IDLE_REASSERT=1; CPUSET=background; NICE=10; DEBUG=0; VOLKEY=1
GAMES="$MODDIR/games.txt"
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
log() {
  echo "$(date '+%m-%d %H:%M:%S') [daemon] $*" >> "$LOG"
  [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 300 ] && tail -n 150 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 2

# 刷新率 -> 模式序号（最多重试 5 次防止刚开机瞬态 display 服务未就绪）
# C16：DisplayModeRecord{mMode={id=1, width=.., height=.., fps=120.00001
# C17（安卓 17）：supportedModes [{id=1, parentModeId=-1, sfModeId=0, flags=, width=.., height=.., fps=120.00001
# 两种都认；id 都是 DisplayManager 的模式号（= SurfaceFlinger 序号 + 1），fps 只取整数部分
try=0; MODES=""
while [ -z "$MODES" ] && [ "$try" -lt 5 ]; do
  MODES=$(dumpsys display | grep -oE 'DisplayModeRecord\{mMode=\{id=[0-9]+, width=[0-9]+, height=[0-9]+, fps=[0-9]+|\{id=[0-9]+, parentModeId=-?[0-9]+, sfModeId=[0-9]+, flags=[^,]*, width=[0-9]+, height=[0-9]+, fps=[0-9]+' | sed -E 's/^.*\{id=([0-9]+),.*fps=([0-9]+)$/\1:\2/' | sort -u)
  [ -n "$MODES" ] || { sleep 1; try=$((try + 1)); }
done
idx_of() { for l in $MODES; do [ "${l#*:}" = "$1" ] && { echo $(( ${l%%:*} - 1 )); return; }; done; }
I_TOUCH=$(idx_of "$TOUCH_HZ"); I_IDLE=$(idx_of "$IDLE_HZ"); I_VIDEO=$(idx_of "$VIDEO_HZ"); I_GAME=$(idx_of "$GAME_HZ"); I_CONTENT=$(idx_of "$CONTENT_HZ"); I_ROTATE=$(idx_of "$ROTATE_HZ")
if [ -z "$I_TOUCH" ] || [ -z "$I_IDLE" ] || [ -z "$I_VIDEO" ] || [ -z "$I_GAME" ] || [ -z "$I_CONTENT" ] || [ -z "$I_ROTATE" ]; then
  log "错误：配置的刷新率不受支持（支持：$(echo $MODES | sed -E 's/[0-9]+://g')）"; exit 1
fi

# 0-fork 合并单次扫描触摸屏 + 手写笔 + 音量键 + 电源键（Y700 四代：音量减 = pmic_resin，音量加 = gpio-keys，电源键 = pmic_pwrkey）
DEVS=""; KDEVS=""; PDEVS=""
for e in /sys/class/input/event*; do
  [ -r "$e/device/name" ] || continue
  nm=""; read -r nm < "$e/device/name" 2>/dev/null
  case "$nm" in
    *[Tt]ouch[Ss]creen*|*Capacitive*) DEVS="$DEVS /dev/input/${e##*/}" ;;
    gpio-keys|pmic_resin) [ "$VOLKEY" = 1 ] && KDEVS="$KDEVS /dev/input/${e##*/}" ;;
    *pwrkey*|*powerkey*)  PDEVS="$PDEVS /dev/input/${e##*/}" ;;
  esac
done
[ -z "$DEVS" ] && { log "错误：没找到触摸屏"; exit 1; }
BL="$(ls -d /sys/class/backlight/* 2>/dev/null | head -n 1)/brightness"
GPU=/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage; [ -r "$GPU" ] || GPU=""
VIRQ=$(grep -m1 -E 'msm-vidc|iris|venus' /proc/interrupts | awk '{print $1}' | tr -d :)
VFILE=""; [ -n "$VIRQ" ] && [ -r "/sys/kernel/irq/$VIRQ/per_cpu_count" ] && VFILE="/sys/kernel/irq/$VIRQ/per_cpu_count"
TOPAPP=/dev/cpuset/top-app/cgroup.procs; [ -r "$TOPAPP" ] || TOPAPP=""

# 游戏名单一次性读进内存（" 包名 包名 ... "），之后判断不用再读文件
GL=" "; NG=0
if [ -f "$GAMES" ]; then
  while read -r g _; do case "$g" in ''|\#*) ;; *) GL="$GL$g "; NG=$((NG + 1)) ;; esac; done < "$GAMES"
fi

echo $$ > "$MODDIR/daemon.pid"
# 放到小核（cpuset background = cpu0-3）、降低调度权重和优先级；之后启动的 getevent/grep/service 都会继承
[ -n "$CPUSET" ] && [ -w "/dev/cpuset/$CPUSET/cgroup.procs" ] && echo $$ > "/dev/cpuset/$CPUSET/cgroup.procs" 2>/dev/null
[ -n "$CPUSET" ] && [ -w "/dev/cpuctl/$CPUSET/cgroup.procs" ] && echo $$ > "/dev/cpuctl/$CPUSET/cgroup.procs" 2>/dev/null
[ -n "$NICE" ] && renice -n "$NICE" -p $$ >/dev/null 2>&1
log "启动 v4.5（cpuset=${CPUSET} nice=${NICE}）：触摸=${TOUCH_HZ} 静止${IDLE_SEC}s=${IDLE_HZ} 视频=${VIDEO_HZ} 画面在动(GPU≥${CONTENT_GPU}%)=${CONTENT_HZ} 游戏(名单${NG}个/GPU≥${GAME_GPU}%)=${GAME_HZ} 旋转=$([ "$ROTATE_DETECT" = 1 ] && echo "${ROTATE_HZ}×${ROTATE_SEC}s" || echo 关) 视频检测=${VFILE:-/proc/interrupts#$VIRQ} 前台检测=${TOPAPP:-无} 设备=$DEVS 音量键=${KDEVS:-无} 电源键=${PDEVS:-无}"
# 旋转 + 亮屏唤醒 + 息屏过渡提前探测：复用同一个 logcat 连接订阅 system_server 的转屏与 PowerManagerService 亮灭屏单行信号（C++ 内部过滤，平时 0 唤醒、0 额外进程）。
SDK=$(getprop ro.build.version.sdk)
[ "${SDK:-0}" -ge 37 ] 2>/dev/null && cmd protolog_configuration logcat disable WM_DEBUG_ORIENTATION >/dev/null 2>&1
rot_watch() {
  while true; do
    ss=$(pidof system_server)
    if [ -n "$ss" ]; then
      if [ "$ROTATE_DETECT" = 1 ]; then
        if [ "${SDK:-0}" -ge 37 ] 2>/dev/null; then
          logcat -b system -v raw -T "$(date +%s).0" --pid="$ss" -e '^(Display id 0 rotation changed to|Waking up from|Going to sleep)' 'WindowManager:I' 'PowerManagerService:I' '*:S' 2>/dev/null
        else
          cmd window logging enable-text WM_DEBUG_ORIENTATION >/dev/null 2>&1
          logcat -b system -v raw -T "$(date +%s).0" --pid="$ss" -e '^(onProposedRotationChanged|Waking up from|Going to sleep)' 'WindowManager:V' 'PowerManagerService:I' '*:S' 2>/dev/null
        fi
      else
        logcat -b system -v raw -T "$(date +%s).0" --pid="$ss" -e '^(Waking up from|Going to sleep)' 'PowerManagerService:I' '*:S' 2>/dev/null
      fi
    fi
    sleep 5
  done
}
release() { service call SurfaceFlinger 1035 i32 -1 >/dev/null 2>&1; }
trap 'trap - TERM INT HUP; release; rm -f "$MODDIR/daemon.pid"; kill -9 0' TERM INT HUP

# ---- 检测：全部内置命令，结果放全局变量 ----
VC=0
vidc_read() {            # VC = 视频解码中断累计数
  VC=0
  if [ -n "$VFILE" ]; then
    IFS=, read -r a b c d e f g h _ < "$VFILE" 2>/dev/null
    VC=$(( ${a:-0} + ${b:-0} + ${c:-0} + ${d:-0} + ${e:-0} + ${f:-0} + ${g:-0} + ${h:-0} ))
    return
  fi
  [ -z "$VIRQ" ] && return
  while read -r l; do
    case "$l" in "$VIRQ:"*)
      set -- $l; shift
      for x in "$@"; do case "$x" in *[!0-9]*) break ;; *) VC=$((VC + x)) ;; esac; done
      return ;;
    esac
  done < /proc/interrupts
}
GB=0
gpu_read() { GB=0; [ -z "$GPU" ] && return; read -r GB _ < "$GPU" 2>/dev/null; GB=${GB%%[!0-9]*}; GB=${GB:-0}; }
screen_on() { s=1; read -r s < "$BL" 2>/dev/null; [ "$s" != "0" ]; }
FGPKG=""; FGLIST="-"; FGRES=1
fg_game() {              # 前台（top-app）里有没有名单中的游戏
                         # v4.2：先只读进程号列表，和上次一样（没切应用）就直接用上次的结果，不再逐个打开 /proc/<pid>/cmdline
  [ "$NG" -gt 0 ] && [ -n "$TOPAPP" ] || { FGPKG=""; return 1; }
  L=""; while read -r p; do L="$L $p"; done < "$TOPAPP"
  [ "$L" = "$FGLIST" ] && return $FGRES
  FGLIST=$L; FGPKG=""; FGRES=1
  for p in $L; do
    c=""; read -r c < "/proc/$p/cmdline" 2>/dev/null; c=${c%%:*}
    case "$c" in system_server|'') continue ;; esac
    case "$GL" in *" $c "*) FGPKG=$c; FGRES=0; return 0 ;; esac
  done
  return 1
}

while true; do
  [ -f "$MODDIR/disable" ] && { release; log "模块已禁用，退出"; exit 0; }
  # 只把「按下/抬起」（BTN_TOUCH = 0001 014a）、音量键（0072/0073）、电源键（0074）及转屏/亮灭屏信号交给 shell
  [ "${SDK:-0}" -ge 37 ] 2>/dev/null && SYS_PAT='^(Display id 0 rotation changed to|Waking up from|Going to sleep)' || SYS_PAT='^(onProposedRotationChanged|Waking up from|Going to sleep)'
  { for dv in $DEVS $KDEVS $PDEVS; do getevent -q "$dv" & done; rot_watch & wait; } 2>/dev/null \
    | grep --line-buffered -e '^0001 014a ' -e '^0001 007[234] ' -e "$SYS_PAT" | {
    CUR=""; RA=0; NCHK=0; NI=0; dv=0
    force_again() {   # 应用申请高刷（DisplayModeDirector.setAppRequest）时系统会重新下发策略、盖掉强制，所以要补发。
                      # 应用申请高刷一定伴随界面更新，所以只在「这次复查期间 GPU 有负载或在解码视频」时补发，完全静止时不补发。
                      # 静止（30Hz）稳定后过滤 2%->3% 的底噪毛刺，避免空转补发；被应用改成 60Hz 时底噪约 5% 仍会立即纠正
      if [ "$CUR" = "idle" ] && [ "$RA" -eq 0 ]; then
        [ "$GB" -gt $((BASE + 1)) ] || [ "$dv" -gt 0 ] || return
      else
        [ "$GB" -gt "$BASE" ] || [ "$dv" -gt 0 ] || return
      fi
      if [ "$RA" -gt 0 ]; then
        RA=$((RA - 1)); service call SurfaceFlinger 1035 i32 "$1" >/dev/null 2>&1
      elif [ "$CUR" = "idle" ]; then
        NI=$((NI + 1)); [ $((NI % IDLE_REASSERT)) -eq 0 ] && service call SurfaceFlinger 1035 i32 "$1" >/dev/null 2>&1
      else service call SurfaceFlinger 1035 i32 "$1" >/dev/null 2>&1; fi     # 其他状态：有动静的每次复查都补发（原来每 3 次才补发，系统改成 60 会停留最多 6 秒）
    }
    setm() {          # setm <名字> <序号>
      [ "$CUR" = "$1" ] && { force_again "$2"; return; }
      service call SurfaceFlinger 1035 i32 "$2" >/dev/null 2>&1
      CUR=$1; RA=3; [ "$DEBUG" = 1 ] && log "-> $1${FGPKG:+ ($FGPKG)} gpu=$GB vidc=$dv"
    }
    setm touch "$I_TOUCH"
    # v4.3：等待用截止时间。read -t 会被后台补发子进程结束时的 SIGCHLD 提前打断（实测转屏后约 0.9 秒就被打断、
    #   提前降到 120/30），所以醒来后先看有没有到截止时间，没到就接着等剩下的。
    now() { read NOW _ < /proc/uptime; NOW=${NOW%.*}; }
    hold() { now; UNTIL=$((NOW + $1)); T=$1; }     # hold <秒>：从现在起至少保持当前状态这么久
    WAKE_AT=0
    do_wake() {       # 亮屏唤醒（黑屏按电源键，或双击/抬手/皮套触发 Waking up）：抢在亮屏动画第 1 帧前切 165Hz，并卡点补发防系统重置
      now
      [ "$CUR" = wake ] && [ $((NOW - WAKE_AT)) -lt 1 ] && return
      WAKE_AT=$NOW; TOUCHING=0; vidc_read; VPREV=$VC; HG=0
      CUR=""; setm wake "$I_TOUCH"; hold "$IDLE_SEC"; T=1
      ( sleep 0.12; service call SurfaceFlinger 1035 i32 "$I_TOUCH"
        sleep 0.25; screen_on && service call SurfaceFlinger 1035 i32 "$I_TOUCH"
        sleep 0.45; screen_on && service call SurfaceFlinger 1035 i32 "$I_TOUCH" ) >/dev/null 2>&1 &
    }
    TOUCHING=0; hold "$IDLE_SEC"; vidc_read; VPREV=$VC; HG=0; BASE=0
    while true; do
      if [ "$TOUCHING" = 1 ]; then read -r _l; rc=$?
      else read -t "$T" -r _l; rc=$?; fi
      if [ "$rc" -eq 0 ]; then
        case "$_l" in
          Waking\ up*)                                                          # 系统亮屏唤醒（电源键/抬手亮屏/双击亮屏/皮套开盖等全渠道）
            do_wake ;;
          Going\ to\ sleep*)                                                    # 系统开始息屏（放下息屏/超时息屏/双击息屏/电源键息屏）：只发 1 次 165Hz 播完收拢动画，1 秒后背光灭即休眠
            TOUCHING=0
            if [ "$CUR" != touch ] && [ "$CUR" != wake ] && [ "$CUR" != rotate ]; then
              service call SurfaceFlinger 1035 i32 "$I_TOUCH" >/dev/null 2>&1
            fi
            CUR=sleep_anim; hold 1; T=1 ;;
          onProposed*|Display*)                                                 # 要旋转：动画开始前切高刷，保持 ROTATE_SEC 秒
            if [ "$TOUCHING" = 1 ]; then service call SurfaceFlinger 1035 i32 "$I_ROTATE" >/dev/null 2>&1   # 按着屏幕转：状态不变，只补发
            else CUR=""; setm rotate "$I_ROTATE"; hold "$ROTATE_SEC"; fi
            ( sleep 0.3; service call SurfaceFlinger 1035 i32 "$I_ROTATE"; sleep 0.6; service call SurfaceFlinger 1035 i32 "$I_ROTATE" ) >/dev/null 2>&1 & ;;
          *00000002) ;;                                                         # 按键长按的重复事件：不管
          0001\ 0074\ 00000001)                                                 # 电源键按下：黑屏时抢跑唤醒 165Hz；亮屏时切 165Hz 让关屏动画也丝滑
            if ! screen_on || [ "$CUR" = off ]; then do_wake
            else TOUCHING=1; CUR=""; setm touch "$I_TOUCH"; fi ;;
          0001\ 0074\ 00000000)                                                 # 电源键抬起：刚唤醒则保持 wake 计时，否则走普通抬起
            TOUCHING=0; vidc_read; VPREV=$VC; HG=0
            if [ "$CUR" = wake ]; then T=1
            else hold "$IDLE_SEC"; T=1; fi ;;
          *00000001) TOUCHING=1; CUR=""; setm touch "$I_TOUCH" ;;               # 按下（手指/笔/音量键）：立刻 165，每次都重发（系统可能已经偷偷改过）
          *)         TOUCHING=0; vidc_read; VPREV=$VC; HG=0                     # 抬起：重新计时；刚转过屏或刚唤醒就取更晚的那个截止时间
                     now; if { [ "$CUR" = rotate ] || [ "$CUR" = wake ]; } && [ "$UNTIL" -gt $((NOW + IDLE_SEC)) ]; then T=$((UNTIL - NOW)); else hold "$IDLE_SEC"; fi
                     T=1 ;;                                                 # 等待期间每秒醒一次，补发高刷（见下）
        esac
        continue
      fi
      [ "$rc" -eq 1 ] && break                                 # getevent 退出
      if [ "$UNTIL" -gt 0 ]; then                              # 被信号提前叫醒：没到截止时间就接着等
        now; if [ "$NOW" -lt "$UNTIL" ]; then
          if ! screen_on; then
            # 刚触发亮屏唤醒的前 2 秒屏幕面板正在通电点亮（brightness 尚未变非 0），不能误判成熄屏掐断高刷
            if [ "$CUR" = wake ] && [ $((NOW - WAKE_AT)) -lt 2 ]; then T=1; continue; fi
            UNTIL=0; release; CUR=off; [ "$DEBUG" = 1 ] && log "-> 熄屏，交还系统"; T=$OFF_SEC; continue
          fi
          # 抬手后 / 亮屏后 / 转屏后的保持期：应用申请刷新率时系统会重算策略、把强制的 165 盖成 60，
          # 所以保持期内每秒补发一次（只有这几秒，开销可忽略）
          case "$CUR" in touch|wake) service call SurfaceFlinger 1035 i32 "$I_TOUCH" >/dev/null 2>&1 ;; rotate) service call SurfaceFlinger 1035 i32 "$I_ROTATE" >/dev/null 2>&1 ;; esac
          T=1; continue
        fi
        UNTIL=0
      fi
      [ -f "$MODDIR/disable" ] && { log "模块已禁用，退出"; kill -TERM 0; }
      if ! screen_on; then
        [ "$CUR" != "off" ] && { release; CUR=off; [ "$DEBUG" = 1 ] && log "-> 熄屏，交还系统"; }
        T=$OFF_SEC; continue                                   # 熄屏时少醒几次
      fi
      T=$CHECK_SEC
      vidc_read; dv=$((VC - VPREV)); VPREV=$VC
      gpu_read
      # 静止画面的 GPU 底噪随刷新率上涨（实测 30Hz≈2%、120Hz≈10%、165Hz≈13%，约为刷新率的 8%），
      # 判断「画面在动」要先扣掉当前刷新率的底噪，否则进了 120 就会被底噪卡住、降不回 30
      case "$CUR" in idle) BASE=$((IDLE_HZ * 8 / 100)) ;; video) BASE=$((VIDEO_HZ * 8 / 100)) ;; content) BASE=$((CONTENT_HZ * 8 / 100)) ;; *) BASE=$((TOUCH_HZ * 8 / 100)) ;; esac
      if [ "$GB" -ge "$GAME_GPU" ]; then HG=$((HG + 1)); else HG=0; fi   # 防偶发尖峰：连续 2 次才算游戏
      if fg_game; then setm game "$I_GAME"
      elif [ "$dv" -ge 10 ]; then setm video "$I_VIDEO"        # 在解码视频：优先按视频算（视频本身也会占 GPU）
      elif [ "$HG" -ge 2 ]; then setm game "$I_GAME"
      elif [ "$GB" -ge $((CONTENT_GPU + BASE)) ]; then setm content "$I_CONTENT"   # 画面一动就切，灵敏度优先
      else setm idle "$I_IDLE"; fi
    done
  }
  sleep 2
done
