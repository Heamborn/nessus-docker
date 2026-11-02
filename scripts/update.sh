#!/bin/bash
# Nessus 插件更新
#
# 适配 10.10+ 引擎：nessuscli update 必须同时给出 detached 签名文件
#   nessuscli update <plugin archive> <signature>
# 老版本（10.2）只给一个参数即可，本脚本两个都能跑。
#
# 用法:
#   /nessus/update.sh "<插件包URL>"               # 自动同时下载 .sig / .sha256 并校验
#   /nessus/update.sh <本地tar.gz> [<本地sig>]    # 用已下载好的包
#   /nessus/update.sh                             # 直接用 /nessus/cache/all-2.0.tar.gz
#
# 环境变量:
#   PURGE_CACHE=1   导入成功后删除缓存的 tar.gz / .sig / .sha256（默认保留）
set -u

PLUGDIR=/opt/nessus/lib/nessus/plugins
VAR=/opt/nessus/var/nessus
MSG="$VAR/logs/nessusd.messages"
CACHE=/nessus/cache
TARBALL="$CACHE/all-2.0.tar.gz"
SIG="$CACHE/all-2.0.tar.gz.sig"
SHA="$CACHE/all-2.0.tar.gz.sha256"

die() { echo -e "\n[!] $*"; exit 1; }

src="${1:-}"
sigarg="${2:-}"
mkdir -p "$CACHE"

echo "-------------------------------------------"
echo " 更新源    : ${src:-$TARBALL}"
echo " 引擎      : $(/opt/nessus/sbin/nessusd -v 2>/dev/null | head -1)"
echo " 当前插件集: $(grep -oE '"[0-9]{8,}"' "$VAR/plugin_feed_info.inc" 2>/dev/null | tr -d '\"')"
echo "-------------------------------------------"

# ---------- 1. 取包 + 签名 ----------
case "$src" in
  http://*|https://*)
    echo "[1/6] 下载插件包（约 1GB，耐心等）"
    wget --no-check-certificate -O "$TARBALL" "$src" || die "插件包下载失败，检查网络或重新生成 URL"
    if [ -z "$sigarg" ]; then
      echo "      下载 detached 签名 ..."
      wget --no-check-certificate -O "$SIG" "$(echo "$src" | sed 's/\.tar\.gz$/.tar.gz.sig/')" \
        || die "签名下载失败；10.10+ 引擎必须提供签名，可手动用第二个参数指定"
      wget --no-check-certificate -O "$SHA" "$(echo "$src" | sed 's/\.tar\.gz$/.tar.gz.sha256/')" 2>/dev/null || true
    fi
    ;;
  "")
    [ -f "$TARBALL" ] || die "$TARBALL 不存在，也没给 URL"
    echo "[1/6] 使用缓存包 $TARBALL"
    ;;
  *)
    [ "$(readlink -f "$src")" != "$(readlink -f "$TARBALL")" ] && cp -f "$src" "$TARBALL" || true
    [ -n "$sigarg" ] && cp -f "$sigarg" "$SIG" 2>/dev/null
    echo "[1/6] 使用本地包 $src"
    ;;
esac

SZ=$(stat -c %s "$TARBALL" 2>/dev/null || echo 0)
echo "      包大小: $((SZ/1024/1024)) MB"
[ "$SZ" -gt 10485760 ] || die "包小于 10MB，下载不完整"

if [ -f "$SHA" ]; then
  a=$(sha256sum "$TARBALL" | awk '{print $1}')
  b=$(awk '{print $1}' "$SHA")
  [ "$a" = "$b" ] && echo "      sha256 校验通过" || die "sha256 不匹配，重新下载"
fi

# ---------- 2. 停服务 ----------
echo "[2/6] 停止 nessusd"
/etc/init.d/nessusd stop >/dev/null 2>&1
pkill -x nessusd 2>/dev/null
sleep 3

# ---------- 3. 导入 ----------
echo "[3/6] nessuscli update <包> <签名>"
rm -f "$PLUGDIR/plugin_feed_info.inc"
: > "$MSG"
if [ -f "$SIG" ]; then
  OUT=$(/opt/nessus/sbin/nessuscli update "$TARBALL" "$SIG" 2>&1)
else
  OUT=$(/opt/nessus/sbin/nessuscli update "$TARBALL" 2>&1)
fi
echo "$OUT" | tail -25
echo "$OUT" | grep -qiE "requires its detached signature|error|invalid|failed" && \
  die "导入失败（见上方输出）"
echo "$OUT" | grep -q "Update successful" || die "未看到 Update successful，导入未完成"

# 默认保留缓存包（1GB），重跑/重建容器都不必再下；要清理加 PURGE_CACHE=1
if [ "${PURGE_CACHE:-0}" = "1" ]; then
  echo "      清理缓存包（PURGE_CACHE=1）"
  rm -f "$TARBALL" "$SIG" "$SHA"
else
  echo "      缓存保留在 $CACHE（清理: PURGE_CACHE=1）"
fi

# ---------- 4. feed 信息 ----------
SET=$(grep -oE 'PLUGIN_SET[[:space:]]*=[[:space:]]*"[0-9]+"' "$VAR/.plugin_feed_info.inc" 2>/dev/null \
      | grep -oE '[0-9]+' | head -1)
if [ -n "${SET:-}" ]; then
  printf 'PLUGIN_SET = "%s";\nPLUGIN_FEED = "ProfessionalFeed (Direct)";\nPLUGIN_FEED_TRANSPORT = "Tenable Network Security Lightning";\n' \
    "$SET" > "$VAR/plugin_feed_info.inc"
  rm -f "$PLUGDIR/plugin_feed_info.inc"
  echo "[4/6] plugin_feed_info.inc -> PLUGIN_SET=$SET"
else
  echo "[4/6] 未取到 PLUGIN_SET，沿用现有 feed 信息"
fi

# ---------- 5. 启动 ----------
echo "[5/6] 启动 nessusd，开始编译（346k 插件，4 核约 10-15 分钟）"
: > "$MSG"
/etc/init.d/nessusd start >/dev/null 2>&1

# ---------- 6. 等编译 ----------
echo "[6/6] 等待编译完成"
SPIN=0; STUCK=0; LAST=0
while true; do
  sleep 15; SPIN=$((SPIN+15))

  FAIL=$(grep -c "Unable to compile" "$MSG" 2>/dev/null | head -1); FAIL=${FAIL:-0}
  if [ "$FAIL" -gt 500 ]; then
    echo -e "\n[!] 有 $FAIL 个插件编译失败 —— 引擎与插件包版本不匹配，换同代包或升级引擎"
    tail -8 "$MSG"; exit 1
  fi

  READY=$(curl -sk https://127.0.0.1:8834/server/status 2>/dev/null | grep -c '"code":200')
  if [ "$READY" -ge 1 ]; then
    STUCK=$((STUCK+1))
    [ "$STUCK" -ge 4 ] && {
      echo -e "\n[i] 编译完成，用时 ${SPIN}s"
      echo "      引擎: $(/opt/nessus/sbin/nessusd -v | head -1)"
      echo "      插件集: $(grep -oE '"[0-9]{8,}"' "$VAR/plugin_feed_info.inc" | tr -d '\"')"
      echo "      访问: https://<本机IP>:8834"
      exit 0
    }
  else
    STUCK=0
  fi

  [ "$SPIN" -ge 7200 ] && { echo -e "\n[!] 超时 2 小时，查看 $MSG"; exit 1; }
  printf '\r      已等待 %4ds  %s' "$SPIN" "$(tail -1 "$MSG" 2>/dev/null | cut -c1-60)"
done
