<div align="center">

# nessus-docker

**一条命令把 Nessus 装进 Docker，插件包随用随更新，引擎版本想换就换**

![docker](https://img.shields.io/badge/docker-compose%20%7C%20docker%20run-2496ED)
![engine](https://img.shields.io/badge/Nessus-10.12.6-00a4e4)
![plugins](https://img.shields.io/badge/plugins-347%2C631-brightgreen)

[🇺🇸 English](./README.md)

</div>

---

## 这是什么

Nessus 是商业漏洞扫描器，官方不给免安装的容器包：你得自己下 `.deb`、自己解决激活、自己等它把
三十多万个 NASL 插件编译完——中途断了还得从头再来。

这个仓库把这些步骤固化成一个 Docker 镜像：

- **构建时选版本**：`--build-arg NESSUS_VERSION=10.12.6`，脚本自己去 Tenable 下载对应 `.deb`
- **更新插件一条命令**：下载、校验、导入、等编译，全过程有输出，失败会明确报错
- **容器不会中途消失**：`update.sh` 里停服务不会把容器带走
- **重装不重编译**：插件包和编译结果都放在 Docker 卷里

适合：临时起一台扫描器、内网做资产盘点、想跟着插件更新又不想碰系统包管理。

---

## 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| Docker | 20.10+ | 用 `docker compose` 需要 compose v2 |
| 内存 | ≥ 6 GB | 4 核 5.8 GB 实测编译约 20 分钟，低于 4 GB 容易 OOM |
| 磁盘 | ≥ 15 GB | 插件本体 4.6 GB + 编译产物 4.6 GB + 插件包 1 GB |
| 出网 | `www.tenable.com`、`plugins.nessus.org` | 前者拉安装包，后者拉插件包 |

---

## 开始部署

### 用 compose（推荐）

```bash
git clone https://github.com/Heamborn/nessus-docker.git
cd nessus-docker

docker compose build          # 构建镜像，会自动下载 Nessus 10.12.6
docker compose up -d          # 起容器，端口 8834
```

### 用脚本

```bash
./deploy.sh                   # 构建 + 起容器
```

### 用原生 docker

```bash
docker build -t nessus:10.12.6 .

docker run -itd --name nessus --restart always \
  -p 8834:8834 \
  -v nessus_cache:/nessus/cache \
  -v nessus_data:/opt/nessus/var/nessus \
  nessus:10.12.6
```

> 两条 `-v` 都要带。少了 `nessus_cache` 每次重下 1 GB 插件包，少了 `nessus_data`
> 每次重建容器都要重新编译二十多分钟。

起来之后打开 `https://<宿主机IP>:8834`。证书是自签的，浏览器会拦一下，点继续就行。

---

## 第一次进后台

镜像里已经有一个 `admin` 账号，但密码是原镜像作者留的谜题。直接重置一个你记得住的：

```bash
docker exec -it nessus sh -c 'printf "你的新密码\n你的新密码\n" \
  | /opt/nessus/sbin/nessuscli chpasswd admin'
```

看到 `Password changed for admin` 就可以用它登录了。

---

## 导入插件包（这是关键一步）

刚起来的容器里只有 17 个引导文件，**必须导入一次插件包**才有扫描能力。

### 第一步：拿到属于你这台实例的机器码

```bash
docker exec nessus /opt/nessus/sbin/nessuscli fetch --challenge
```

输出里那串 40 位十六进制就是机器码（Challenge Code）：

```
Challenge code: 300db798b04cc3ae15070dc9075581a0de7c7657
```

它必须由你要用的这套实例现场生成，**不能随手编一串**：Tenable 会把它和激活码绑在一起签发插件包地址，
所以它和这台实例是绑定的。换容器、重建实例后要重新取一次。

### 第二步：用激活码 + 机器码换下载地址

1. 到 [tenable.com](https://www.tenable.com/products/nessus/nessus-essentials) 申请激活码（Activation Code）
2. 打开 [plugins.nessus.org/v2/offline.php](https://plugins.nessus.org/v2/offline.php)
3. 把**激活码**和上一步的 **Challenge code** 一起填进去

会得到一个下载地址，长这样：

```
https://plugins.nessus.org/v2/nessus.php?f=all-2.0.tar.gz&u=<32位>&p=<32位>
```

同一个地址把 `all-2.0.tar.gz` 换成 `all-2.0.tar.gz.sig` 或 `all-2.0.tar.gz.sha256`，
就是它的签名和校验和——脚本会自动去取，你不用手动下。

### 第三步：导入

```bash
docker exec -it nessus /nessus/update.sh "<上一步的地址>"
```

脚本会依次做六件事，每一步都有打印：

| 步骤 | 做什么 |
|---|---|
| 1/6 | 下载插件包（约 1 GB）；如果缓存里已有就直接用 |
| 2/6 | 停掉 nessusd |
| 3/6 | `nessuscli update <包> <签名>` 导入，并校验 `.sha256` |
| 4/6 | 把插件集版本写进 `plugin_feed_info.inc` |
| 5/6 | 启动 nessusd，开始编译 |
| 6/6 | 轮询服务状态，等编译真正结束 |

编译期间会看到 `已等待 xxxs` 的进度，跑完打印：

```
[i] 编译完成，用时 1185s
      引擎: nessusd (Nessus) 10.12.6 [build R20073] for Linux
      插件集: 202610032324
      访问: https://<本机IP>:8834
```

这时候刷新后台，插件数就是三十四万多了。

### 下载老是被掐断怎么办

`plugins.nessus.org` 走 Cloudflare，长连接经常在中途静默停住（TCP 还连着，但不再给数据），
而且服务端**不支持断点续传**——断了只能从头来。仓库里带了一个抗抖动的下载器：

```bash
docker cp scripts/fetch-feed.sh nessus:/nessus/
docker exec -it nessus bash /nessus/fetch-feed.sh "<插件包地址>" /nessus/cache

# 下好之后按本地包导入
docker exec -it nessus /nessus/update.sh \
  /nessus/cache/all-2.0.tar.gz /nessus/cache/all-2.0.tar.gz.sig
```

它做三件事：45 秒内速度低于 200 KB/s 就判定卡死并重连、最多试 12 轮、下完用 `.sha256` 对一遍。

---

## 日常使用

### 跟着插件更新

有新插件包时，重新拿一个地址（机器码不用换），再跑一次 `update.sh` 就行，缓存里旧的包会被覆盖。

### 看编译进度

```bash
docker exec -it nessus tail -f /opt/nessus/var/nessus/logs/nessusd.messages
```

只想看规模变化：

```bash
docker exec -it nessus ls -lh /opt/nessus/var/nessus/plugins-*.db
```

`plugins-code.db` 会一路涨到 1.8 GB 左右，涨完并稳定下来，再等两分钟就绪。

### 换一个 Nessus 版本

```bash
docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .
```

Dockerfile 里没有写死的下载链接：它会去 Tenable 的公开下载接口，按
`Nessus-<版本>-ubuntu1604_amd64.deb` 反查真实下载 id 再拉。构建最后会核对装出来的版本号和参数一致，
不一致直接失败。改完版本号记得重建镜像、重建容器。

### 数据放在哪

| 路径 | 内容 | 大小 |
|---|---|---|
| `/opt/nessus/var/nessus` | 用户、证书、已编译插件库 | 约 10 GB |
| `/nessus/cache` | 下载下来的插件包 | 约 1 GB |
| `/opt/nessus/lib/nessus/plugins` | NASL 源码与 nbin | 约 4.6 GB（在镜像内） |

前两个都挂在 Docker 卷上，`docker compose down` 不会删；要彻底清干净用
`docker compose down -v`。

---

## 实测数据

4 核 / 5.8 GB 内存 / Docker，插件包 `all-2.0.tar.gz`（982 MB）：

| 项 | 结果 |
|---|---|
| 引擎 | Nessus 10.12.6 [build R20073]，nasl 19.18.6 |
| 插件集 | `PLUGIN_SET = "202610032324"` |
| 插件文件 | 346,487 个 `.nasl` + 3,303 个 `.nbin` |
| 实际加载 | 65 个族，**347,631** 个插件 |
| 编译错误 | `Unable to compile` 0 条，`could not be loaded` 0 条 |
| 全流程耗时 | 约 20 分钟（含最后的索引收尾） |

---

## 出问题先看这里

| 现象 | 原因 | 怎么处理 |
|---|---|---|
| 日志刷满 `Unable to compile` | 引擎太老，编不动新版插件 | 把 `NESSUS_VERSION` 调高重建，或换同代插件包 |
| 报 `requires its detached signature file` | 少了签名文件 | 用 `update.sh`（它会自己取 `.sig`），或把签名作为第二个参数 |
| 容器在跑，8834 打不开 | 还在编译 | 看 `nessusd.messages`，等编译完成 |
| 编译完插件数还是 0 | 插件目录里残留了 `plugin_feed_info.inc` | `start.sh` 每次启动都会清掉，重启容器 |
| `dpkg: unable to access dpkg status area` | 基础镜像裁掉了 `/var/lib/dpkg` | Dockerfile 已重建最小状态区，重新构建即可 |
| 导入到一半容器没了 | nessusd 被当成 1 号进程 | 必须用本仓库的 `start.sh` 做入口（它后台托管 nessusd） |
| 磁盘越用越少 | 编译产物约 10 GB | `docker system df` 看卷和悬空镜像，必要时 `docker system prune` |

---

## 项目结构

```
.
├── Dockerfile            # 基础镜像 + 指定版本引擎 + 脚本
├── docker-compose.yml    # 一键起，带两个数据卷
├── deploy.sh             # 构建 / 启动 / 可选更新插件
└── scripts
    ├── start.sh          # 容器 1 号进程：改 feed → 后台起 nessusd → 保活
    ├── update.sh         # 下载 / 校验 / 导入 / 等编译
    └── fetch-feed.sh     # 抗抖动的插件包下载器
```

---

## 说明

仅供非营利性学习与研究使用，请勿用于未授权的目标。

感谢 [Adam-Zhong/nessus](https://github.com/Adam-Zhong/nessus) 提供的原始容器化思路与基础镜像。
