#!/usr/bin/env bash
# =============================================================================
# Cosmos Cloud — Golden Build v1.2 Rollback Script
#
# Restores the system to its pre-Golden Build state by reversing the changes
# made by install-cosmos-golden-build-v1.2.sh.
#
# What this script does:
#   1. Locates the most recent backup set in /root/golden-build-backups/
#   2. Restores /etc/docker/daemon.json from backup (or removes it if none)
#   3. Removes the CosmosCloud systemd hardening drop-in (or restores backup)
#   4. Restores cosmos.config.json from backup if one exists
#   5. Reloads systemd and restarts Docker
#   6. Reports the final state
#
# What this script does NOT do:
#   - Delete /srv/cosmos, /srv/cosmos-storage, /srv/media, or /srv/backups
#   - Remove the media user
#   - Migrate Docker data from /srv/docker back to /var/lib/docker
#   - Make any network or firewall changes
#
# Usage: sudo bash rollback-golden-build-v1.2.sh
# =============================================================================
set -euo pipefail

readonly BACKUP_DIR="/root/golden-build-backups"
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly DROPIN_DIR="/etc/systemd/system/CosmosCloud.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/golden-build.conf"
readonly COSMOS_CONFIG_FILE="/srv/cosmos/config/cosmos.config.json"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[DONE]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
step()  { printf "\n${BOLD}━━━ %s ━━━${NC}\n" "$*"; }
die()   { printf "${RED}[FATAL]${NC} %s\n" "$*" >&2; exit 1; }

# =============================================================================
# ROOT CHECK
# =============================================================================
if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root.  Try: sudo bash $(basename "$0")"
fi

printf "\n${BOLD}Cosmos Cloud — Golden Build v1.2 Rollback${NC}\n\n"

# =============================================================================
# LOCATE BACKUPS
# =============================================================================
step "Locating Backups"

if [[ ! -d "${BACKUP_DIR}" ]]; then
    die "Backup directory not found: ${BACKUP_DIR}"
    die "Has install-cosmos-golden-build-v1.2.sh been run?"
fi

