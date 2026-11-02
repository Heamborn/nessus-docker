#!/bin/bash
# 抗抖动下载插件包：卡死检测 + 多轮重试 + sha256 校验
#
# 背景：plugins.nessus.org 走 Cloudflare，长连接常在中途静默停住
#       （TCP 仍 ESTABLISHED 但不再收数据），且服务端不支持 Range 断点续传。
#
# 用法:
#   ./fetch-feed.sh "<插件包URL>" [输出目录]
# 例:
#   ./fetch-feed.sh "https://plugins.nessus.org/v2/nessus.php?f=all-2.0.tar.gz&u=..&p=.." /nessus/cache
set -u
U="${1:?用法: fetch-feed.sh <插件包URL> [目录]}"
DIR="${2:-/nessus/cache}"
EXPECT="${EXPECT_SIZE:-1030136903}"
mkdir -p "$DIR"
cd "$DIR" || exit 1
rm -f all-2.0.tar.gz.part

for try in $(seq 1 12); do
  echo "[$(date +%H:%M:%S)] 第 $try 轮下载 ..."
  curl -k -sS -o all-2.0.tar.gz.part \
       --speed-limit 200000 --speed-time 45 \
       "$U"
  rc=$?
  sz=$(stat -c %s all-2.0.tar.gz.part 2>/dev/null || echo 0)
  echo "[$(date +%H:%M:%S)] rc=$rc size=$sz / $EXPECT"
  if [ "$sz" = "$EXPECT" ]; then
    mv -f all-2.0.tar.gz.part all-2.0.tar.gz
    echo "[$(date +%H:%M:%S)] 下载完成"
    break
  fi
  sleep 5
done

[ -f all-2.0.tar.gz ] || { echo "下载失败"; exit 1; }

echo "[$(date +%H:%M:%S)] 取签名与校验和"
curl -k -sS -o all-2.0.tar.gz.sig    "${U/\.tar\.gz/\.tar.gz.sig}"
curl -k -sS -o all-2.0.tar.gz.sha256 "${U/\.tar\.gz/\.tar.gz.sha256}"

a=$(sha256sum all-2.0.tar.gz | awk '{print $1}')
b=$(awk '{print $1}' all-2.0.tar.gz.sha256)
echo "local  : $a"
echo "remote : $b"
[ "$a" = "$b" ] && echo "[$(date +%H:%M:%S)] sha256 OK" || { echo "sha256 不匹配"; exit 1; }
