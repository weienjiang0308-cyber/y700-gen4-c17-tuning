#!/system/bin/sh
# 开机早期（系统扫描应用之前）：
# 1) 把模块里的 system/app/<应用> 挂进 /system/app，让 Scene / WireGuard 被当成系统应用
#    本模块自带 skip_mount 不依赖外部挂载组件（meta-overlayfs），自己在内存里挂载：
#    做法（安全）：先在临时 tmpfs 目录里挂好「当前 /system/app 全部应用 + 新应用」并核对数量，核对无误才整体盖到 /system/app；
#    就算其他模块已先挂载过 /system/app 也能在其基础上叠加，任何一步失败就放弃，/system/app 保持原样。
# 2) 把应用加入 ColorOS 自启动白名单（开机后 ColorOS 会重写这个文件，service.sh 会再补一次）
MODDIR=${0%/*}
. "$MODDIR/config.conf"
LOG="$MODDIR/autostart.log"
echo "$(date '+%m-%d %H:%M:%S') post-fs-data" > "$LOG"
CTX=u:object_r:system_file:s0

A="$MODDIR/system/app"
S=/dev/sys_apps_stage
if [ -d "$A" ] && [ -n "$(ls "$A" 2>/dev/null)" ] && [ -d /system/app ]; then
  if grep -q "^sys_apps_stage /system/app " /proc/mounts; then
    echo "本模块已挂载过 /system/app，跳过" >> "$LOG"
  else
    ok=1; ORIG=0; NEW=0
    mkdir -p "$S" && mount -t tmpfs -o mode=755 sys_apps_stage "$S" && chcon "$CTX" "$S" || ok=0
    if [ "$ok" = 1 ]; then
      for e in /system/app/*; do
        [ -e "$e" ] || continue
        n=${e##*/}; ORIG=$((ORIG + 1))
        mkdir "$S/$n" && chcon "$(ls -Zd "$e" | awk '{print $1}')" "$S/$n" && mount --bind "$e" "$S/$n" || { ok=0; break; }
      done
    fi
    if [ "$ok" = 1 ]; then
      for e in "$A"/*; do
        n=${e##*/}
        [ -e "$S/$n" ] && { echo "/system/app 里已有 $n，跳过" >> "$LOG"; continue; }
        NEW=$((NEW + 1))
        mkdir "$S/$n" && chcon "$CTX" "$S/$n" && mount --bind "$e" "$S/$n" || { ok=0; break; }
      done
    fi
    CNT=$(ls "$S" 2>/dev/null | wc -l)
    if [ "$ok" = 1 ] && [ "$CNT" -eq $((ORIG + NEW)) ] && [ "$NEW" -gt 0 ]; then
      if mount --rbind "$S" /system/app; then
        mount -o remount,bind,ro /system/app 2>/dev/null
        echo "已挂进 /system/app：原有 $ORIG 个 + 新增 $NEW 个（$(ls "$A" | tr '\n' ' ')）" >> "$LOG"
      else
        echo "最后一步挂载失败，/system/app 保持原样" >> "$LOG"; umount -l "$S" 2>/dev/null
      fi
    else
      echo "准备阶段失败（ok=$ok 数量=$CNT 原有=$ORIG 新增=$NEW），/system/app 保持原样" >> "$LOG"
      umount -l "$S" 2>/dev/null
    fi
  fi
fi

W=/data/oplus/os/startup/autostart_white_list.txt
[ -f "$W" ] || exit 0
for e in $APPS; do
  pkg=${e%%:*}
  grep -qx "$pkg" "$W" || { echo "$pkg" >> "$W"; grep -qx "$pkg" "$MODDIR/.added" 2>/dev/null || echo "$pkg" >> "$MODDIR/.added"; echo "加入自启白名单：$pkg" >> "$LOG"; }
done
