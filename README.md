<div align="center">

# Nessus Docker

**Containerized Nessus with a self-upgradable engine**

![platform](https://img.shields.io/badge/platform-Docker%20%7C%20docker--compose-blueviolet)
![engine](https://img.shields.io/badge/engine-10.12.6-informational)
![plugins](https://img.shields.io/badge/plugin%20set-202610032324-success)
![plugins loaded](https://img.shields.io/badge/plugins-347%2C631-brightgreen)

[🇨🇳 简体中文](./README-cn.md) ｜ [🇺🇸 English](./README.md)

</div>

In one line: **pick the Nessus engine version at `docker build` time**, then import the current plugin
feed with a single command — signature verified, compilation completion detected, mass failures fail fast.

---

## Features

| Capability | Detail |
|---|---|
| Selectable engine version | `--build-arg NESSUS_VERSION=10.12.6`; the build resolves the deb download id from Tenable's public download API by filename — no hardcoded links |
| One-command plugin update | download → verify `.sha256` → fetch `.sig` → `nessuscli update <pkg> <sig>` → rewrite feed → wait for compile |
| Handles the 10.10+ signature requirement | automatically fetches the detached signature, so you never hit `requires its detached signature file` |
| Deterministic completion | polls `/server/status` until `200`; aborts immediately when mass `Unable to compile` shows up instead of spinning forever |
| Container survives updates | `start.sh` runs as PID1 and supervises nessusd, so stopping the service inside `update.sh` no longer kills the container |
| 1 GB downloaded once | the tarball lands in the `nessus_cache` volume and survives container recreation |
| Feed info normalized | on boot, `plugin_feed_info.inc` is rewritten to `ProfessionalFeed (Direct)` and the stale copy inside the plugin dir is removed |

## Requirements

- Docker 20.10+ / docker compose v2
- RAM ≥ 6 GB (4 vCPU / 5.8 GB measured: ~20 min for the full 347k plugin set)
- Disk ≥ 15 GB (4.6 GB plugins + 4.6 GB plugin DBs + 1 GB cache)
- Outbound access to `www.tenable.com` and `plugins.nessus.org`

---

## Quick start

### Option 1: docker compose (recommended)

```bash
git clone https://github.com/<you>/nessus-docker.git
cd nessus-docker

docker compose build
docker compose up -d

# first plugin import (10-20 min, progress is printed live)
docker exec -it nessus /nessus/update.sh "<PLUGIN_PACKAGE_URL>"
```

### Option 2: one-shot script

```bash
./deploy.sh "<PLUGIN_PACKAGE_URL>"   # build + run + update
./deploy.sh                          # build + run only
```

### Option 3: plain docker

```bash
docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .

docker run -itd --name nessus --restart always \
  -p 8834:8834 \
  -v nessus_cache:/nessus/cache \
  nessus:10.12.6

docker exec -it nessus /nessus/update.sh "<PLUGIN_PACKAGE_URL>"
```

> Data persistence: `/opt/nessus/var/nessus` is a volume (`nessus_data`, ~10 GB with users,
> certificates and the compiled plugin DBs) so recreating the container does not recompile;
> `/nessus/cache` holds the 1 GB tarball. With plain `docker run`, pass **both** `-v` flags.

### First login

```bash
# reset the admin password (non-interactive)
docker exec -it nessus sh -c 'printf "YourPassw0rd\nYourPassw0rd\n" \
  | /opt/nessus/sbin/nessuscli chpasswd admin'
```

Open `https://<host-ip>:8834` (self-signed certificate — the browser warning is expected), user `admin`.

---

## Where the plugin URL comes from

1. Request an activation code at [tenable.com](https://www.tenable.com/products/nessus/nessus-essentials)

2. **Let the container generate the machine code (Challenge Code)** — it has to come from the instance you are actually going to use; do not invent a hex string:

   ```bash
   docker exec nessus /opt/nessus/sbin/nessuscli fetch --challenge
   ```

   Output:

   ```
   Challenge code: 300db798b04cc3ae15070dc9075581a0de7c7657

   You can copy the challenge code above and paste it alongside your
   Activation Code at:
   https://plugins.nessus.org/v2/offline.php
   ```

   That 40-hex-digit value is this instance's machine code. Tenable signs the plugin URL against it together with the activation code, so it is bound to this instance:

   - Re-fetch it after recreating the container — an old code still yields a working URL, but it no longer represents the current instance
   - Do not share one code between several deployments, or their plugin URLs will overwrite each other's entitlement

3. Open [plugins.nessus.org/v2/offline.php](https://plugins.nessus.org/v2/offline.php) and enter the **activation code plus the challenge code from the previous step**

4. You get a URL like:

```
https://plugins.nessus.org/v2/nessus.php?f=all-2.0.tar.gz&u=<32 hex>&p=<32 hex>
```

The same URL with a suffix serves the signature and checksum (the script does this for you):

```
...&f=all-2.0.tar.gz.sig
...&f=all-2.0.tar.gz.sha256
```

---

## Updating plugins

```bash
docker exec -it nessus /nessus/update.sh "<PLUGIN_PACKAGE_URL>"
```

Six explicit stages:

```
[1/6] download (~1 GB) / use cache / use local file
[2/6] stop nessusd
[3/6] nessuscli update <pkg> <sig>
[4/6] plugin_feed_info.inc -> PLUGIN_SET=<real value from the package>
[5/6] start nessusd, compilation begins
[6/6] wait for completion (polls /server/status)
```

### Download keeps stalling?

`plugins.nessus.org` sits behind Cloudflare and long connections often go silent mid-transfer
(TCP still ESTABLISHED, no more data). The server does **not** support Range requests, so an interrupted
`wget` in `update.sh` has to start over. Use the bundled resilient downloader:

```bash
docker cp scripts/fetch-feed.sh nessus:/nessus/
docker exec -it nessus bash /nessus/fetch-feed.sh "<PLUGIN_PACKAGE_URL>" /nessus/cache
# then import from the local file
docker exec -it nessus /nessus/update.sh /nessus/cache/all-2.0.tar.gz /nessus/cache/all-2.0.tar.gz.sig
```

It watches for stalls (aborts below 200 KB/s for 45 s), retries up to 12 times, then verifies `.sha256`.

Offline / air-gapped:

```bash
docker cp all-2.0.tar.gz         nessus:/nessus/cache/
docker cp all-2.0.tar.gz.sig     nessus:/nessus/cache/
docker cp all-2.0.tar.gz.sha256  nessus:/nessus/cache/
docker exec -it nessus /nessus/update.sh /nessus/cache/all-2.0.tar.gz /nessus/cache/all-2.0.tar.gz.sig
```

Watch progress:

```bash
docker exec -it nessus tail -f /opt/nessus/var/nessus/logs/nessusd.messages
docker exec -it nessus ls -lh  /opt/nessus/var/nessus/plugins-*.db
```

---

## Upgrading the engine

```bash
docker build --build-arg NESSUS_VERSION=10.12.6 -t nessus:10.12.6 .
```

Nothing is hardcoded: the Dockerfile looks up
`Nessus-${NESSUS_VERSION}-ubuntu1604_amd64.deb` in
`https://www.tenable.com/downloads/api/v1/public/pages/nessus`, resolves its download id, then fetches the deb.
The build finishes by asserting that the installed version matches the build arg.

---

## Verified numbers

Host: 4 vCPU / 5.8 GB RAM / Docker, package `all-2.0.tar.gz` (982 MB)

| Item | Value |
|---|---|
| Engine | Nessus **10.12.6** [build R20073] / nasl 19.18.6 |
| Plugin set | `PLUGIN_SET = "202610032324"` / `ProfessionalFeed (Direct)` |
| Files | 346,487 `.nasl` + 3,303 `.nbin` |
| Loaded | `/plugins/families` → 65 families, **347,631** plugins |
| Compile errors | `Unable to compile` **0**, `could not be loaded` **0** |
| Compile time | ~20 minutes including the attributes index |
| Disk | plugins 4.6 GB, DBs 4.6 GB (code 1.8 GB / desc 554 MB / attributes 2.3 GB) |

---

## Layout

```
.
├── Dockerfile            # base image + selected engine version + scripts
├── docker-compose.yml    # one-shot bring-up, plugin tarball cached in a volume
├── deploy.sh             # build / run / optional plugin update
└── scripts
    ├── start.sh          # PID1: rewrite feed -> start nessusd in background -> keep alive
    ├── update.sh         # download / verify / import / wait for compile
    └── fetch-feed.sh     # stall-resistant package downloader (+ sha256)
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Log flooded with `Unable to compile` | Engine and feed are different generations. Raise `NESSUS_VERSION` and rebuild, or use a matching feed |
| `requires its detached signature file` | Missing `.sig`. Use `update.sh`, or pass the signature as the second argument |
| Container runs but 8834 does not answer | Still compiling — `docker exec nessus tail -f /opt/nessus/var/nessus/logs/nessusd.messages` |
| Plugin count is 0 after compile | A leftover `plugin_feed_info.inc` inside the plugin dir overrides the feed info; `start.sh` removes it, just restart the container |
| `dpkg: unable to access dpkg status area` | The base image shipped without `/var/lib/dpkg`; the Dockerfile rebuilds a minimal status area |
| Container disappears mid-update | Entrypoint must stay alive as PID1; never run nessusd as PID 1 (handled here) |
| Disk fills up | Compile artifacts are ~10 GB — check `docker system df` for volumes and dangling images |

---

## Disclaimer

For non-profit study and research only. Do not use it against systems you are not authorized to test.
You are responsible for anything you do with this repository.

## Credits

Thanks to [Adam-Zhong/nessus](https://github.com/Adam-Zhong/nessus) for the original containerization
approach and the base runtime image.
