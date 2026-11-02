#!/bin/bash
# 一键：构建镜像 -> 启动容器 -> （可选）更新插件
#
#   ./deploy.sh                                  只构建+启动
#   ./deploy.sh "<插件包URL>"                     构建+启动+更新插件
#   NESSUS_VERSION=10.12.6 ./deploy.sh "<URL>"   指定引擎版本
set -eu

VERSION="${NESSUS_VERSION:-10.12.6}"
NAME="${CONTAINER_NAME:-nessus}"
PORT="${HOST_PORT:-8834}"
URL="${1:-}"
# 需要保留已编译插件库（重建容器免重编译）时：DATA_VOLUME=1 ./deploy.sh
DATA_VOLUME="${DATA_VOLUME:-0}"

cd "$(dirname "$0")"

echo "==> 构建 nessus:${VERSION}"
docker build --build-arg NESSUS_VERSION="$VERSION" -t "nessus:${VERSION}" .

echo "==> 启动容器 ${NAME} (宿主机端口 ${PORT})"
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null
fi
VOL_ARGS="-v nessus_cache:/nessus/cache"
[ "$DATA_VOLUME" = "1" ] && VOL_ARGS="$VOL_ARGS -v nessus_data:/opt/nessus/var/nessus -v nessus_plugins:/opt/nessus/lib/nessus/plugins"

docker run -itd --name "$NAME" --restart always \
  -p "${PORT}:8834" \
  $VOL_ARGS \
  -v nessus_cache:/nessus/cache \
  "nessus:${VERSION}"

sleep 20
docker logs "$NAME" 2>&1 | tail -8

if [ -n "$URL" ]; then
  echo "==> 更新插件"
  docker exec -it "$NAME" /nessus/update.sh "$URL"
fi

echo "==> 完成： https://<本机IP>:${PORT}"
