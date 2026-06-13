# Cosmos Cloud — Golden Build v1.2

**Target system:** Debian GNU/Linux 13 (trixie), kernel 6.12.x or later  
**Cosmos version:** 0.22.19 (built 2026-05-26)  
**Document date:** 2026-06-13  
**Status:** v1.2 complete and validated on reference Debian 13 installation

| Version | Date | Change |
|---|---|---|
| v1.0 | 2026-06-12 | Initial Golden Build — least-privilege media user, /srv consolidation, systemd hardening |
| v1.1 | 2026-06-12 | Add `/srv/cosmos-storage` for Marketplace bind-mount data; fix `DefaultDataPath` |
| v1.2 | 2026-06-13 | Add Docker log rotation to `daemon.json`; cap container log storage to 500 MB per container |

---

## Table of Contents

1. [Architectural Overview](#1-architectural-overview)
2. [User and Permission Model](#2-user-and-permission-model)
3. [Filesystem Layout](#3-filesystem-layout)
4. [Cosmos Configuration Model](#4-cosmos-configuration-model)
5. [Docker Configuration Model](#5-docker-configuration-model)
6. [systemd Hardening Configuration](#6-systemd-hardening-configuration)
7. [Validation Results](#7-validation-results)
8. [Rollback Procedures](#8-rollback-procedures)
9. [Known Limitations](#9-known-limitations)
10. [Phase 2 Considerations](#10-phase-2-considerations)

---

## 1. Architectural Overview

### Design Goals

The Golden Build replaces Cosmos Cloud's default all-root execution model with a least-privilege architecture. The design has three requirements:

1. **Privilege reduction.** Cosmos runs as a dedicated non-root service user with exactly one Linux capability beyond a normal user process.
2. **Storage consolidation.** All persistent application state lives on the dedicated `/srv` volume. No application data lives under `/var`, `/root`, or `/home`.
3. **Upgrade safety.** The `cosmos-launcher` self-update mechanism continues to work without modification. New binaries delivered by the launcher inherit all hardening settings automatically via the systemd unit environment.

### Component Relationships

```
                    ┌─────────────────────────────────────┐
                    │          systemd (PID 1, root)       │
                    │   CosmosCloud.service +              │
                    │   CosmosCloud.service.d/             │
                    │   golden-build.conf                  │
                    └──────────────┬──────────────────────┘
                                   │ forks as user=media
                    ┌──────────────▼──────────────────────┐
                    │    /opt/cosmos/start.sh  (media)     │
                    │    ├── cosmos-launcher               │
                    │    │     downloads new binary to     │
                    │    │     /opt/cosmos/, exits         │
                    │    └── cosmos  (media)               │
                    │          CAP_NET_BIND_SERVICE only   │
                    │          NoNewPrivileges=true        │
                    └──────────────┬──────────────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
   ┌──────────▼──────┐  ┌──────────▼──────┐  ┌─────────▼───────┐
   │ /srv/cosmos/    │  │ /run/docker.sock │  │ :80 / :443      │
   │ config/         │  │ (via docker gid) │  │ (via CAP_NET_   │
   │ (config, db,    │  └─────────────────┘  │  BIND_SERVICE)  │
   │  logs)          │                        └─────────────────┘
   └─────────────────┘
```

### Storage Architecture

The Golden Build requires `/srv` to be a dedicated volume (LVM or otherwise). The example below shows a reference implementation using LVM over LUKS full-disk encryption. Exact device names, volume group names, and sizes will differ on your system.

```
<primary-disk>
└── <encrypted-partition>  [LUKS / crypto_LUKS]
    └── <luks-mapper>  [LVM2]
        ├── <vg>-root   ext4   <size>    /
        ├── <vg>-var    ext4   <size>    /var
        ├── <vg>-swap   swap   <size>    [SWAP]
        └── <vg>-srv    ext4   300+ GB   /srv   ← application data
```

**Minimum recommended `/srv` size:** 50 GB for a small single-user deployment; 300 GB or more for a multi-application server with media storage.

---

## 2. User and Permission Model

### The `media` Service Account

```
media:x:999:986::/home/media:/usr/sbin/nologin
uid=999  gid=986(media)  supplementary: 987(docker)
```

| Property | Value | Rationale |
|---|---|---|
| UID | 999 | System UID range (< 1000), allocated by `useradd --system` |
| Shell | `/usr/sbin/nologin` | No interactive login possible |
| Home directory | `/home/media` | Linux convention only; **ephemeral** — contains no application data |
| Primary group | `media` (GID 986) | Dedicated group; not shared with any other service |
| Supplementary group | `docker` (GID 987) | Required to access `/run/docker.sock` (mode 0660, root:docker) |

**The `/home/media` directory is not part of the persistent application architecture.** It exists because Linux user accounts conventionally have a home directory. Loss or deletion of `/home/media` has no impact on application state. All persistent data lives under `/srv`.

### Creation Command

```bash
useradd \
  --system \
  --create-home \
  --home-dir /home/media \
  --shell /usr/sbin/nologin \
  --user-group \
  media

usermod -aG docker media
```

### Linux Capabilities

Cosmos listens on ports 80 and 443. On Linux, binding to ports below 1024 requires either root or `CAP_NET_BIND_SERVICE`. The Golden Build grants exactly this one capability and no others.

| Capability set | Value | Meaning |
|---|---|---|
| CapInh | `0x0000000000000400` | Inheritable: CAP_NET_BIND_SERVICE (bit 10) |
| CapPrm | `0x0000000000000400` | Permitted: CAP_NET_BIND_SERVICE only |
| CapEff | `0x0000000000000400` | Effective: CAP_NET_BIND_SERVICE only |
| CapBnd | `0x0000000000000400` | Bounding: hard ceiling, all 40 other capabilities absent |
| CapAmb | `0x0000000000000400` | Ambient: inherited across `execve` calls |

**Why ambient rather than file capabilities (`setcap`):** The `cosmos-launcher` binary replaces `/opt/cosmos/cosmos` on updates. A `setcap` attribute on the file would be overwritten by each update, losing the capability silently. Ambient capabilities are granted by the systemd unit to the process tree — new binaries delivered by the launcher inherit them automatically without any post-install step.

**`NoNewPrivileges=true`:** Even though the cosmos binary is owned by `media`, `NoNewPrivileges` prevents any setuid or file-capability escalation by the process or any child it spawns. This applies to binaries delivered by `cosmos-launcher` as well — they cannot acquire capabilities beyond what the unit grants, regardless of their file attributes.

### Honest Security Model Note

**`media` in the `docker` group is functionally root-equivalent for container management purposes.** The Docker socket (`/run/docker.sock`, mode 0660, root:docker) accepts arbitrary Docker API calls. Any process that can write to this socket can start privileged containers, mount host filesystem paths, and escalate to full root access. The security gain of running Cosmos as `media` is:

- Reduced blast radius if the Cosmos *process itself* is compromised (Cosmos's own filesystem access is constrained by `ProtectSystem=strict`, `ReadWritePaths`, and the capability bounding set)
- No reduction in Docker container management privilege

This is an acceptable trade-off for a single-owner home server. It must be understood and not mistaken for full least-privilege isolation.

---

## 3. Filesystem Layout

### `/srv` — Application Data Root

All persistent application data is consolidated under `/srv`. This volume is separate from the OS (`/`) and system runtime (`/var`), so application data survives OS reinstallation and can be snapshotted or backed up independently.

```
/srv/
├── cosmos/                  drwxr-x---  media:media  750
│   └── config/              drwx--x--x  media:media  711
│       ├── cosmos.config.json           media:media  600   (main config, TLS keys, CA)
│       ├── cosmos.log                   media:media  600   (structured log, rotated 15 MB/2 copies)
│       ├── cosmos.plain.log             media:media  600   (plain log, rotated 15 MB/2 copies)
│       ├── database                     media:media  700   (embedded Lungo/MongoDB data file)
│       ├── backup.cosmos-compose.json   media:media  600   (Docker Compose backup state)
│       └── snapraid/        drwx------  media:media  700   (SnapRAID configuration)
│
├── cosmos-storage/          drwxr-xr-x  media:media  755   (Marketplace application bind-mount data)
│   └── {app-name}/          drwxrwxr-x  media:media  750   (per-application, created on install)
│       └── ...
│
├── docker/                  drwx--x---  root:root    710   (Docker data-root)
│   ├── buildkit/
│   ├── containers/                                         (container log files stored here)
│   │   └── {id}/
│   │       ├── {id}-json.log                              (active log, max 100 MB)
│   │       └── {id}-json.log.1                            (rotated log, max 100 MB — up to 5 total)
│   ├── image/
│   ├── network/
│   ├── volumes/
│   └── ...
│
├── media/                   drwxrwxr-x  media:media  775   (media content files)
│
└── backups/                 drwxr-x---  media:media  750   (restic repositories)
```

### `/opt/cosmos` — Binaries

```
/opt/cosmos/                 drwxr-xr-x  media:media  755
├── cosmos                   -rwxr-xr-x  media:media  755   (171 MB — main server binary)
├── cosmos-launcher          -rwxr-xr-x  media:media  755   (42 MB  — self-updater)
├── nebula                   -rwxr-xr-x  media:media  755   (VPN daemon)
├── nebula-cert              -rwxr-xr-x  media:media  755   (VPN cert tool)
├── restic                   -rwxr-xr-x  media:media  755   (backup binary)
├── start.sh                 -rwxr-xr-x  media:media  755   (launcher entrypoint)
├── meta.json                -rw-r--r--  media:media  644   (version metadata)
├── GeoLite2-Country.mmdb    -rw-r--r--  media:media  644   (IP geolocation database)
├── Logo.png                 -rw-r--r--  media:media  644
├── cosmos_gray.png          -rw-r--r--  media:media  644
├── images/                  drwxr-xr-x  media:media  755
└── static/                  drwxr-xr-x  media:media  755   (web UI assets)
```

**Ownership rationale:** `cosmos-launcher` must write new binaries into `/opt/cosmos/`. Owning the directory as `media:media` gives Cosmos write access without requiring root. No world-write bits are set.

### `/home/media` — Ephemeral Service-User State

```
/home/media/                 drwx------  media:media  700
```

Created by `useradd --create-home`. Empty. Contains no application data. Not backed up. Deletion is safe.

### Separation of Concerns

| Data class | Location | Volume | Owner |
|---|---|---|---|
| OS and system services | `/` | `root` LV | root |
| System runtime, `containerd`, old Docker | `/var` | `var` LV | root |
| Cosmos application data | `/srv/cosmos/config/` | `srv` LV | media |
| Marketplace bind-mount data | `/srv/cosmos-storage/` | `srv` LV | media |
| Docker runtime data | `/srv/docker/` | `srv` LV | root |
| Docker container log files | `/srv/docker/containers/` | `srv` LV | root |
| Media content files | `/srv/media/` | `srv` LV | media |
| Backup repositories | `/srv/backups/` | `srv` LV | media |
| Cosmos binaries | `/opt/cosmos/` | `root` LV | media |

---

## 4. Cosmos Configuration Model

### `COSMOS_CONFIG_FOLDER` — Implementation Detail

Cosmos reads the `COSMOS_CONFIG_FOLDER` environment variable in `src/index.go` and assigns it directly to the global `utils.CONFIGFOLDER`. All file paths are then built by **direct string concatenation** with no separator:

```go
// src/utils/utils.go
var CONFIGFOLDER = "/var/lib/cosmos/"   // default always has trailing slash

// src/index.go
if os.Getenv("COSMOS_CONFIG_FOLDER") != "" {
    utils.CONFIGFOLDER = os.Getenv("COSMOS_CONFIG_FOLDER")
}

// File path construction (no filepath.Join, no separator):
configFile = CONFIGFOLDER + "cosmos.config.json"
Filename:   CONFIGFOLDER + "cosmos.log"
Filename:   CONFIGFOLDER + "cosmos.plain.log"
// ...and all other data paths (database, backup.cosmos-compose.json, snapraid/)
```

**Critical:** `COSMOS_CONFIG_FOLDER` must end with a trailing slash. Without it, the path segment after the last `/` becomes a filename prefix rather than a directory name, producing misnamed files (e.g., `/srv/cosmos/configcosmos.config.json` instead of `/srv/cosmos/config/cosmos.config.json`).

**Golden Build value:**
```
COSMOS_CONFIG_FOLDER=/srv/cosmos/config/
```

### `DefaultDataPath` — Marketplace Bind-Mount Base Directory

`DockerConfig.DefaultDataPath` in `cosmos.config.json` controls where Cosmos pre-creates host directories for Marketplace application bind mounts. The default value is `/cosmos-storage`.

**Why the default fails under Golden Build hardening:** Cosmos calls `os.MkdirAll(DefaultDataPath + "/" + subdir, 0750)` directly on the host filesystem. Under `ProtectSystem=strict`, `/` is read-only for the Cosmos process. `/cosmos-storage` is not under any `ReadWritePaths` entry, so `mkdir /cosmos-storage` fails with `read-only file system`.

**Root cause of the upstream default:** The upstream installation runs Cosmos inside a Docker container with the host's root mounted at `/mnt/host`. In that mode, Cosmos prepends `/mnt/host` to the path, writing to `/mnt/host/cosmos-storage/` on the real host. On a bare-metal host installation, no prefix is added and the write goes directly to `/cosmos-storage` — which is inaccessible under `ProtectSystem=strict`.

**There is no environment variable override** for `DefaultDataPath`. It is config-file only.

**Golden Build value:**
```json
"DockerConfig": {
    "DefaultDataPath": "/srv/cosmos-storage"
}
```

**`DefaultDataPath` must NOT end with a trailing slash.** Unlike `COSMOS_CONFIG_FOLDER`, the bind-mount path construction appends a `/`-prefixed suffix directly: `DefaultDataPath + "/appname"`. A trailing slash would produce double-slash paths. `/srv/cosmos-storage` (correct) vs `/srv/cosmos-storage/` (incorrect).

**`/srv/cosmos-storage` must be in `ReadWritePaths`** in the systemd drop-in. Without it, `ProtectSystem=strict` blocks writes even to the correct path.

This is settable via:
- Editing `cosmos.config.json` directly (service must be stopped first)
- The Cosmos web UI: Settings → Docker → Default Data Path
- The `/api/config` PUT endpoint (authenticated)

### How Marketplace Apps Use `DefaultDataPath`

Two mechanisms found in the Cosmos UI bundle (`index-97c240fd.js`):

**Mechanism A — relative volume source substitution:** When a Cosmos-compose YAML defines a volume with a relative source path (starting with `.`), Cosmos rewrites it at install time:

```
source: ./myapp-data  →  /srv/cosmos-storage/myapp-data
```

**Mechanism B — template variable:** `{{DefaultDataPath}}` is available in Marketplace app compose templates and is substituted with the configured value at render time.

Both mechanisms fall back to `/cosmos-storage` if `DefaultDataPath` is unset — which fails under `ProtectSystem=strict`.

### Files Written by Cosmos Under `CONFIGFOLDER`

| Filename | Path | Contents |
|---|---|---|
| `cosmos.config.json` | `/srv/cosmos/config/cosmos.config.json` | Main config: TLS certs, CA keypair, auth keys, proxy routes, all settings |
| `cosmos.log` | `/srv/cosmos/config/cosmos.log` | Structured log (lumberjack, max 15 MB, 2 rotations, 16 days, compressed) |
| `cosmos.plain.log` | `/srv/cosmos/config/cosmos.plain.log` | Plain-text log (same rotation policy) |
| `database` | `/srv/cosmos/config/database` | Embedded Lungo/MongoDB-compatible database (user accounts, sessions, metrics, notifications) |
| `backup.cosmos-compose.json` | `/srv/cosmos/config/backup.cosmos-compose.json` | Docker Compose structure for backup service state |
| `snapraid/` | `/srv/cosmos/config/snapraid/` | SnapRAID configuration directory |

### Cosmos Binary

- **Format:** ELF 64-bit, dynamically linked
- **Dynamic dependencies:** `libc.so.6` only — no other shared libraries
- **Embedded database:** Lungo (MongoDB-wire-compatible, file-backed) — no separate MongoDB container required by default
- **Self-update:** Managed by `cosmos-launcher`, which downloads the new binary to `/opt/cosmos/` and exits before `cosmos` starts

### Installer Lifecycle: Two Supported States

The Golden Build installer distinguishes two system states. Understanding which state applies determines how to interpret installer and validator output.

#### State 1 — Infrastructure provisioned, Cosmos not yet initialized

`cosmos.config.json` does not exist. This is the state of any server after the installer has run but before Cosmos has started for the first time and generated its config.

| Property | Value |
|---|---|
| Infrastructure (media user, /srv layout, daemon.json, drop-in) | Complete |
| `cosmos.config.json` | Does not exist |
| `DefaultDataPath` | Not yet set |
| Installer output | `Golden Build v1.2 infrastructure provisioned — Cosmos initialization pending` |
| Validator output | `RESULT: PENDING` (exits 0 — not a failure) |

**Required action before State 2 is reachable:** Start Cosmos once so it generates `cosmos.config.json`, then run the installer again.

#### State 2 — Fully initialized Golden Build

`cosmos.config.json` exists and `DockerConfig.DefaultDataPath` is `/srv/cosmos-storage`. This is the target operating state.

| Property | Value |
|---|---|
| Infrastructure | Complete |
| `cosmos.config.json` | Present, `DefaultDataPath=/srv/cosmos-storage` |
| Installer output | `All checks passed. Golden Build v1.2 installation complete.` |
| Validator output | `RESULT: PASS` (exits 0) |

#### Two-Pass Sequence (fresh server)

```
[Pass 1]   sudo bash install-cosmos-golden-build-v1.2.sh
               ↳ State 1: infrastructure complete, config pending

[Validate] sudo bash validate-golden-build-v1.2.sh
               ↳ RESULT: PENDING  (correct — not an error)

[First run] sudo systemctl start CosmosCloud
               ↳ Cosmos generates cosmos.config.json with DefaultDataPath=/cosmos-storage

[Pass 2]   sudo bash install-cosmos-golden-build-v1.2.sh
               ↳ Detects wrong DefaultDataPath, stops Cosmos, corrects it, restarts Cosmos
               ↳ State 2: fully initialized

[Validate] sudo bash validate-golden-build-v1.2.sh
               ↳ RESULT: PASS
```

On a server where Cosmos has already been running (migrating an existing installation), State 2 is reachable in a single installer run.

---

## 5. Docker Configuration Model

### `/etc/docker/daemon.json`

```json
{
  "data-root": "/srv/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  }
}
```

#### `data-root`

All Docker runtime state (images, containers, volumes, networks, BuildKit cache) is stored on the `/srv` volume, not under `/var/lib/docker`.

#### `log-driver` and `log-opts` (v1.2)

Docker's default `json-file` driver with no size limits would allow container log files to grow without bound under `/srv/docker/containers/`. On a server running multiple Marketplace applications, a verbose or misbehaving container can exhaust disk space within hours.

**`log-driver: json-file`** is declared explicitly to lock the driver regardless of any future Docker default changes.

**`max-size: 100m`** — Docker rotates the active log file when it reaches 100 MB.

**`max-file: 5`** — Docker retains at most 5 log files per container (the active file plus 4 rotated). When a 6th would be created, the oldest is deleted.

**Maximum log storage per container:** 100 MB × 5 = **500 MB**.  
**Maximum log storage for 10 Marketplace apps:** approximately 5 GB on the `/srv` volume.

These are daemon-level defaults. They apply to every container created without explicit `--log-opt` overrides. All Marketplace apps installed via Cosmos use the daemon defaults — none set per-container log options.

**Behavior for existing containers:** Docker bakes log configuration into a container at creation time. Containers created before this daemon.json change was applied retain their creation-time log config (`Config: {}`). Those containers will not enforce rotation until they are recreated (which happens automatically when Cosmos updates their image to a new version). All containers created after the change inherit the rotation defaults immediately.

### Docker Socket Access

```
/run/docker.sock   srw-rw----  root:docker  0660
```

The `media` user accesses the Docker socket via supplementary group membership (`docker`, GID 987). No direct `root` access is required for Cosmos to manage containers.

### Networking

Docker iptables management is **enabled** (default). Docker manages its own NAT and forwarding rules via iptables. This is the Phase 1 baseline; nftables integration and `iptables=false` are Phase 2 work.

### Storage Driver

Docker uses the `overlayfs` storage driver with cgroup v2 under systemd cgroup management. No manual configuration is needed for this on Debian 13.

### Service Start Order

```
containerd.service → docker.service → CosmosCloud.service
```

All three services must be active before Cosmos can manage containers. The services are started in dependency order; stopping should be done in reverse.

**Note:** The vendor `CosmosCloud.service` unit file does not declare `After=docker.service` or `Requires=docker.service`. This means a Docker daemon restart does **not** cascade a restart of CosmosCloud. Cosmos reconnects to the Docker socket automatically when Docker returns.

---

## 6. systemd Hardening Configuration

### Unit Files

**`/etc/systemd/system/CosmosCloud.service`** — vendor-supplied, **not modified**:

```ini
[Unit]
Description=Cosmos Cloud service
ConditionFileIsExecutable=/opt/cosmos/start.sh

[Service]
StartLimitInterval=10
StartLimitBurst=5
ExecStart=/opt/cosmos/start.sh
WorkingDirectory=/opt/cosmos
Restart=always
RestartSec=2
EnvironmentFile=-/etc/sysconfig/CosmosCloud

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/CosmosCloud.service.d/golden-build.conf`** — drop-in, Golden Build v1.2 configuration (unchanged from v1.1):

```ini
[Service]
User=media
Group=media
SupplementaryGroups=docker
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=COSMOS_CONFIG_FOLDER=/srv/cosmos/config/
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/srv/cosmos /srv/cosmos-storage /opt/cosmos
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
```

### Directive Reference

| Directive | Value | Effect |
|---|---|---|
| `User` / `Group` | `media` | Process runs as UID/GID 999/986 |
| `SupplementaryGroups` | `docker` | Adds GID 987 for `/run/docker.sock` access |
| `AmbientCapabilities` | `CAP_NET_BIND_SERVICE` | Grants capability to process tree via ambient set — survives `execve`, so `cosmos-launcher`-delivered binaries inherit it |
| `CapabilityBoundingSet` | `CAP_NET_BIND_SERVICE` | Hard ceiling: no other capability can ever be acquired, regardless of file attributes on any binary |
| `NoNewPrivileges` | `true` | Disables setuid escalation and file-capability acquisition by all processes in the unit |
| `Environment` | `COSMOS_CONFIG_FOLDER=/srv/cosmos/config/` | Redirects all Cosmos data I/O to `/srv/cosmos/config/` (trailing slash required — see Section 4) |
| `ProtectSystem` | `strict` | Mounts `/`, `/usr`, `/boot` read-only for this unit |
| `ProtectHome` | `true` | Makes `/home`, `/root`, `/run/user` invisible |
| `PrivateTmp` | `true` | Gives the unit a private `/tmp` and `/var/tmp` namespace |
| `ReadWritePaths` | `/srv/cosmos /srv/cosmos-storage /opt/cosmos` | Explicitly restores write access to these three trees within the `ProtectSystem=strict` context. `/srv/cosmos-storage` is required for Marketplace application bind-mount directory creation. |
| `ProtectKernelTunables` | `true` | `/proc/sys`, `/sys` are read-only |
| `ProtectKernelModules` | `true` | Cannot load/unload kernel modules |
| `ProtectControlGroups` | `true` | cgroup filesystem is read-only |
| `RestrictSUIDSGID` | `true` | Cannot create SUID/SGID files |
| `LockPersonality` | `true` | Cannot change execution domain |
| `RestrictRealtime` | `true` | Cannot acquire real-time scheduling priority |

### Why a Drop-in, Not a Modified Unit

The vendor unit file at `/etc/systemd/system/CosmosCloud.service` is managed by the Cosmos installer/updater. Modifying it directly risks having changes overwritten on reinstall. The drop-in directory (`CosmosCloud.service.d/`) is merge-applied by systemd and is never touched by the Cosmos update process.

---

## 7. Validation Results

All checks were performed against the running system.

#### Golden Build v1 checks (baseline) — validated 2026-06-12

| # | Check | Method | Result |
|---|---|---|---|
| V1 | `media` user exists with correct identity | `id media`, `getent passwd media` | PASS — UID 999, GID 986, shell `/usr/sbin/nologin`, member of `docker` |
| V2 | CosmosCloud service active and running as `media` | `systemctl show` + `ps` | PASS — `ActiveState=active SubState=running`, `User=media Group=media SupplementaryGroups=docker` |
| V3 | All capability sets equal `CAP_NET_BIND_SERVICE` only | `/proc/<pid>/status` | PASS — CapInh/CapPrm/CapEff/CapBnd/CapAmb all `0x0000000000000400` |
| V4 | `/srv` layout correct with proper ownership and modes | `ls -la /srv/` | PASS — all directories match specification |
| V5 | `COSMOS_CONFIG_FOLDER` with trailing slash in process environment | `/proc/<pid>/environ` | PASS — `COSMOS_CONFIG_FOLDER=/srv/cosmos/config/` |
| V6 | Docker data-root is `/srv/docker` | `docker info` | PASS — `Docker Root Dir: /srv/docker` |
| V7 | `NoNewPrivileges` enforced | `/proc/<pid>/status` | PASS — `NoNewPrivs: 1` |
| V8 | Docker socket accessible to `media` via group | `sudo -u media docker info` | PASS — `Server Version: 29.x.x` returned |
| V9 | `/opt/cosmos` permissions correct | `ls -la /opt/cosmos/` | PASS — executables 755, data files 644, owned `media:media` |
| V10 | All six CONFIGFOLDER files under `/srv/cosmos/config/` | `find /srv/cosmos` | PASS — `cosmos.config.json`, `cosmos.log`, `cosmos.plain.log`, `database`, `backup.cosmos-compose.json`, `snapraid/` present; root of `/srv/cosmos/` contains only `config/` |
| V11 | Existing config read on start (no fresh generation) | Log output | PASS — `Using config file: /srv/cosmos/config/cosmos.config.json`; config mtime predates service start |
| V12 | TLS certificates valid and in use | Log output | PASS — `TLS certificate exist, starting HTTPS servers`; HTTPS serving on `:443` |
| V13 | Logs written to `/srv/cosmos/config/` post-start | File mtimes | PASS — `cosmos.log` and `cosmos.plain.log` updated after service start |

#### Golden Build v1.1 checks (Marketplace storage) — validated 2026-06-12

| # | Check | Method | Result |
|---|---|---|---|
| V14 | Service active after v1.1 changes | `systemctl is-active CosmosCloud` | PASS — `active` |
| V15 | `DefaultDataPath` is `/srv/cosmos-storage` in live config | `cosmos.config.json` → `DockerConfig.DefaultDataPath` | PASS |
| V16 | `ReadWritePaths` includes `/srv/cosmos-storage` | `systemctl show CosmosCloud --property=ReadWritePaths` | PASS |
| V17 | `media` user can write to `/srv/cosmos-storage` | `sudo -u media touch /srv/cosmos-storage/.probe` | PASS |
| V18 | `/srv/cosmos-storage` is `media:media 755` | `ls -la /srv/` | PASS |
| V19 | Marketplace bind-mount directory creation succeeds | `sudo -u media mkdir -p /srv/cosmos-storage/code-projects` | PASS |
| V20 | `/cosmos-storage` does not exist at root | `ls /cosmos-storage` | PASS — `No such file or directory` |
| V21 | All v1 hardening properties unchanged | `ProtectSystem`, `NoNewPrivileges`, `CapabilityBoundingSet`, `User`, `COSMOS_CONFIG_FOLDER` | PASS — no regressions |

#### Golden Build v1.2 checks (Docker log rotation) — validated 2026-06-13

| # | Check | Method | Result |
|---|---|---|---|
| V22 | `daemon.json` contains log rotation settings and is valid JSON | `cat /etc/docker/daemon.json \| python3 -m json.tool` | PASS — `log-driver: json-file`, `max-size: 100m`, `max-file: 5` |
| V23 | Docker daemon active post-restart | `systemctl is-active docker` | PASS — `active` |
| V24 | Daemon-level logging driver confirmed | `docker info \| grep "Logging Driver"` | PASS — `Logging Driver: json-file` |
| V25 | CosmosCloud uninterrupted by Docker restart | `systemctl status CosmosCloud` | PASS — same PID throughout, continuous uptime (no restart recorded) |
| V26 | `cosmos-mongo-<suffix>` running post-restart, 0 additional restarts | `docker inspect --format '{{.State.Status}} {{.RestartCount}}'` | PASS — `running 0` |
| V27 | New containers inherit daemon log-opts at creation time | `docker run --rm -d alpine ... \| docker inspect --format '{{json .HostConfig.LogConfig}}'` | PASS — `Config: {max-file:5, max-size:100m}` confirmed on test container |

---

## 8. Rollback Procedures

### Full Rollback to Pre-Golden-Build State

If you took a VM or disk snapshot before running the installer, reverting that snapshot is the fastest rollback. All procedures below assume no snapshot is available and a full manual rollback is needed.

**Estimated time: 10 minutes.**

#### Step 1 — Stop services

```bash
sudo systemctl stop CosmosCloud docker containerd
```

#### Step 2 — Remove the systemd drop-in

```bash
sudo rm /etc/systemd/system/CosmosCloud.service.d/golden-build.conf
sudo rmdir /etc/systemd/system/CosmosCloud.service.d
sudo systemctl daemon-reload
```

#### Step 3 — Restore Docker data-root to default

```bash
sudo rm /etc/docker/daemon.json
```

Docker will revert to `/var/lib/docker` on next start. Any images/containers pulled while on `/srv/docker` will not be visible until either:
- moved: `sudo mv /srv/docker/* /var/lib/docker/` (requires stopping dockerd first), or
- accepted as lost (containers were empty at Golden Build time).

#### Step 4 — Restore `/opt/cosmos` ownership to root

```bash
sudo chown -R root:root /opt/cosmos
```

#### Step 5 — Restore Cosmos config to original location

The original default was `/var/lib/cosmos/`. If reverting to that path:

```bash
sudo mkdir -p /var/lib/cosmos
sudo cp -a /srv/cosmos/config/* /var/lib/cosmos/
```

The unset `COSMOS_CONFIG_FOLDER` causes Cosmos to fall back to `/var/lib/cosmos/`. No environment variable needs to be set.

#### Step 6 — Remove the `media` user (optional)

```bash
sudo userdel -r media
```

This removes `/home/media`. The `/srv/cosmos`, `/srv/backups`, `/srv/media` directories and their contents are **not** removed by `userdel` and must be handled separately if desired.

#### Step 7 — Restart services

```bash
sudo systemctl start containerd docker CosmosCloud
```

Verify Cosmos starts and its process is owned by root: `ps aux | grep cosmos`

---

### Partial Rollback: v1.2 Changes Only (Docker Log Rotation)

If the log rotation settings need to be reverted while keeping v1.1 intact:

```bash
# Restore daemon.json to v1.1 state (data-root only)
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "data-root": "/srv/docker"
}
EOF

# Validate JSON
cat /etc/docker/daemon.json | python3 -m json.tool

# Restart Docker (brief downtime for cosmos-mongo)
sudo systemctl restart docker

# Verify
sudo docker ps
sudo systemctl status CosmosCloud --no-pager | head -8
```

After rollback, container logs are once again unbounded. Existing rotated log files (if any) remain on disk and are harmless — they can be deleted manually. No Cosmos configuration, data volumes, or bind mounts are affected.

---

### Partial Rollback: v1.1 Changes Only (DefaultDataPath + cosmos-storage)

If the v1.1 changes need to be reverted while keeping v1 intact:

```bash
sudo systemctl stop CosmosCloud

# Revert DefaultDataPath in config
sudo python3 -c "
import json
path = '/srv/cosmos/config/cosmos.config.json'
with open(path) as f:
    c = json.load(f)
c['DockerConfig']['DefaultDataPath'] = '/cosmos-storage'
with open(path, 'w') as f:
    json.dump(c, f, indent=2)
print('Reverted DefaultDataPath to /cosmos-storage')
"

# Revert ReadWritePaths in drop-in
sudo sed -i 's|ReadWritePaths=/srv/cosmos /srv/cosmos-storage /opt/cosmos|ReadWritePaths=/srv/cosmos /opt/cosmos|' \
  /etc/systemd/system/CosmosCloud.service.d/golden-build.conf

sudo systemctl daemon-reload
sudo systemctl start CosmosCloud
```

After rollback, Marketplace installations will fail again with `read-only file system` until this change is reapplied.

### Partial Rollback: CONFIGFOLDER Only

If Cosmos fails due to the CONFIGFOLDER path and a config reset is needed:

```bash
sudo systemctl stop CosmosCloud
# Rename files back to the prefixed form (if reverting the trailing slash)
sudo mv /srv/cosmos/config/cosmos.config.json /srv/cosmos/configcosmos.config.json
sudo mv /srv/cosmos/config/cosmos.log /srv/cosmos/configcosmos.log
sudo mv /srv/cosmos/config/cosmos.plain.log /srv/cosmos/configcosmos.plain.log
sudo mv /srv/cosmos/config/database /srv/cosmos/configdatabase
sudo mv /srv/cosmos/config/backup.cosmos-compose.json /srv/cosmos/configbackup.cosmos-compose.json
sudo mv /srv/cosmos/config/snapraid /srv/cosmos/configsnapraid
# Remove trailing slash from drop-in
sudo sed -i 's|/srv/cosmos/config/$|/srv/cosmos/config|' \
  /etc/systemd/system/CosmosCloud.service.d/golden-build.conf
sudo systemctl daemon-reload
sudo systemctl start CosmosCloud
```

---

## 9. Known Limitations

### 9.1 `ProtectSystem=strict` and Docker Container Operations

`ProtectSystem=strict` makes most of the filesystem read-only for the Cosmos process. The explicit `ReadWritePaths=/srv/cosmos /srv/cosmos-storage /opt/cosmos` restores write access to those three trees only. Docker's container operations use `/srv/docker` (owned and written by the Docker daemon as root), not by the Cosmos process directly. This works correctly; however, if Cosmos is extended to write to paths outside these three trees, `ReadWritePaths` must be updated.

**Note (v1.1):** The default `DefaultDataPath` of `/cosmos-storage` is incompatible with `ProtectSystem=strict` on a bare-metal host installation. The Golden Build sets `DefaultDataPath=/srv/cosmos-storage` to resolve this. Any future reinstallation must apply this config change before attempting Marketplace app installation — it is not applied automatically by the Cosmos installer.

### 9.2 Docker iptables and nftables Coexistence

Docker manages firewall rules via legacy `iptables`. Debian 13 defaults to `nftables` for the system firewall. In the current Phase 1 configuration, Docker's iptables rules coexist with nftables but they are in separate rule tables. This is functional but not clean — iptables-managed rules are not visible in `nft list ruleset`. Phase 2 addresses this.

### 9.3 Samba Runs as Root

`smbd`, `nmbd`, and `winbindd` continue to run as root with no hardening. This was explicitly out of scope for Phase 1.

### 9.4 No Seccomp Profile

The Cosmos process has no seccomp filter applied. All system calls are available (constrained only by `NoNewPrivileges` and the capability bounding set). A custom seccomp profile would require profiling the full set of syscalls used by Cosmos including Docker management operations.

### 9.5 Docker Container Isolation is Default

Containers launched by Cosmos run with Docker's default isolation (no user namespace remapping, no seccomp-profile override, default capabilities). Container workloads are not covered by the media user's least-privilege model.

### 9.6 `cosmos-launcher` Runs Briefly as `media`

The launcher runs before `cosmos`, downloads the new binary to `/opt/cosmos/`, and exits. During this window it has the same capability set as `cosmos` (CAP_NET_BIND_SERVICE) and could in principle make outbound connections. This is the intended behaviour of the update mechanism and is not a regression from the original all-root model.

### 9.7 Embedded Database Has No Encryption at Rest

The Lungo/MongoDB-compatible database at `/srv/cosmos/config/database` is a plain binary file. It is protected by filesystem permissions (mode 700, `media:media`) and by LUKS full-disk encryption at the block device layer. There is no additional application-layer encryption on the database file itself.

### 9.8 `cosmos-launcher` Self-Updater Mounts `/var/run/docker.sock`

The cosmos-launcher self-updater starts a container with `-v /var/run/docker.sock:/var/run/docker.sock`. This is the only container in the Golden Build stack that mounts the Docker socket. It is required for the self-update mechanism to function. This is a known exception to any future "no containers mount the Docker socket" hardening policy.

### 9.9 Existing Containers Do Not Retroactively Inherit Log Rotation (v1.2)

Docker bakes log configuration into a container at creation time. Containers created before `daemon.json` included `log-opts` (the mongo container created at initial v1.1 setup) retain their creation-time config and will not enforce the 100 MB rotation limit until they are recreated. Recreation happens automatically when Cosmos updates the container to a new image version. All containers created after the v1.2 `daemon.json` change inherit log rotation at creation time.

---

## 10. Phase 2 Considerations

The following items were deliberately deferred from Phase 1. They should be evaluated in order of risk reduction.

### 10.1 nftables Integration

**Goal:** Replace split iptables/nftables management with a unified nftables ruleset.

**Approach:**
1. Set `"iptables": false` in `/etc/docker/daemon.json`.
2. Write explicit nftables rules to replicate Docker's NAT and forwarding behaviour (`DOCKER` chain semantics, `MASQUERADE` for outbound container traffic, per-published-port DNAT rules).
3. Enable nftables service and disable `iptables-legacy`.

**Risk:** Container networking breaks entirely if nftables rules are incorrect. Test on a dedicated server or VM before applying to production.

### 10.2 Samba Hardening

**Goal:** Run `smbd`/`nmbd` as a dedicated non-root user with a systemd drop-in similar to the Cosmos pattern.

**Approach:** Create a `samba` system user, use `User=` in a drop-in, and set `CapabilityBoundingSet` to the minimum required by Samba (typically `CAP_NET_BIND_SERVICE` for port 445 and `CAP_DAC_READ_SEARCH` if sharing root-owned paths).

### 10.3 Docker Rootless Evaluation

**Goal:** Assess whether Docker can run in rootless mode (entirely within the `media` user namespace) without breaking Cosmos functionality.

**Findings from prior investigation:** All kernel prerequisites are met (CONFIG_USER_NS, overlayfs in user ns on kernel 6.12). Primary blockers: `media` has no `/etc/subuid`/`/etc/subgid` entries; `cosmos-launcher` self-updater hardcodes `/var/run/docker.sock` in its container bind mount; all existing Docker volumes require migration. **Recommendation: test on a dedicated environment only before applying to production.**

### 10.4 Container Isolation Hardening

**Goal:** Apply least-privilege constraints to containers launched by Cosmos.

**Approach:**
- Enable user namespace remapping in Docker (`userns-remap` in `daemon.json`).
- Apply a default seccomp profile to containers.
- Restrict container capabilities via a Cosmos-side default policy.

**Dependency:** Requires Phase 10.1 (nftables) to be stable first, as user namespace remapping changes Docker's iptables/nftables rule structure.

### 10.5 Seccomp Profile for Cosmos

**Goal:** Restrict Cosmos to the minimum set of Linux system calls it actually uses.

**Approach:** Run Cosmos under `strace -f` or use `systemd-seccomp` profiling for a representative workload (startup, proxy operations, container management, backup). Build a whitelist profile and apply it via `SystemCallFilter=` in the drop-in.

**Effort:** High. Requires comprehensive workload coverage to avoid false denials.

### 10.6 Log Shipping

**Goal:** Centralise logs off the server before log rotation removes them.

**Current state (v1.2):** Docker container logs are now bounded at 500 MB per container (100m × 5 files) via daemon-level rotation. Cosmos application logs (`cosmos.log`, `cosmos.plain.log`) are bounded by lumberjack at 15 MB × 2 copies × 16 days. Both provide a defined but narrow retention window — sufficient for debugging recent issues but not for audit or long-term analysis.

**Approach:** Forward `/srv/cosmos/config/cosmos.plain.log` to a syslog aggregator or object store using a `systemd` journal forwarder or a lightweight agent (`vector`, `promtail`). Consider shipping Docker container logs via a fluentd or journald log driver if long-term container log history is required.

### 10.7 Backup Policy for `/srv/cosmos/config/` and `/srv/cosmos-storage/`

**Goal:** Establish a restic backup job for Cosmos application state and Marketplace application data.

**Scope:**
- `/srv/cosmos/config/` — specifically `cosmos.config.json` and `database`. Logs can be excluded.
- `/srv/cosmos-storage/` — all Marketplace application bind-mount data. This is the persistent state of every installed application (databases, uploads, configuration). Omitting it means application data is unprotected.

**Restic binary:** Already present at `/opt/cosmos/restic` (26 MB, version embedded in Cosmos). A cron or systemd timer can invoke it directly as the `media` user, writing repositories to `/srv/backups/`.

**Note:** `cosmos.config.json` contains TLS private keys and the CA private key. The backup repository must be encrypted (restic encrypts by default) and the repository password stored securely off-server.

---

*End of Golden Build v1.2 documentation.*
