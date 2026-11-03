<div align="center">

# nessus-docker

**用官方安装包自己构建 Nessus 容器：基础镜像自建、引擎版本可选、插件包一条命令更新**

![docker](https://img.shields.io/badge/docker-compose%20%7C%20docker%20run-2496ED)
![engine](https://img.shields.io/badge/Nessus-10.12.6-00a4e4)
![plugins](https://img.shields.io/badge/plugins-347%2C672-brightgreen)
![base](https://img.shields.io/badge/base-ubuntu%3A22.04-orange)

[🇺🇸 English](./README.md)

</div>

---

## 这是什么

Nessus 是商业漏洞扫描器，官方不给容器包：得自己下 `.deb`、自己解决激活、自己等它把三十多万个
NASL 插件编译完。这个仓库把这套流程固化成一个**完全自建**的镜像——不依赖任何第三方 Nessus 镜像，
基础镜像是公开的 `ubuntu:22.04`，引擎从 Tenable 官方下载接口现取。

- **引擎版本可选**：`--build-arg NESSUS_VERSION=10.12.6`
- **插件包一条命令更新**：下载、校验签名、导入、等编译，全程有输出，失败会明确报错
- **踩过的坑都写进脚本了**：缺 Java、feed 指纹对不上、离线环境自动更新卡 503

---

## 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| Docker | 20.10+ | compose 需 v2 |
| 内存 | ≥ 6 GB | 4 核 5.8 GB 实测编译约 25 分钟 |
| 磁盘 | ≥ 15 GB | 插件 4.6 GB + 编译产物 4.6 GB + 插件包 1 GB |
| 出网 | `www.tenable.com`（拉安装包）、`plugins.nessus.org`（拉插件包） | 构建期与更新期各一次 |
| 一个 Nessus 激活码 | 去 [tenable.com](https://www.tenable.com/products/nessus/nessus-essentials) 申请，免费 | 每个实例用一次，用完即绑定 |

---

## 快速开始

### 1. 构建

```bash
git clone https://github.com/Heamborn/nessus-docker.git
cd nessus-docker

docker compose build
# 或
docker build -t nessus:10.12.6 .
```

如果拉不动 Docker Hub（`registry-1.docker.io` 超时），换官方公共镜像源即可，不用配代理：

```bash
docker build --build-arg BASE_IMAGE=public.ecr.aws/docker/library/ubuntu:22.04 -t nessus:10.12.6 .
```

### 2. 启动并激活

激活码通过环境变量传进去，容器**首次启动会自己注册一次**，之后不再重复：

```bash
docker run -itd --name nessus --restart always \
  -p 8834:8834 \
  -e ACTIVATION_CODE=XXXX-XXXX-XXXX-XXXX-XXXX \
  -v nessus_cache:/nessus/cache \
  nessus:10.12.6
```

compose 用户在 `docker-compose.yml` 里填 `environment: ACTIVATION_CODE`。

离线环境用 license 文件代替激活码（`fetch --challenge` → offline.php 换回来的那个文件）：

```bash
-v /path/to/license.lic:/nessus/license.lic \
-e NESSUS_LICENSE_FILE=/nessus/license.lic
```

> 激活码是**一次性**的：注册成功后它与这台实例绑定，再拿去注册别的实例会被 Tenable 拒（400）。
> 重新部署请申请新码，或者把已注册实例的 `/opt/nessus/var/nessus` 与 `/opt/nessus/etc/nessus` 一起保留下来复用。

### 3. 进后台

```bash
docker exec -it nessus sh -c 'printf "你的密码\n你的密码\n" \
  | /opt/nessus/sbin/nessuscli chpasswd admin'
```

浏览器打开 `https://<IP>:8834`，账号 `admin`。

### 4. 导入插件包（必须有这一步）

刚起来的容器只有十几个引导文件，**不导入插件包就没有扫描能力**。

拿机器码：

```bash
docker exec nessus /opt/nessus/sbin/nessuscli fetch --challenge
```

输出里那串 40 位十六进制就是本实例的机器码，必须由这套实例现场生成，不能手编。

然后用**激活码 + 机器码**去 [plugins.nessus.org/v2/offline.php](https://plugins.nessus.org/v2/offline.php)
换下载地址，形如：

```
https://plugins.nessus.org/v2/nessus.php?f=all-2.0.tar.gz&u=<32位>&p=<32位>
```

导入：

```bash
docker exec -it nessus /nessus/update.sh "<上一步的地址>"
```

脚本六步：下载 → 校验 sha256 + 取 .sig → 停服务 → `nessuscli update <包> <签名>` →
写 feed 指纹 → 启动并等编译。跑完打印：

```
[i] 编译完成，用时 1500s
      引擎: nessusd (Nessus) 10.12.6 [build R20073] for Linux
      插件集: 202610042310
      插件库: 1815 MB
      访问: https://<本机IP>:8834
```

---

## 三个必须知道的坑（脚本已经处理）

**1. 没有 Java，编译到最后一刻会前功尽弃**

Nessus 编译插件、生成 attributes 索引时会 fork `java`。镜像里缺 JDK 时日志出现
`execvp(java) failed`，编译看起来完成了，但紧接着插件目录被清空、DB 归零。
Dockerfile 已装 `openjdk-8-jre-headless`。

**2. `PLUGIN_SET` / `PLUGIN_FEED` 必须等于插件包自带的值**

nessusd 会拿 `plugin_feed_info.inc` 和插件内容对账，不一致就打印
`Could not validate plugin feed`，然后把插件目录清空、编译成果全部作废。

- `PLUGIN_SET` 要从包内 `plugin_feed_info.inc` 直接读，**不能**用 `plugins.php` 的当前时间戳（那个一直在变）
- `PLUGIN_FEED` 要跟包一致（免费包是 `HomeFeed (Non-commercial use only)`），不要硬写成 `ProfessionalFeed`

**3. 未注册实例会被清空；自动更新会把服务卡在 503**

- 实例未注册时也能导入编译，但收尾校验授权失败 → 清空插件。所以 `ACTIVATION_CODE` 不是可选项
- Nessus 会自己联网拉 feed，拉不到就停在 `feed_status: downloading-failed`，网页一直转圈。
  `start.sh` 和 `update.sh` 都会先 `nessuscli fix --set auto_update=no`

---

## 授权说明（重要）

| 方式 | 结果 | 说明 |
|---|---|---|
| 官方激活码（本仓库默认） | `license.type = essentials`，IP 数、到期时间由激活码决定 | 合法、可自动更新、可长期使用；插件包也可换成在线自动更新 |
| SecurityCenter 托管模式（`nessuscli fetch --security-center`） | `license.type = sc_scanner`，`ips = 2147483647`，无到期 | 看起来"不限 IP"，但授权校验由 SC 侧完成；本地无有效 SC 授权时，编译收尾仍会 `Could not validate the license` 并清空插件 |

结论：**想要稳定可用，就老老实实用激活码注册。** 网上流传的"无限 IP"是 SC 托管态，
只有在 SecurityCenter 侧确实授权过扫描端时才成立，凭一个 Essentials 激活码复现不出来。

---

## 日常使用

**跟着插件更新**：重新生成插件包地址（机器码不用换），再跑一次 `update.sh`。

**看编译进度**：

```bash
docker exec -it nessus tail -f /opt/nessus/var/nessus/logs/nessusd.messages
docker exec -it nessus ls -lh /opt/nessus/var/nessus/plugins-*.db
```

**换引擎版本**：

```bash
docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .
```

**要不要持久化**：默认不持久化，重建容器要重新编译（约 25 分钟）。想省这一步就把
`/opt/nessus/var/nessus` 和 `/opt/nessus/lib/nessus/plugins` **一起**挂卷（只挂前者，插件文件不在照样重编）：

```bash
-v nessus_data:/opt/nessus/var/nessus \
-v nessus_plugins:/opt/nessus/lib/nessus/plugins
```

---

## 实测数据

4 核 / 5.8 GB，`ubuntu:22.04` + Nessus 10.12.6 + OpenJDK 8，插件包 982 MB：

| 项 | 结果 |
|---|---|
| 引擎 | Nessus 10.12.6 [build R20073] / nasl 19.18.6 |
| 插件集 | `202610042310` / `HomeFeed`（与包内一致） |
| 插件文件 | 350,719 个 |
| 实际加载 | 65 个族，**347,672** 个插件 |
| 编译错误 | `Unable to compile` 0 条 |
| feed 校验 | `Could not validate` 0 条 |
| 全流程 | 约 25 分钟（含索引收尾与 DB 装载） |

---

## 出问题先看这里

| 现象 | 原因 | 处理 |
|---|---|---|
| 编译完插件数归零、目录被清空 | 缺 Java / feed 指纹不符 / 未注册 | 看 `nessusd.messages` 里是 `execvp(java) failed` 还是 `Could not validate` |
| `Could not validate plugin feed` | `PLUGIN_SET` 或 `PLUGIN_FEED` 与包不一致 | 用仓库里的 `update.sh`，它从包里直接读这两个值 |
| `Could not validate the license used on this scanner` | 实例未注册或激活码失效 | 重新注册，或申请新激活码 |
| 网页一直转圈、`downloading-failed` | 自动更新在联网拉 feed | `nessuscli fix --set auto_update=no`，脚本已自动做 |
| `requires its detached signature file` | 少了 `.sig` | 用 `update.sh`，或把签名作为第二个参数 |
| 激活返回 `HTTP 400` | 激活码已被别的实例用掉 | 换新码，或复用已有实例的状态目录 |
| 下载中途停住 | Cloudflare 静默停传且不支持断点续传 | 用 `scripts/fetch-feed.sh`，带卡死重试 |

---

## 项目结构

```
.
├── Dockerfile            # ubuntu:22.04 + 官方 deb + OpenJDK8，引擎版本可选
├── docker-compose.yml    # 一键起，带插件包缓存卷
├── deploy.sh             # 构建 / 启动 / 可选更新
└── scripts
    ├── start.sh          # PID1：按需激活 → 写 feed → 关自动更新 → 托管 nessusd → 保活
    ├── update.sh         # 下载 / 校验 / 导入 / 写指纹 / 等编译
    └── fetch-feed.sh     # 抗抖动下载器（卡死重试 + sha256）
```

---

## 说明

仅供非营利性学习与研究使用，请勿用于未授权的目标。Nessus 为 Tenable 商业软件，请遵守其许可条款。

容器化思路参考 [Adam-Zhong/nessus](https://github.com/Adam-Zhong/nessus)。
