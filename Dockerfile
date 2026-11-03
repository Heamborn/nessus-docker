# Nessus Docker —— 自建基础镜像（不依赖任何第三方 Nessus 镜像）
#
# 构建：
#   docker build -t nessus:10.12.6 .                                  # 默认
#   docker build --build-arg BASE_IMAGE=public.ecr.aws/docker/library/ubuntu:22.04 -t nessus:10.12.6 .
#   docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .
#
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

# openjdk-8 是必须的：Nessus 编译插件、生成 attributes 索引时会 fork java，
# 缺了它会在编译收尾阶段失败（日志里是 execvp(java) failed），
# 随后插件目录被清空、编译成果作废。
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget procps net-tools tzdata \
        openjdk-8-jre-headless \
    && rm -rf /var/lib/apt/lists/*

ARG NESSUS_VERSION=10.12.6
ARG NESSUS_DEB_TAG=ubuntu1604_amd64.deb

# 从 Tenable 公开下载接口按文件名反查 download id，再取 deb；构建末尾校验版本号
RUN set -eux; \
    FILE="Nessus-${NESSUS_VERSION}-${NESSUS_DEB_TAG}"; \
    ID=$(curl -fsSL https://www.tenable.com/downloads/api/v1/public/pages/nessus \
         | grep -o "\"id\":[0-9]*,\"file\":\"${FILE}\"" \
         | head -1 | sed 's/^"id"://; s/,.*$//'); \
    test -n "$ID"; \
    curl -fsSL -o /tmp/nessus.deb \
      "https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/${ID}/download?i_agree_to_tenable_license_agreement=true"; \
    dpkg -i /tmp/nessus.deb; \
    rm -f /tmp/nessus.deb; \
    VER=$(/opt/nessus/sbin/nessusd -v 2>/dev/null | head -1 || true); \
    echo "$VER"; \
    echo "$VER" | grep -q " ${NESSUS_VERSION} "

COPY scripts/start.sh  /nessus/start.sh
COPY scripts/update.sh /nessus/update.sh
COPY scripts/fetch-feed.sh /nessus/fetch-feed.sh
RUN chmod +x /nessus/start.sh /nessus/update.sh /nessus/fetch-feed.sh

# 插件包缓存（约 1GB）：挂卷后重建容器不必重下
VOLUME ["/nessus/cache"]

EXPOSE 8834
ENTRYPOINT ["/nessus/start.sh"]
