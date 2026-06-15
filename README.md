# Cosmos Cloud — Golden Build v1.2.2

A hardened, least-privilege deployment kit for [Cosmos Cloud](https://cosmos-cloud.io)
on Debian GNU/Linux 13 (trixie).

> **v1.2.2** formalises `media` UID/GID as **1001:1001**. Fresh installations use
> explicit `--uid 1001 --gid 1001`; the installer provides migration guidance for
> existing deployments with other UID/GID values. The validator now reports `PASS`
> (not `WARN`) for 1001:1001. MongoDB volume ownership (`999:999`) is unchanged and
> documented as an invariant that must not be forcibly altered.
> See [CHANGELOG](CHANGELOG.md) for details.

> **Disclaimer:** This project is an independent community hardening kit.
> It is not affiliated with, endorsed by, or supported by the Cosmos Cloud project.
> All Cosmos Cloud trademarks belong to their respective owners.

---

## What is the Golden Build?

Cosmos Cloud's default installation runs as `root`. The Golden Build replaces that
with a least-privilege architecture:

- Cosmos runs as a dedicated `media` service account (non-root, no login shell)
- All application data lives on a dedicated `/srv` volume — not under `/var` or `/root`
- Docker log rotation prevents unbounded disk growth
- systemd unit hardening scopes what the process can read, write, and do

The installer is **idempotent** — safe to run multiple times. It applies only the
changes where the current system state diverges from the specification.

---

## Supported Versions

| Component | Tested version |
|---|---|
| OS | Debian GNU/Linux 13 (trixie) |
| Kernel | 6.12.x |
| Docker CE | 29.x |
| Cosmos Cloud | 0.22.x |

Other Debian 13 configurations should work. Other distributions are not tested.

---

## Target Architecture

| Property | Value |
|---|---|
| Cosmos runs as | `media` (UID=1001, GID=1001, `nologin`) |
| Docker socket access | `media` via `docker` group membership |
| Docker data-root | `/srv/docker` |
| Docker log rotation | `json-file`, `max-size=100m`, `max-file=5` (500 MB per container) |
| Cosmos config dir | `/srv/cosmos/config/` |
| Marketplace app data | `/srv/cosmos-storage/` |
| Media files | `/srv/media/` |
| Backup destination | `/srv/backups/` |
| Cosmos binaries | `/opt/cosmos/` (owned by `media` for self-update) |
| systemd hardening | `ProtectSystem=strict`, `NoNewPrivileges=true`, `CAP_NET_BIND_SERVICE` only |

---

## Repository Layout

```
cosmos-golden-build/
├── scripts/
│   ├── install-cosmos-golden-build-v1.2.2.sh  # Main installer (idempotent)
│   ├── validate-golden-build-v1.2.2.sh         # Validator (read-only)
│   └── rollback-golden-build-v1.2.sh           # Rollback to pre-install state
├── docs/
│   └── golden-build-v1.2.2.md                  # Full architectural reference
├── examples/
│   ├── daemon.json.example                     # Reference Docker daemon config
│   └── golden-build.conf.example               # Reference systemd drop-in
├── CHANGELOG.md
├── LICENSE
└── README.md
```

---

## Prerequisites

Before running the installer the target server must have:

- **Debian 13 (trixie)**
- **Docker CE** installed and running — `apt-get install docker-ce`
- **Cosmos Cloud** installed — the `CosmosCloud.service` unit file must exist
- **python3** installed — standard on Debian 13
- **A dedicated `/srv` volume** — strongly recommended (LVM or otherwise); the
  installer warns if absent but does not enforce
- **Root access** — `sudo`

The installer does **not** install Docker or Cosmos. It configures them.

---

## Quick Start (existing Cosmos installation)

If Cosmos has already started at least once and `cosmos.config.json` exists,
a single run is all you need:

```bash
# 1. Install
sudo bash scripts/install-cosmos-golden-build-v1.2.2.sh

# 2. Validate
sudo bash scripts/validate-golden-build-v1.2.2.sh

# 3. Rollback if needed
sudo bash scripts/rollback-golden-build-v1.2.sh
```

---

## Fresh Install Workflow (two-pass)

On a server where Cosmos has **never started**, `cosmos.config.json` does not
exist yet. The installer cannot set `DefaultDataPath` until Cosmos generates
that file on first startup. Two passes are required.

### Pass 1 — Provision infrastructure

```bash
sudo bash scripts/install-cosmos-golden-build-v1.2.2.sh
```

Provisions the `media` user, `/srv` layout, `daemon.json`, and the systemd
drop-in. Reports:

> **Golden Build v1.2.1 infrastructure provisioned — Cosmos initialization pending.**

This is expected and correct — not an error. Running the validator at this
point reports `RESULT: PENDING` (exits 0).

### Pass 2 — After Cosmos first startup

1. Start Cosmos and open the web UI to complete initial setup:

   ```bash
   sudo systemctl start CosmosCloud
   ```

   Cosmos generates `cosmos.config.json` with `DefaultDataPath=/cosmos-storage`
   (the upstream default, which will not work under `ProtectSystem=strict`).

2. Run the installer again:

   ```bash
   sudo bash scripts/install-cosmos-golden-build-v1.2.2.sh
   ```

   The installer detects the wrong `DefaultDataPath`, stops Cosmos briefly,
   corrects it to `/srv/cosmos-storage`, and restarts Cosmos.

3. Confirm everything passes:

   ```bash
   sudo bash scripts/validate-golden-build-v1.2.2.sh
   # Expected: RESULT: PASS
   ```

---

## Validation

The validator checks live system state — not just file contents:

```bash
sudo bash scripts/validate-golden-build-v1.2.2.sh
```

**Output states:**

| Result | Meaning |
|---|---|
| `RESULT: PASS` | System fully matches Golden Build v1.2.1 |
| `RESULT: PENDING` | Infrastructure in place; Cosmos initialization required (run Pass 2) |
| `RESULT: FAIL` | One or more checks failed; review output for details |

Checked properties include: `media` user/group membership, Docker data-root,
log rotation settings, `/srv` directory ownership and modes, systemd drop-in
directives, live process user, `COSMOS_CONFIG_FOLDER` environment, capability
sets, `NoNewPrivileges`, and `DefaultDataPath`.

---

## Rollback

The installer creates timestamped backups in `/root/golden-build-backups/`
before modifying any file. The rollback script restores from those backups:

```bash
sudo bash scripts/rollback-golden-build-v1.2.sh
```

The rollback script is compatible with both v1.2 and v1.2.1 installations —
the rollback procedure is architecturally identical. It does **not** delete
`/srv` data or the `media` user.

---

## Important Security Notes

### docker group = effectively root

The `media` user is a member of the `docker` group. Any process that can write
to `/run/docker.sock` can start privileged containers and escalate to full root
access. The security gain of this architecture is a reduced blast radius if the
Cosmos *process itself* is compromised — not full Docker isolation.

This is a documented and accepted trade-off for a personal server context.
See `docs/golden-build-v1.2.2.md` Section 2 for the full security model.

### COSMOS_CONFIG_FOLDER requires a trailing slash

`COSMOS_CONFIG_FOLDER=/srv/cosmos/config/` — the trailing slash is mandatory.
Cosmos uses direct string concatenation for all internal path construction.
Without the slash, file paths are misnamed and Cosmos will fail to start.

### DefaultDataPath must NOT have a trailing slash

`DockerConfig.DefaultDataPath` in `cosmos.config.json` must be
`/srv/cosmos-storage` with no trailing slash. The installer sets this
automatically.

### Existing Docker data

If Docker is already using `/var/lib/docker`, changing `data-root` to
`/srv/docker` makes existing containers and volumes invisible to Docker.
They remain on disk — they are not deleted. The installer warns before
making this change. Cosmos automatically recreates `cosmos-mongo` on next
startup.

---

## What the Installer Does NOT Do

- Install Docker, Cosmos, or any package
- Migrate Docker data from `/var/lib/docker` to `/srv/docker`
- Modify Samba, nftables, or firewall rules
- Enable rootless Docker
- Delete or overwrite `/srv` data without a backup

---

## Backups

The installer creates timestamped backups in `/root/golden-build-backups/`
before modifying any existing file:

```
/root/golden-build-backups/
├── daemon.json.YYYYMMDD-HHMMSS.bak
├── golden-build.conf.YYYYMMDD-HHMMSS.bak
└── cosmos.config.json.YYYYMMDD-HHMMSS.bak
```

Backups are never deleted automatically.

---

## Full Documentation

Architecture, design rationale, validation results, and rollback procedures are
documented in [`docs/golden-build-v1.2.2.md`](docs/golden-build-v1.2.2.md).

---

## License

MIT — see [LICENSE](LICENSE).
