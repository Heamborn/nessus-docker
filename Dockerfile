#
# Nessus Docker 破解版 —— 可自更新引擎版本
#
# 背景：ramisec/nessus 镜像内的引擎固定在 10.2.0(2022)，而 Tenable 的插件包
# 早已升级到新的 nasl 运行时。用 10.2.0 编译 2026 年的 all-2.0.tar.gz，会在
# nessusd.messages 里刷满 "Unable to compile"，plugins-code.db 一个插件都写不进去。
#
# 本 Dockerfile 在原镜像（保留其破解布局：plugin_feed_info / 免 license）之上，
# 直接安装指定版本的官方 Nessus 引擎，使引擎与最新插件包匹配。
#
# 构建：
#   docker build -t nessus:10.12.6 .
#   docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .
#
FROM ramisec/nessus

# 要升级到的 Nessus 版本；修改后需重新 build
ARG NESSUS_VERSION=10.12.6
# 官方 deb 的发行版后缀，ubuntu1604 包在 18.04 基础镜像上可直接运行
ARG NESSUS_DEB_TAG=ubuntu1604_amd64.deb

# 1) 原镜像为了瘦身把 /var/lib/dpkg 删掉了，dpkg 必须先有最小状态区才能工作
# 2) 从 Tenable 公开下载 API 里按文件名反查 download id，再取 deb
# 3) dpkg 的 postinst 在没有 systemd 的环境里返回非 0（会尝试拉起服务），
#    这里只以「二进制是否就位 + 版本号是否匹配」为成功判据（nessusd -v 本身也可能返回 42）
RUN set -eux; \
    mkdir -p /var/lib/dpkg/info /var/lib/dpkg/updates /var/lib/dpkg/triggers \
             /var/lib/dpkg/alternatives /var/lib/dpkg/parts; \
    : > /var/lib/dpkg/status; \
    : > /var/lib/dpkg/available; \
    : > /var/lib/dpkg/diversions; \
    FILE="Nessus-${NESSUS_VERSION}-${NESSUS_DEB_TAG}"; \
    ID=$(curl -fsSL https://www.tenable.com/downloads/api/v1/public/pages/nessus \
         | grep -o "\"id\":[0-9]*,\"file\":\"${FILE}\"" \
         | head -1 | sed 's/^"id"://; s/,.*$//'); \
    test -n "$ID" || { echo "找不到 $FILE 的下载 id"; exit 1; }; \
    echo "downloading $FILE (id=$ID)"; \
    curl -fsSL -o /tmp/nessus.deb \
      "https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/${ID}/download?i_agree_to_tenable_license_agreement=true"; \
    dpkg -i /tmp/nessus.deb || true; \
    rm -f /tmp/nessus.deb; \
    test -x /opt/nessus/sbin/nessusd; \
    VER=$(/opt/nessus/sbin/nessusd -v 2>/dev/null | head -1 || true); \
    echo "$VER"; \
    echo "$VER" | grep -q " ${NESSUS_VERSION} " || { \
        echo "安装后的版本与 NESSUS_VERSION=${NESSUS_VERSION} 不一致"; exit 1; }

# 入口脚本：写 feed 信息 -> 后台拉起 nessusd -> 保活（让 update.sh 停服务时容器不退出）
COPY scripts/start.sh /nessus/start.sh
# 插件更新脚本：自动下载/校验 detached 签名，适配 10.10+ 的 nessuscli update 语法
COPY scripts/update.sh /nessus/update.sh
RUN chmod +x /nessus/start.sh /nessus/update.sh

# /nessus/cache      插件包缓存（1GB，重装容器不必重下）
# /opt/nessus/var/nessus  运行数据（用户/证书/插件库约 10GB，不挂卷则重建容器要重编 20 分钟）
VOLUME ["/nessus/cache", "/opt/nessus/var/nessus"]

EXPOSE 8834

# 注意：必须用 ENTRYPOINT，父镜像自带 ENTRYPOINT /nessus/run.sh
ENTRYPOINT ["/nessus/start.sh"]
