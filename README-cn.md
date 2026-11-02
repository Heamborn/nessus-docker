<div align="center">

# Nessus Docker

**引擎版本可自升级的 Nessus 容器化部署**

![platform](https://img.shields.io/badge/platform-Docker%20%7C%20docker--compose-blueviolet)
![engine](https://img.shields.io/badge/engine-10.12.6-informational)
![plugins](https://img.shields.io/badge/plugin%20set-202610032324-success)
![plugins loaded](https://img.shields.io/badge/plugins-347%2C631-brightgreen)

[🇨🇳 简体中文](./README-cn.md) ｜ [🇺🇸 English](./README.md)

</div>

一句话：**`docker build` 时说要用哪版 Nessus，就装哪版**；`update.sh` 一条命令把最新插件包导进去，
签名自动校验、编译完成自动判定、批量失败立即报错。

---

## 特性

| 能力 | 说明 |
|---|---|
| 引擎版本可选 | `--build-arg NESSUS_VERSION=10.12.6`，构建时从 Tenable 官方下载 API 按文件名反查 id 拉 deb，不用手找直链 |
| 插件包更新一条命令 | 下载 → 校验 `.sha256` → 取 `.sig` → `nessuscli update <包> <签名>` → 改写 feed → 等编译 |
| 适配 10.10+ 强制签名 | 自动同源下载 detached signature，不再撞 `requires its detached signature file` |
| 编译结果可判定 | 轮询 `/server/status` 到 `200` 才算完成；出现批量 `Unable to compile` 立刻失败退出，不会无限空转 |
| 容器不中途退出 | `start.sh` 作为 PID1 后台托管 nessusd，`update.sh` 停/起服务不会带走容器 |
| 1GB 包只下一次 | 插件包落在 `nessus_cache` 卷，重建容器不必重下 |
| feed 自动修正 | 启动时把 `plugin_feed_info.inc` 统一改写为 `ProfessionalFeed (Direct)`，并清掉插件目录里的同名文件 |

## 环境要求

- Docker 20.10+ / docker compose v2
- 内存 ≥ 6 GB（4 核 / 5.8 GB 实测编译约 20 分钟，全量 34.7 万插件）
- 磁盘 ≥ 15 GB（插件 4.6 GB + 插件库 4.6 GB + 缓存 1 GB）
- 出网：`www.tenable.com`（拉 deb）、`plugins.nessus.org`（拉插件包）

---

## 快速开始

### 方式一：docker compose（推荐）

```bash
git clone https://github.com/<you>/nessus-docker.git
cd nessus-docker

docker compose build
docker compose up -d

# 首次导入插件（约 10-20 分钟编译，日志会实时打印进度）
docker exec -it nessus /nessus/update.sh "<插件包URL>"
```

### 方式二：一键脚本

```bash
./deploy.sh "<插件包URL>"       # 构建 + 启动 + 更新插件
./deploy.sh                     # 只构建 + 启动
```

### 方式三：纯 docker

```bash
docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .

docker run -itd --name nessus --restart always \
  -p 8834:8834 \
  -v nessus_cache:/nessus/cache \
  nessus:10.12.6

docker exec -it nessus /nessus/update.sh "<插件包URL>"
```

### 首次登入

```bash
# 重置 admin 密码（非交互）
docker exec -it nessus sh -c 'printf "YourPassw0rd\nYourPassw0rd\n" \
  | /opt/nessus/sbin/nessuscli chpasswd admin'
```

浏览器打开 `https://<宿主机IP>:8834`（自签证书，浏览器告警属正常），账号 `admin`。

---

## 插件包 URL 怎么来

1. 在 [tenable.com](https://www.tenable.com/products/nessus/nessus-essentials) 申请／取得激活码（Activation Code）

2. **让容器自己生成机器码（Challenge Code）**——必须由你要用的这套实例现场生成，不能随手编一串十六进制：

   ```bash
   docker exec nessus /opt/nessus/sbin/nessuscli fetch --challenge
   ```

   输出：

   ```
   Challenge code: 300db798b04cc3ae15070dc9075581a0de7c7657

   You can copy the challenge code above and paste it alongside your
   Activation Code at:
   https://plugins.nessus.org/v2/offline.php
   ```

   这串 40 位十六进制就是本实例的机器码，Tenable 拿它和激活码一起签发插件包 URL，因此它和这套实例是绑定的：

   - 换容器／重建实例后要重新获取，旧机器码签出来的 URL 仍可用，但语义上已不是当前实例
   - 同一串机器码不要多人共用，否则插件包 URL 会互相覆盖授权

3. 打开 [plugins.nessus.org/v2/offline.php](https://plugins.nessus.org/v2/offline.php)，把 **激活码 + 上一步的 Challenge code** 一起填进去

4. 得到形如下面的 URL：

```
https://plugins.nessus.org/v2/nessus.php?f=all-2.0.tar.gz&u=<32位>&p=<32位>
```

同一个 URL 再加后缀即可单独取签名与校验和（脚本会自动做）：

```
...&f=all-2.0.tar.gz.sig
...&f=all-2.0.tar.gz.sha256
```

---

## 更新插件

```bash
docker exec -it nessus /nessus/update.sh "<插件包URL>"
```

脚本六步，每步都有输出：

```
[1/6] 下载插件包（约 1GB） / 使用缓存包 / 使用本地包
[2/6] 停止 nessusd
[3/6] nessuscli update <包> <签名>
[4/6] plugin_feed_info.inc -> PLUGIN_SET=<来自包内的真实值>
[5/6] 启动 nessusd，开始编译
[6/6] 等待编译完成（轮询 /server/status）
```

### 下载老是被掐断？

`plugins.nessus.org` 走 Cloudflare，长连接常在中途静默停住（TCP 仍 ESTABLISHED，但不再收数据），
而且服务端**不支持 Range 断点续传**——`update.sh` 里那条 wget 断了就得从头再来。用附带的抗抖动下载器：

```bash
docker cp scripts/fetch-feed.sh nessus:/nessus/
docker exec -it nessus bash /nessus/fetch-feed.sh "<插件包URL>" /nessus/cache
# 然后走本地包流程
docker exec -it nessus /nessus/update.sh /nessus/cache/all-2.0.tar.gz /nessus/cache/all-2.0.tar.gz.sig
```

它做三件事：卡死检测（45 秒低于 200KB/s 就断开重来）、最多 12 轮重试、下完用 `.sha256` 校验。

只用本地包（内网环境）：

```bash
docker cp all-2.0.tar.gz      nessus:/nessus/cache/
docker cp all-2.0.tar.gz.sig  nessus:/nessus/cache/
docker cp all-2.0.tar.gz.sha256 nessus:/nessus/cache/
docker exec -it nessus /nessus/update.sh /nessus/cache/all-2.0.tar.gz /nessus/cache/all-2.0.tar.gz.sig
```

查看编译进度：

```bash
docker exec -it nessus tail -f /opt/nessus/var/nessus/logs/nessusd.messages
docker exec -it nessus ls -lh  /opt/nessus/var/nessus/plugins-*.db
```

---

## 升级引擎版本

```bash
docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .
```

Dockerfile 里没有任何硬编码下载链接：它会去
`https://www.tenable.com/downloads/api/v1/public/pages/nessus` 里按
`Nessus-${NESSUS_VERSION}-ubuntu1604_amd64.deb` 反查 download id，再取 deb。
换版本号即可，构建末尾还会校验装出来的版本号与参数一致。

---

## 实测数据

环境：4 vCPU / 5.8 GB RAM / Docker，插件包 `all-2.0.tar.gz`（982 MB）

| 项 | 值 |
|---|---|
| 引擎 | Nessus **10.12.6** [build R20073] / nasl 19.18.6 |
| 插件集 | `PLUGIN_SET = "202610032324"` / `ProfessionalFeed (Direct)` |
| 插件文件 | 346,487 个 `.nasl` + 3,303 个 `.nbin` |
| 实际加载 | `/plugins/families` 65 个族，共 **347,631** 个插件 |
| 编译错误 | `Unable to compile` **0** 条，`could not be loaded` **0** 条 |
| 编译耗时 | 约 20 分钟（含 attributes 索引收尾） |
| 磁盘占用 | 插件目录 4.6 G，插件库 4.6 G（code 1.8 G / desc 554 M / attributes 2.3 G） |

---

## 目录结构

```
.
├── Dockerfile            # 基础镜像 + 指定版本引擎 + 脚本落地
├── docker-compose.yml    # 一键起，插件包落 nessus_cache 卷
├── deploy.sh             # 构建 / 启动 / 可选更新插件
└── scripts
    ├── start.sh          # PID1：改写 feed → 后台起 nessusd → 保活
    ├── update.sh         # 下载 / 校验 / 导入 / 等编译
    └── fetch-feed.sh     # 抗抖动的插件包下载器（卡死重试 + sha256）
```

---

## 排错

| 现象 | 原因与处理 |
|---|---|
| 日志刷 `Unable to compile` | 引擎与插件包不同代。提升 `NESSUS_VERSION` 重新构建，或换同代插件包 |
| `requires its detached signature file` | 少了 `.sig`。用 `update.sh`，或手动把签名作为第二个参数 |
| 容器在跑但 8834 打不开 | 还在编译。`docker exec nessus tail -f /opt/nessus/var/nessus/logs/nessusd.messages` |
| 编译完插件数是 0 | 插件目录里残留 `plugin_feed_info.inc` 覆盖了 feed 信息，`start.sh` 已自动清理，重启容器即可 |
| `dpkg: unable to access dpkg status area` | 基础镜像裁掉了 `/var/lib/dpkg`，Dockerfile 已重建最小状态区 |
| 编译中途容器消失 | 入口脚本必须是 PID1 保活模式（本仓库 `start.sh` 已处理），别让 nessusd 直接当 1 号进程 |
| 磁盘爆 | 编译产物约 10 G，`docker system df` 看看卷和悬空镜像 |

---

## 免责声明

仅供非营利性学习与研究使用。请勿用于未授权的目标。使用本仓库产生的任何后果由使用者自行承担。

## 致谢

感谢 [Adam-Zhong/nessus](https://github.com/Adam-Zhong/nessus) 提供的原始容器化思路与运行时的基础镜像。
