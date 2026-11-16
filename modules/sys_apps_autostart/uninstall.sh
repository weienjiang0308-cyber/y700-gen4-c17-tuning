#!/system/bin/sh
MODDIR=${0%/*}
W=/data/oplus/os/startup/autostart_white_list.txt
[ -f "$MODDIR/.added" ] && [ -f "$W" ] && while read -r p; do sed -i "/^$p\$/d" "$W"; done < "$MODDIR/.added"
