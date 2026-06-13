# Changelog

All notable changes to the Cosmos Cloud Golden Build installer kit are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
