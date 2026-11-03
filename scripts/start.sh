#!/bin/bash
# 容器 1 号进程
#   1) 首启按需激活（ACTIVATION_CODE / NESSUS_LICENSE_FILE，只做一次）
#   2) 首次启动时生成 plugin_feed_info.inc（之后不再改动，改动会触发全量重编译）
#   3) 关掉 Nessus 自带自动更新（离线环境拉不到 feed 会卡在 downloading-failed）
#   4) 后台拉起 nessusd 并保活，让 update.sh 停服务时容器不退出
set -u

PLUGDIR=/opt/nessus/lib/nessus/plugins
VAR=/opt/nessus/var/nessus
FEED="$VAR/plugin_feed_info.inc"
MARK="$VAR/.nessus-docker-registered"

# ---------- 1. 激活（仅一次） ----------
if [ ! -f "$MARK" ]; then
    if [ -n "${NESSUS_LICENSE_FILE:-}" ] && [ -f "${NESSUS_LICENSE_FILE}" ]; then
        echo "[start] 离线注册：$NESSUS_LICENSE_FILE"
        /opt/nessus/sbin/nessuscli fetch --register-offline "$NESSUS_LICENSE_FILE" && touch "$MARK"
    elif [ -n "${ACTIVATION_CODE:-}" ]; then
        echo "[start] 在线注册（activation code 前 4 位: ${ACTIVATION_CODE:0:4}****）"
        /opt/nessus/sbin/nessuscli fetch --register "$ACTIVATION_CODE" && touch "$MARK"
    else
        echo "[start] 未提供 ACTIVATION_CODE / NESSUS_LICENSE_FILE"
        echo "        实例会停在未注册状态：可以导入/编译插件，但 nessusd 校验授权失败后会清空插件"
        echo "        注册命令：docker exec nessus /opt/nessus/sbin/nessuscli fetch --register <激活码>"
    fi
else
    echo "[start] 已注册过（$MARK 存在），跳过激活"
fi

# ---------- 2. feed 信息：只在缺失时生成 ----------
local_set() {
    for f in "$VAR/.plugin_feed_info.inc" "$PLUGDIR/plugin_feed_info.inc"; do
        [ -f "$f" ] || continue
        s=$(grep -oE 'PLUGIN_SET[[:space:]]*=[[:space:]]*"[0-9]+"' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -1)
        [ -n "${s:-}" ] && { echo "$s"; return; }
    done
}
local_feed() {
    for f in "$VAR/.plugin_feed_info.inc" "$PLUGDIR/plugin_feed_info.inc"; do
        [ -f "$f" ] || continue
        s=$(grep -oE 'PLUGIN_FEED[[:space:]]*=[[:space:]]*"[^"]+"' "$f" 2>/dev/null | sed 's/.*"\(.*\)"/\1/' | head -1)
        [ -n "${s:-}" ] && { echo "$s"; return; }
    done
}

if [ ! -s "$FEED" ]; then
    S=$(local_set); F=$(local_feed)
    if [ -n "${S:-}" ]; then
        printf 'PLUGIN_SET = "%s";\nPLUGIN_FEED = "%s";\n' "$S" "${F:-HomeFeed (Non-commercial use only)}" > "$FEED"
        echo "[start] 生成 plugin_feed_info.inc: PLUGIN_SET=$S, PLUGIN_FEED=${F:-HomeFeed}"
    fi
else
    echo "[start] 沿用现有 plugin_feed_info.inc: $(grep -oE '"[0-9]{8,}"' "$FEED" | tr -d '"')"
fi
rm -f "$PLUGDIR/plugin_feed_info.inc"

# ---------- 3. 关掉自动更新 ----------
if /opt/nessus/sbin/nessuscli fix --list 2>/dev/null | grep -q "auto_update: yes"; then
    /opt/nessus/sbin/nessuscli fix --set auto_update=no >/dev/null 2>&1 && echo "[start] 已关闭自动更新"
fi

# ---------- 4. 启动并保活 ----------
PLUGINS=$(ls "$PLUGDIR" 2>/dev/null | wc -l)
echo "[start] $(/opt/nessus/sbin/nessusd -v 2>/dev/null | head -1) | 插件目录文件数: $PLUGINS"
[ "$PLUGINS" -lt 100 ] && cat <<'EOF'
[start] 提示：还没导入插件包，执行（约 20 分钟编译）
        docker exec -it nessus /nessus/update.sh "<插件包URL>"
EOF

/opt/nessus/sbin/nessus-service -q &

while true; do sleep 30; done