# Find the most recent backup timestamp that has at least one file
LATEST_TS=""
for bak_file in "${BACKUP_DIR}"/*.bak; do
    [[ -f "${bak_file}" ]] || continue
    # Extract timestamp from filename pattern: name.YYYYMMDD-HHMMSS.bak
    ts="$(basename "${bak_file}" | grep -oE '[0-9]{8}-[0-9]{6}' || true)"
    if [[ -n "${ts}" ]]; then
        # Keep the lexicographically greatest (most recent) timestamp
        if [[ "${ts}" > "${LATEST_TS}" ]]; then
            LATEST_TS="${ts}"
        fi
    fi
done

if [[ -z "${LATEST_TS}" ]]; then
    warn "No timestamped backup files found in ${BACKUP_DIR}"
    warn "Will attempt rollback by removing installed files rather than restoring"
else
    info "Most recent backup set: ${LATEST_TS}"
    ls -lh "${BACKUP_DIR}"/*.bak 2>/dev/null | grep "${LATEST_TS}" || true
fi

# =============================================================================
# STOP COSMOSCLOUD
# =============================================================================
step "Stopping CosmosCloud"

COSMOS_WAS_RUNNING=false
if systemctl is-active --quiet CosmosCloud 2>/dev/null; then
    info "Stopping CosmosCloud..."
    systemctl stop CosmosCloud
    COSMOS_WAS_RUNNING=true
    ok "CosmosCloud stopped"
else
    info "CosmosCloud is not running — nothing to stop"
fi

# =============================================================================
# RESTORE COSMOS.CONFIG.JSON
# =============================================================================
step "Cosmos Configuration (cosmos.config.json)"

COSMOS_BAK=""
if [[ -n "${LATEST_TS}" ]]; then
    COSMOS_BAK="${BACKUP_DIR}/cosmos.config.json.${LATEST_TS}.bak"
fi

if [[ -n "${COSMOS_BAK}" && -f "${COSMOS_BAK}" ]]; then
    if [[ -f "${COSMOS_CONFIG_FILE}" ]]; then
        cp "${COSMOS_CONFIG_FILE}" "${COSMOS_CONFIG_FILE}.before-rollback"
        info "Saved current config to ${COSMOS_CONFIG_FILE}.before-rollback"
    fi
    cp "${COSMOS_BAK}" "${COSMOS_CONFIG_FILE}"
    chown media:media "${COSMOS_CONFIG_FILE}" 2>/dev/null || true
    ok "Restored cosmos.config.json from ${COSMOS_BAK}"
elif [[ -f "${COSMOS_CONFIG_FILE}" ]]; then
    warn "No cosmos.config.json backup found for timestamp ${LATEST_TS:-none}"
    warn "cosmos.config.json will not be modified — DefaultDataPath may still be /srv/cosmos-storage"
    warn "You can manually revert DefaultDataPath through the Cosmos UI if needed"
else
    info "No cosmos.config.json exists — nothing to restore"
fi

# =============================================================================
# RESTORE SYSTEMD DROP-IN
# =============================================================================
step "systemd Hardening Drop-in"

DROPIN_BAK=""
if [[ -n "${LATEST_TS}" ]]; then
    DROPIN_BAK="${BACKUP_DIR}/golden-build.conf.${LATEST_TS}.bak"
fi

if [[ -f "${DROPIN_FILE}" ]]; then
    if [[ -n "${DROPIN_BAK}" && -f "${DROPIN_BAK}" ]]; then
        cp "${DROPIN_BAK}" "${DROPIN_FILE}"
        ok "Restored drop-in from ${DROPIN_BAK}"
    else
        rm -f "${DROPIN_FILE}"
        ok "Removed ${DROPIN_FILE} (no backup to restore — drop-in was created fresh)"
    fi

    # Remove directory if empty
    if [[ -d "${DROPIN_DIR}" ]] && [[ -z "$(ls -A "${DROPIN_DIR}" 2>/dev/null)" ]]; then
        rmdir "${DROPIN_DIR}" || true
        ok "Removed empty drop-in directory ${DROPIN_DIR}"
    fi
else
    info "Drop-in file does not exist — nothing to remove"
fi

info "Reloading systemd..."
systemctl daemon-reload
ok "systemd reloaded"

# =============================================================================
# RESTORE DOCKER DAEMON.JSON
# =============================================================================
step "Docker daemon.json"

DAEMON_BAK=""
if [[ -n "${LATEST_TS}" ]]; then
    DAEMON_BAK="${BACKUP_DIR}/daemon.json.${LATEST_TS}.bak"
fi

if [[ -n "${DAEMON_BAK}" && -f "${DAEMON_BAK}" ]]; then
    cp "${DAEMON_BAK}" "${DOCKER_DAEMON_JSON}"
    ok "Restored daemon.json from ${DAEMON_BAK}"
elif [[ -f "${DOCKER_DAEMON_JSON}" ]]; then
    warn "No daemon.json backup found for timestamp ${LATEST_TS:-none}"
    warn "Removing daemon.json (Docker will revert to built-in defaults: data-root=/var/lib/docker)"
    rm -f "${DOCKER_DAEMON_JSON}"
    ok "Removed ${DOCKER_DAEMON_JSON}"
else
    info "daemon.json does not exist — nothing to remove"
fi

info "Restarting Docker (daemon.json changed)..."
systemctl restart docker
ok "Docker restarted"

# =============================================================================
# CONDITIONAL COSMOS RESTART
# =============================================================================
step "CosmosCloud Service"

if "${COSMOS_WAS_RUNNING}"; then
    info "Attempting to start CosmosCloud..."
    if systemctl start CosmosCloud 2>/dev/null; then
        ok "CosmosCloud started"
    else
        warn "CosmosCloud failed to start — check 'journalctl -u CosmosCloud -n 50'"
    fi
else
    info "CosmosCloud was not running before rollback — leaving it stopped"
fi

# =============================================================================
# SUMMARY
# =============================================================================
step "Rollback Summary"

printf "${YELLOW}NOTE:${NC} The following were NOT removed by this rollback:\n"
printf "  • /srv/cosmos/          (Cosmos config and data)\n"
printf "  • /srv/cosmos-storage/  (Marketplace application data)\n"
printf "  • /srv/media/           (Media files)\n"
printf "  • /srv/backups/         (Restic repositories)\n"
printf "  • /srv/docker/          (Docker data — was not migrated back to /var/lib/docker)\n"
printf "  • media user            (system user — remove manually if desired: userdel -r media)\n"
printf "\n"

if [[ -n "${LATEST_TS}" ]]; then
    printf "Backup files used (from ${BACKUP_DIR}):\n"
    ls -lh "${BACKUP_DIR}"/*.bak 2>/dev/null | grep "${LATEST_TS}" || true
fi

printf "\n${GREEN}${BOLD}Rollback complete.${NC}\n\n"
