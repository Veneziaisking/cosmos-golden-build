# Changelog

All notable changes to the Cosmos Cloud Golden Build installer kit are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.2.2] — 2026-06-15

### Changed

- **Canonical `media` UID/GID is now 1001:1001.** Fresh installations create the
  `media` user with `--uid 1001 --gid 1001` rather than `useradd --system`.
  The kernel treats both equally; the fixed value ensures reproducibility across
  deployments. See `docs/golden-build-v1.2.2.md` Section 2 for rationale.

- **Validator Section 1 updated:** `PASS` when `media` is 1001:1001 (canonical).
  `FAIL` only when `media` is root (UID=0). `WARN` for any other non-root UID/GID
  (system is functional but not at canonical values — e.g. pre-migration state).
  Previously the v1.2.1 validator issued a `WARN` for UID ≥ 1000; v1.2.2 promotes
  1001:1001 to `PASS` and keeps the `WARN` for other non-root UIDs.

### Added

- **Installer UID migration guidance (Phase 2):** When `media` exists with a
  UID/GID other than 1001:1001, the installer prints a step-by-step migration
  procedure (stop services → groupmod → usermod → rechown → restart) and exits
  without modifying the account. It does not silently change an existing UID or GID.

- **Section 9.11 (documentation):** Documents why `cosmos-mongo` volumes remain
  `999:999` and must never be forcibly rechowned:
  - The `mongo:8` entrypoint starts as root and unconditionally rechowns
    `/data/db` and `/data/configdb` to the container-internal `mongodb` user
    (UID 999) on every start. Any host-side ownership change is silently
    reverted on the next container restart.
  - Host UID 999 has no account and GID 999 (`systemd-journal`) has no
    filesystem access to these paths outside of Docker volume mounts.
  - The migration `find` scope (`/srv/cosmos`, `/srv/cosmos-storage`,
    `/srv/media`, `/srv/backups`, `/opt/cosmos`, `/home/media`) explicitly
    excludes `/srv/docker`, preventing any accidental rechown of MongoDB data.

---

## [1.2.1] — 2026-06-15

### Fixed

- **Installer startup race (Phase 7):** CosmosCloud is now explicitly stopped
  before Docker is restarted, eliminating the window where `Restart=always` could
  auto-start Cosmos before the systemd drop-in `COSMOS_CONFIG_FOLDER` setting was
  guaranteed active. The corrected sequence is:
  `stop CosmosCloud → daemon-reload → restart Docker → start CosmosCloud`.
  Previously, Cosmos could start during the Docker restart window using the
  compiled-in default `/var/lib/cosmos/`, leaving orphan files at that path.
  On systems installed with v1.2, `/var/lib/cosmos` is a safe-to-remove artifact.

### Added

- **Phase 9 — Orphan Artifact Check (installer):** After completing Phase 8
  validation, the installer now inspects `/var/lib/cosmos` and `/var/lib/docker`
  and reports their status: WARN (inactive; safe to remove) or FAIL (active file
  descriptors detected). When both are inactive, the installer prints exact
  `rm -rf` commands to clean them up.

- **Section 9 — Orphan Artifact Check (validator):** `validate-golden-build-v1.2.1.sh`
  includes a new check section for `/var/lib/cosmos` and `/var/lib/docker`:
  - **PASS** if the path does not exist.
  - **WARN** if the path exists with no open file descriptors (inactive orphan artifact).
  - **FAIL** if the path exists with open file descriptors (active use — do not remove).
  The validator does not fail on the mere presence of these paths, distinguishing
  inactive orphan artifacts from active state.

- **Section 9.10 (documentation):** `docs/golden-build-v1.2.1.md` documents the
  root cause of both orphan artifacts, the v1.2.1 fix, safe-removal procedure, and
  confirmation that neither path reappears after removal when `daemon.json` is in place.

---

## [1.2] — 2026-06-13

### Added
- **Docker log rotation** via `daemon.json`: `json-file` driver, `max-size=100m`,
  `max-file=5` (500 MB maximum per container across all log files).
- **Two-pass installer flow** with explicit `COSMOS_INIT_PENDING` state tracking.
  When `cosmos.config.json` does not yet exist the installer reports
  *"infrastructure provisioned — Cosmos initialization pending"* and exits cleanly.
- **Validator `RESULT: PENDING` output** — distinguishes a correctly provisioned
  but not-yet-initialized system from an actual failure.
- **`scripts/`** and **`docs/`** directory layout for the public repository.
- **`examples/`** directory: `daemon.json.example` and `golden-build.conf.example`.

### Changed
- `/srv/docker` canonical permission mode updated to `710` (`root:root drwx--x---`),
  matching what the Docker daemon sets on restart.

### Fixed
- **Drop-in idempotency** (`printf '%s\n'` → `printf '%s'`): the previous form wrote
  a double trailing newline, causing the idempotency comparison to fail on every
  re-run. This fired an unnecessary `daemon-reload` and `systemctl restart
  CosmosCloud` on each execution even when nothing had changed.
- **Rollback `rmdir` abort risk**: added `|| true` to `rmdir "${DROPIN_DIR}"`.
  Under `set -euo pipefail` a non-empty directory at that point would abort the
  rollback script before restoring `daemon.json` and restarting Docker, leaving
  the system in a partially rolled-back state.

---

## [1.1] — 2026-06-12

### Added
- `/srv/cosmos-storage/` directory for Cosmos Marketplace application bind-mount data.
- Automatic correction of `DockerConfig.DefaultDataPath` to `/srv/cosmos-storage`
  in `cosmos.config.json`.
- `ReadWritePaths=/srv/cosmos-storage` added to the systemd drop-in — required for
  `ProtectSystem=strict` to allow Cosmos to create bind-mount directories for
  Marketplace apps.
- Full documentation of the `DefaultDataPath` upstream default incompatibility
  with `ProtectSystem=strict` on bare-metal host installations.

---

## [1.0] — 2026-06-12

### Added
- Initial Golden Build architecture for running Cosmos Cloud as a non-root service
  user on Debian GNU/Linux 13.
- `media` system service account: `nologin` shell, `docker` group membership,
  system UID range.
- `/srv` directory layout: `cosmos/`, `cosmos/config/`, `cosmos-storage/`,
  `media/`, `backups/`, `docker/`.
- Docker `data-root` moved to `/srv/docker` via `daemon.json`.
- systemd hardening drop-in (`CosmosCloud.service.d/golden-build.conf`):
  - `User=media`, `Group=media`, `SupplementaryGroups=docker`
  - `AmbientCapabilities=CAP_NET_BIND_SERVICE` (survives `cosmos-launcher`
    binary replacement — new binaries inherit the capability automatically)
  - `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`
  - `NoNewPrivileges=true`
  - `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`
  - `ReadWritePaths=/srv/cosmos /srv/cosmos-storage /opt/cosmos`
  - `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`,
    `RestrictSUIDSGID`, `LockPersonality`, `RestrictRealtime`
- `/opt/cosmos/` ownership transferred to `media:media` — required for
  `cosmos-launcher` self-update write access.
- Idempotent installer, validator, and rollback scripts.
- Full architectural documentation (`docs/golden-build-v1.2.md`).
