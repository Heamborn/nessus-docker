#!/bin/bash
# 容器 PID1
#   1) 按原 ramisec 项目的口径改写 plugin_feed_info.inc（ProfessionalFeed Direct）
#   2) 后台启动 nessusd
#   3) 保活，使 `docker exec ... update.sh` 里 stop/start nessusd 不会导致容器退出
set -u

PLUGDIR=/opt/nessus/lib/nessus/plugins
VAR=/opt/nessus/var/nessus
FEED="$VAR/plugin_feed_info.inc"

load_set() {
    for f in "$VAR/.plugin_feed_info.inc" "$FEED" "$PLUGDIR/plugin_feed_info.inc"; do
        [ -f "$f" ] || continue
        s=$(grep -oE 'PLUGIN_SET[[:space:]]*=[[:space:]]*"[0-9]+"' "$f" 2>/dev/null \
            | grep -oE '[0-9]+' | head -1)
        [ -n "${s:-}" ] && { echo "$s"; return; }
    done
}

SET=$(load_set)
if [ -n "${SET:-}" ]; then
    printf 'PLUGIN_SET = "%s";\nPLUGIN_FEED = "ProfessionalFeed (Direct)";\nPLUGIN_FEED_TRANSPORT = "Tenable Network Security Lightning";\n' \
        "$SET" > "$FEED"
    echo "[start] plugin_feed_info.inc -> PLUGIN_SET=$SET (ProfessionalFeed Direct)"
else
    echo "[start] 没有可用的 PLUGIN_SET，跳过 feed 改写（首次安装属正常）"
fi

# 插件目录里的同名文件会让 nessusd 以它为准，必须清掉
rm -f "$PLUGDIR/plugin_feed_info.inc"

PLUGINS=$(ls "$PLUGDIR" 2>/dev/null | wc -l)
echo "[start] $(/opt/nessus/sbin/nessusd -v 2>/dev/null | head -1) | 插件目录文件数: $PLUGINS"
[ "$PLUGINS" -lt 100 ] && cat <<'EOF'
[start] 提示：当前还没导入插件包，执行下面命令完成首次安装（约 10-20 分钟编译）
        docker exec -it nessus /nessus/update.sh "<插件包URL>"
EOF

/opt/nessus/sbin/nessus-service -q &

while true; do sleep 30; done
