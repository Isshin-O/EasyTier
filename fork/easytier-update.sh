#!/bin/sh
# 手动更新 OpenWrt / Debian 上的 EasyTier，来源是 fork 的 Latest Release。
#
# 用法（root）：先存成文件再运行，不要用 wget | sh：
#   wget -O /root/easytier-update.sh https://raw.githubusercontent.com/Isshin-O/EasyTier/main/fork/easytier-update.sh
#   sh /root/easytier-update.sh
#
# 更新在后台进行，通过 EasyTier 组网 SSH 进来、更新时连接断开也没关系：
# 重新连上后看 /tmp/easytier-update.log。
# 可选环境变量：
#   DIR      程序目录（默认从运行中的进程反查，查不到用 /opt/easytier）
#   SERVICE  服务控制命令，会追加 stop/start（默认自动识别 /etc/init.d/easytier 或 systemd 的 easytier*.service）
#   ARCH     架构（默认 uname -m）
REPO=${REPO:-Isshin-O/EasyTier}
ARCH=${ARCH:-$(uname -m)}
LOG=/tmp/easytier-update.log
WORK=/tmp/easytier-update

if [ -z "$ET_UPDATE_BG" ]; then
  [ "$(id -u)" = 0 ] || { echo "需要 root 运行"; exit 1; }
  [ -f "$0" ] || { echo "请先把脚本存成文件再运行（不要用 wget | sh）"; exit 1; }
  : > "$LOG"
  # 脱离当前 SSH 会话，组网断开时更新照样做完。
  if command -v setsid >/dev/null 2>&1; then
    ET_UPDATE_BG=1 setsid sh "$0" >>"$LOG" 2>&1 </dev/null &
  else
    ET_UPDATE_BG=1 nohup sh "$0" >>"$LOG" 2>&1 </dev/null &
  fi
  echo "更新已转入后台，SSH 断开也会继续。日志：$LOG"
  n=0
  while :; do
    c=$(wc -l < "$LOG")
    if [ "$c" -gt "$n" ]; then sed -n "$((n + 1)),${c}p" "$LOG"; n=$c; fi
    grep -q '^== 结束' "$LOG" && exit 0
    sleep 1
  done
fi

trap '' HUP
set -e

svc() {
  if [ -n "$SERVICE" ]; then
    $SERVICE "$1"
  elif [ -x /etc/init.d/easytier ]; then
    /etc/init.d/easytier "$1"
  elif command -v systemctl >/dev/null 2>&1; then
    units=$(systemctl list-units --type=service --all --plain --no-legend 'easytier*' | awk '{print $1}')
    [ -n "$units" ] || { echo "没找到 easytier 的 systemd 服务，请用 SERVICE=... 指定"; return 1; }
    for u in $units; do systemctl "$1" "$u"; done
  else
    echo "不知道怎么控制服务，请用 SERVICE=... 指定"; return 1
  fi
}

restore() {
  set +e
  echo "换回旧版"
  svc stop
  for f in "$WORK"/bak/*; do [ -f "$f" ] && mv -f "$f" "$DIR/"; done
  svc start
}

on_exit() {
  rc=$?
  if [ "$rc" != 0 ] && [ -n "$swapped" ]; then restore; fi
  echo "== 结束（退出码 $rc）"
}
trap on_exit EXIT

fetch() { wget -q -O "$2" "$1" 2>/dev/null || curl -fsSL -o "$2" "$1"; }

pid=$(pidof easytier-core | awk '{print $1}')
if [ -z "$DIR" ]; then
  if [ -n "$pid" ] && exe=$(readlink "/proc/$pid/exe"); then DIR=$(dirname "$exe")
  elif p=$(command -v easytier-core); then DIR=$(dirname "$p")
  else DIR=/opt/easytier; fi
fi
[ -x "$DIR/easytier-core" ] || { echo "在 $DIR 找不到 easytier-core，请用 DIR=... 指定"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK/new" "$WORK/bak"
fetch "https://api.github.com/repos/$REPO/releases/latest" "$WORK/latest.json"
tag=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$WORK/latest.json" | head -n 1)
[ -n "$tag" ] || { echo "取不到 Latest 版本"; exit 1; }
have=$("$DIR/easytier-core" --version 2>/dev/null | awk '{print $2}')
if [ "v$have" = "$tag" ]; then echo "已是最新：$tag"; exit 0; fi
echo "目录：$DIR  当前：${have:-无}  最新：$tag"

zip="easytier-linux-$ARCH-$tag.zip"
base="https://github.com/$REPO/releases/download/$tag"
fetch "$base/$zip" "$WORK/$zip"
fetch "$base/SHA256SUMS" "$WORK/SHA256SUMS"
(cd "$WORK" && grep " \*\?$zip\$" SHA256SUMS | sha256sum -c -) || { echo "校验失败，未改动"; exit 1; }
unzip -q -o -j "$WORK/$zip" -d "$WORK/new"
"$WORK/new/easytier-core" --version >/dev/null || { echo "新程序不能在本机运行（架构不对？）"; exit 1; }

svc stop || true
# 从这里起出错都会自动换回旧版。旧文件移到 /tmp，目录空间紧张时也能换。
swapped=1
for b in easytier-core easytier-cli easytier-web easytier-web-embed; do
  [ -f "$DIR/$b" ] && [ -f "$WORK/new/$b" ] || continue
  mv "$DIR/$b" "$WORK/bak/$b"
  cp "$WORK/new/$b" "$DIR/$b"
  chmod 755 "$DIR/$b"
done
svc start
if [ -n "$pid" ]; then
  sleep 10
  pidof easytier-core >/dev/null || { echo "新版启动失败"; exit 1; }
fi
swapped=
echo "已更新到 $("$DIR/easytier-core" --version)；旧版备份在 $WORK/bak（重启后消失）"
