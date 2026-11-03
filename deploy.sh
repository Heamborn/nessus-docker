#!/bin/bash
# 一键：构建镜像 -> 启动容器 ->（可选）更新插件
#
#   ACTIVATION_CODE=XXXX-XXXX-XXXX-XXXX-XXXX ./deploy.sh      构建 + 启动 + 首次自动注册
#   ./deploy.sh                                               只构建 + 启动（需手动注册）
#   ./deploy.sh "<插件包URL>"                                  构建 + 启动 + 更新插件
#   DATA_VOLUME=1 ./deploy.sh                                 额外挂数据卷（重建不重编译）
#   BASE_IMAGE=public.ecr.aws/docker/library/ubuntu:22.04 ./deploy.sh   拉不动 Docker Hub 时
set -eu

VERSION="${NESSUS_VERSION:-10.12.6}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"
NAME="${CONTAINER_NAME:-nessus}"
PORT="${HOST_PORT:-8834}"
URL="${1:-}"
DATA_VOLUME="${DATA_VOLUME:-0}"

cd "$(dirname "$0")"

echo "==> 构建 nessus:${VERSION}（base: ${BASE_IMAGE}）"
docker build --build-arg BASE_IMAGE="$BASE_IMAGE" \
             --build-arg NESSUS_VERSION="$VERSION" \
             -t "nessus:${VERSION}" .

echo "==> 启动容器 ${NAME}（宿主机端口 ${PORT}）"
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker rm -f "$NAME" >/dev/null
fi

VOL_ARGS="-v nessus_cache:/nessus/cache"
if [ "$DATA_VOLUME" = "1" ]; then
    VOL_ARGS="$VOL_ARGS -v nessus_data:/opt/nessus/var/nessus -v nessus_plugins:/opt/nessus/lib/nessus/plugins"
fi

ENV_ARGS=""
if [ -n "${ACTIVATION_CODE:-}" ]; then
    ENV_ARGS="$ENV_ARGS -e ACTIVATION_CODE=$ACTIVATION_CODE"
fi

# shellcheck disable=SC2086
docker run -itd --name "$NAME" --restart always \
    -p "${PORT}:8834" \
    $ENV_ARGS \
    $VOL_ARGS \
    "nessus:${VERSION}"

sleep 25
docker logs "$NAME" 2>&1 | tail -8

if [ -n "$URL" ]; then
    echo "==> 更新插件"
    docker exec -it "$NAME" /nessus/update.sh "$URL"
fi

echo "==> 完成： https://<本机IP>:${PORT}"
