#!/bin/bash
# 容器 1 号进程
#   1) 首次启动时生成 plugin_feed_info.inc（之后不再改动，改动会触发全量重编译）
#   2) 关掉 Nessus 自带的自动更新（离线环境拉不到 feed，会卡在 downloading-failed）
#   3) 后台拉起 nessusd 并保活，让 update.sh 停服务时容器不退出
set -u

PLUGDIR=/opt/nessus/lib/nessus/plugins
VAR=/opt/nessus/var/nessus
FEED="$VAR/plugin_feed_info.inc"

feed_set_local() {
    for f in "$VAR/.plugin_feed_info.inc" "$PLUGDIR/plugin_feed_info.inc"; do
        [ -f "$f" ] || continue
        s=$(grep -oE 'PLUGIN_SET[[:space:]]*=[[:space:]]*"[0-9]+"' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -1)
        [ -n "${s:-}" ] && { echo "$s"; return; }
    done
}

write_feed() {
    local set="$1"
    printf 'PLUGIN_SET = "%s";\nPLUGIN_FEED = "ProfessionalFeed (Direct)";\nPLUGIN_FEED_TRANSPORT = "Tenable Network Security Lightning";\n' \
        "$set" > "$FEED"
}

# 只在缺失时生成；已有就不要动
if [ ! -f "$FEED" ] || ! grep -q PLUGIN_SET "$FEED"; then
    SET=$(feed_set_local)
    if [ -n "${SET:-}" ]; then
        write_feed "$SET"
        echo "[start] 生成 plugin_feed_info.inc, PLUGIN_SET=$SET"
    fi
else
    echo "[start] 沿用现有 plugin_feed_info.inc, $(grep -oE '"[0-9]{8,}"' "$FEED" | tr -d '\"')"
fi

rm -f "$PLUGDIR/plugin_feed_info.inc"

# 离线环境关掉自动更新，否则拉不到 feed 会卡在 downloading-failed（503）
if /opt/nessus/sbin/nessuscli fix --list 2>/dev/null | grep -q "auto_update: yes"; then
    /opt/nessus/sbin/nessuscli fix --set auto_update=no >/dev/null 2>&1 && echo "[start] 已关闭自动更新"
fi

PLUGINS=$(ls "$PLUGDIR" 2>/dev/null | wc -l)
echo "[start] $(/opt/nessus/sbin/nessusd -v 2>/dev/null | head -1) | 插件目录文件数: $PLUGINS"
[ "$PLUGINS" -lt 100 ] && cat <<'EOF'
[start] 提示：还没导入插件包，执行（约 10-20 分钟编译）
        docker exec -it nessus /nessus/update.sh "<插件包URL>"
EOF

/opt/nessus/sbin/nessus-service -q &

while true; do sleep 30; done
