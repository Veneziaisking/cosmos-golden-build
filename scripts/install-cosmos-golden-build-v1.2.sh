#!/usr/bin/env bash
# =============================================================================
# Cosmos Cloud — Golden Build v1.2 Installer
# Target: Debian GNU/Linux 13 (trixie)
#
# Prepares a fresh or existing Debian 13 server for the Golden Build v1.2
# architecture. Safe to run multiple times — all phases are idempotent.
#
# What this script does:
#   1. Preflight: verifies OS, Docker, python3, backup dir
#   2. Creates the 'media' service user (nologin, docker group)
#   3. Creates the /srv directory layout with correct ownership/permissions
#   4. Configures /etc/docker/daemon.json (data-root + log rotation)
#   5. Writes the CosmosCloud systemd hardening drop-in
#   6. Fixes DockerConfig.DefaultDataPath in cosmos.config.json if it exists
#   7. Applies changes (daemon-reload, Docker restart, CosmosCloud restart)
#   8. Runs validation checks and reports PASS/FAIL
#
# What this script does NOT do:
#   - Install Docker or Cosmos
#   - Migrate existing Docker data from /var/lib/docker
#   - Modify Samba, nftables, or firewall rules
#   - Enable rootless Docker
#   - Install any packages
#
# Usage: sudo bash install-cosmos-golden-build-v1.2.sh
# =============================================================================
set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly GOLDEN_BUILD_VERSION="1.2"
readonly SCRIPT_NAME="$(basename "$0")"

readonly MEDIA_USER="media"
readonly MEDIA_HOME="/home/media"
readonly MEDIA_SHELL="/usr/sbin/nologin"
readonly DOCKER_GROUP="docker"

readonly SRV_COSMOS="/srv/cosmos"
readonly SRV_COSMOS_CONFIG="/srv/cosmos/config"
readonly COSMOS_CONFIG_FILE="/srv/cosmos/config/cosmos.config.json"
readonly SRV_COSMOS_STORAGE="/srv/cosmos-storage"
readonly SRV_MEDIA="/srv/media"
readonly SRV_BACKUPS="/srv/backups"
readonly SRV_DOCKER="/srv/docker"
readonly OPT_COSMOS="/opt/cosmos"

readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly DROPIN_DIR="/etc/systemd/system/CosmosCloud.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/golden-build.conf"

readonly BACKUP_DIR="/root/golden-build-backups"
readonly BACKUP_TS="$(date +%Y%m%d-%H%M%S)"

# Change tracking — used to decide which services need restarting
DOCKER_DAEMON_CHANGED=false
DROPIN_CHANGED=false
COSMOS_CONFIG_CHANGED=false
COSMOS_WAS_RUNNING=false
COSMOS_INIT_PENDING=false

# =============================================================================
# LOGGING
# =============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[PASS]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC}  %s\n" "$*" >&2; }
step()  { printf "\n${BOLD}━━━ %s ━━━${NC}\n" "$*"; }
die()   { printf "${RED}[FATAL]${NC} %s\n" "$*" >&2; exit 1; }

# =============================================================================
# ROOT CHECK
# =============================================================================
if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root.  Try: sudo bash ${SCRIPT_NAME}"
fi

printf "\n${BOLD}Cosmos Cloud — Golden Build v${GOLDEN_BUILD_VERSION} Installer${NC}\n"
printf "Backup timestamp: %s\n" "${BACKUP_TS}"
printf "Backups will be written to: %s\n\n" "${BACKUP_DIR}"

# =============================================================================
# PHASE 1: PREFLIGHT CHECKS
# =============================================================================
step "Phase 1: Preflight Checks"

# OS
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]; then
        ok "Debian 13 (trixie)"
    elif [[ "${ID:-}" == "debian" ]]; then
        warn "Debian ${VERSION_ID:-unknown} detected — script targets Debian 13"
    else
        warn "OS '${PRETTY_NAME:-unknown}' is not Debian 13 — proceeding anyway"
    fi
else
    warn "/etc/os-release not found — cannot verify OS"
fi

# python3 (required for JSON manipulation)
if ! command -v python3 &>/dev/null; then
    die "python3 is required but not installed (apt-get install python3)"
fi
ok "python3: $(python3 --version 2>&1)"

# Docker installed and running
if ! command -v docker &>/dev/null; then
    die "Docker CLI not found. Install docker-ce before running this script."
fi
if ! systemctl is-active --quiet docker 2>/dev/null; then
    die "Docker daemon is not running. Start it with: systemctl start docker"
fi
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")"
ok "Docker running: ${DOCKER_VERSION}"

# /srv mount
if mountpoint -q /srv 2>/dev/null; then
    SRV_AVAIL="$(df -h /srv | awk 'NR==2 {print $4}')"
    ok "/srv is a dedicated mount point (${SRV_AVAIL} available)"
else
    warn "/srv is not a separate mount point — a dedicated LVM volume is strongly recommended"
fi

# Warn if Docker has data at the old default location that would become inaccessible
CURRENT_DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")"
if [[ "${CURRENT_DOCKER_ROOT}" != "/srv/docker" && -n "${CURRENT_DOCKER_ROOT}" ]]; then
    EXISTING_CONTAINERS="$(docker ps -aq 2>/dev/null | wc -l)"
    EXISTING_VOLUMES="$(docker volume ls -q 2>/dev/null | wc -l)"
    if [[ "${EXISTING_CONTAINERS}" -gt 0 || "${EXISTING_VOLUMES}" -gt 0 ]]; then
        warn "Docker has ${EXISTING_CONTAINERS} container(s) and ${EXISTING_VOLUMES} volume(s) at ${CURRENT_DOCKER_ROOT}"
        warn "After changing data-root to /srv/docker those will not be visible to Docker."
        warn "They remain on disk and can be manually migrated if needed."
        warn "Cosmos will recreate cosmos-mongo automatically on next startup."
    fi
fi

# CosmosCloud.service
COSMOS_SERVICE_EXISTS=false
if [[ -f /etc/systemd/system/CosmosCloud.service ]] || \
   [[ -f /usr/lib/systemd/system/CosmosCloud.service ]]; then
    COSMOS_SERVICE_EXISTS=true
    ok "CosmosCloud.service found"
else
    warn "CosmosCloud.service not found — drop-in will be created and will activate when Cosmos is installed"
fi

# Backup directory
mkdir -p "${BACKUP_DIR}"
ok "Backup directory ready: ${BACKUP_DIR}"

# =============================================================================
# PHASE 2: SERVICE USER
# =============================================================================
step "Phase 2: Service User"

if id "${MEDIA_USER}" &>/dev/null; then
    ok "User '${MEDIA_USER}' exists (UID=$(id -u "${MEDIA_USER}"), GID=$(id -g "${MEDIA_USER}"))"

    CURRENT_SHELL="$(getent passwd "${MEDIA_USER}" | cut -d: -f7)"
    if [[ "${CURRENT_SHELL}" != "${MEDIA_SHELL}" ]]; then
        info "Correcting shell: '${CURRENT_SHELL}' → '${MEDIA_SHELL}'"
        usermod --shell "${MEDIA_SHELL}" "${MEDIA_USER}"
        ok "Shell updated to ${MEDIA_SHELL}"
    else
        ok "Shell is ${MEDIA_SHELL}"
    fi
else
    info "Creating system user '${MEDIA_USER}'"
    useradd \
        --system \
        --create-home \
        --home-dir "${MEDIA_HOME}" \
        --shell "${MEDIA_SHELL}" \
        --user-group \
        "${MEDIA_USER}"
    ok "Created '${MEDIA_USER}' (UID=$(id -u "${MEDIA_USER}"), GID=$(id -g "${MEDIA_USER}"))"
fi

if getent group "${DOCKER_GROUP}" &>/dev/null; then
    if id -nG "${MEDIA_USER}" | tr ' ' '\n' | grep -qx "${DOCKER_GROUP}"; then
        ok "'${MEDIA_USER}' is already in group '${DOCKER_GROUP}'"
    else
        info "Adding '${MEDIA_USER}' to group '${DOCKER_GROUP}'"
        usermod -aG "${DOCKER_GROUP}" "${MEDIA_USER}"
        ok "Added '${MEDIA_USER}' to group '${DOCKER_GROUP}'"
    fi
else
    warn "Group '${DOCKER_GROUP}' does not exist — re-run after Docker is installed"
fi

# =============================================================================
# PHASE 3: /srv DIRECTORY LAYOUT
# =============================================================================
step "Phase 3: Filesystem Layout"

ensure_dir() {
    local path="$1" owner="$2" mode="$3"
    if [[ ! -d "${path}" ]]; then
        mkdir -p "${path}"
        info "Created ${path}"
    fi
    chown "${owner}" "${path}"
    chmod "${mode}" "${path}"
    ok "${path}  →  owner=${owner}  mode=${mode}"
}

ensure_dir "${SRV_COSMOS}"         "media:media" "750"
ensure_dir "${SRV_COSMOS_CONFIG}"  "media:media" "711"
ensure_dir "${SRV_COSMOS_STORAGE}" "media:media" "755"
ensure_dir "${SRV_MEDIA}"          "media:media" "775"
ensure_dir "${SRV_BACKUPS}"        "media:media" "750"
ensure_dir "${SRV_DOCKER}"         "root:root"   "710"

if [[ -d "${OPT_COSMOS}" ]]; then
    chown -R "${MEDIA_USER}:${MEDIA_USER}" "${OPT_COSMOS}"
    chmod 755 "${OPT_COSMOS}"
    ok "${OPT_COSMOS}  →  owner=media:media  mode=755"
else
    warn "${OPT_COSMOS} not found — will be configured when Cosmos is installed"
fi

# =============================================================================
# PHASE 4: DOCKER DAEMON.JSON
# =============================================================================
step "Phase 4: Docker daemon.json"

# Use python3 to generate a merged daemon.json that:
#   - Preserves any pre-existing keys not owned by this script
#   - Merges log-opts (preserving any extra log options)
#   - Outputs "NO_CHANGE" if the required settings are already present
DAEMON_RESULT="$(python3 /dev/stdin "${DOCKER_DAEMON_JSON}" <<'PYEOF'
import json, sys

required = {
    "data-root": "/srv/docker",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "5"
    }
}

daemon_json_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/docker/daemon.json"

try:
    with open(daemon_json_path) as f:
        current = json.load(f)
except FileNotFoundError:
    current = {}
except json.JSONDecodeError as e:
    print(f"JSON_ERROR:{e}", file=sys.stderr)
    sys.exit(2)

def required_present(req, cur):
    for key, val in req.items():
        if key not in cur:
            return False
        if isinstance(val, dict):
            if not isinstance(cur[key], dict):
                return False
            if not required_present(val, cur[key]):
                return False
        elif cur[key] != val:
            return False
    return True

if required_present(required, current):
    print("NO_CHANGE")
    sys.exit(0)

# Merge: preserve existing keys, apply required values on top
merged = dict(current)
for key, val in required.items():
    if key == "log-opts" and isinstance(val, dict) and isinstance(merged.get(key), dict):
        merged[key] = {**merged[key], **val}
    else:
        merged[key] = val

print(json.dumps(merged, indent=2))
PYEOF
)" || die "python3 failed to process daemon.json — check that the file is valid JSON"

if [[ "${DAEMON_RESULT}" == "NO_CHANGE" ]]; then
    ok "daemon.json already has correct settings — no change needed"
else
    if [[ -f "${DOCKER_DAEMON_JSON}" ]]; then
        cp "${DOCKER_DAEMON_JSON}" "${BACKUP_DIR}/daemon.json.${BACKUP_TS}.bak"
        info "Backed up daemon.json → ${BACKUP_DIR}/daemon.json.${BACKUP_TS}.bak"
    fi
    printf '%s\n' "${DAEMON_RESULT}" > "${DOCKER_DAEMON_JSON}"
    ok "Written daemon.json"
    DOCKER_DAEMON_CHANGED=true
fi

# =============================================================================
# PHASE 5: SYSTEMD HARDENING DROP-IN
# =============================================================================
step "Phase 5: systemd Hardening Drop-in"

# The exact drop-in content for Golden Build v1.2.
# Any difference from the current file triggers a backup + overwrite.
read -r -d '' DROPIN_CONTENT <<'DROPIN' || true
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
DROPIN

mkdir -p "${DROPIN_DIR}"

if [[ -f "${DROPIN_FILE}" ]] && [[ "$(cat "${DROPIN_FILE}")" == "${DROPIN_CONTENT}" ]]; then
    ok "Drop-in already has correct content — no change needed"
else
    if [[ -f "${DROPIN_FILE}" ]]; then
        cp "${DROPIN_FILE}" "${BACKUP_DIR}/golden-build.conf.${BACKUP_TS}.bak"
        info "Backed up drop-in → ${BACKUP_DIR}/golden-build.conf.${BACKUP_TS}.bak"
    fi
    printf '%s' "${DROPIN_CONTENT}" > "${DROPIN_FILE}"
    ok "Written ${DROPIN_FILE}"
    DROPIN_CHANGED=true
fi

# =============================================================================
# PHASE 6: COSMOS CONFIG — DefaultDataPath
# =============================================================================
step "Phase 6: Cosmos Configuration (DefaultDataPath)"

if [[ -f "${COSMOS_CONFIG_FILE}" ]]; then
    CURRENT_DEFAULT_PATH="$(python3 /dev/stdin "${COSMOS_CONFIG_FILE}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
    print(c.get("DockerConfig", {}).get("DefaultDataPath", ""))
except Exception as e:
    print(f"READ_ERROR:{e}", file=sys.stderr)
    sys.exit(2)
PYEOF
)" || die "Failed to read DefaultDataPath from cosmos.config.json"

    if [[ "${CURRENT_DEFAULT_PATH}" == "/srv/cosmos-storage" ]]; then
        ok "DefaultDataPath is already /srv/cosmos-storage"
    else
        warn "DefaultDataPath is '${CURRENT_DEFAULT_PATH}' — must be '/srv/cosmos-storage'"

        # Stop Cosmos if running so it doesn't overwrite our changes on next write
        if systemctl is-active --quiet CosmosCloud 2>/dev/null; then
            info "Stopping CosmosCloud to safely modify cosmos.config.json..."
            systemctl stop CosmosCloud
            COSMOS_WAS_RUNNING=true
            info "Waiting for CosmosCloud to stop..."
            sleep 2
        fi

        cp "${COSMOS_CONFIG_FILE}" "${BACKUP_DIR}/cosmos.config.json.${BACKUP_TS}.bak"
        info "Backed up cosmos.config.json → ${BACKUP_DIR}/cosmos.config.json.${BACKUP_TS}.bak"

        python3 /dev/stdin "${COSMOS_CONFIG_FILE}" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    c = json.load(f)
if "DockerConfig" not in c:
    c["DockerConfig"] = {}
c["DockerConfig"]["DefaultDataPath"] = "/srv/cosmos-storage"
with open(path, "w") as f:
    json.dump(c, f, indent=2)
PYEOF
        chown "${MEDIA_USER}:${MEDIA_USER}" "${COSMOS_CONFIG_FILE}"
        ok "DefaultDataPath updated to /srv/cosmos-storage"
        COSMOS_CONFIG_CHANGED=true
    fi
else
    warn "cosmos.config.json not found at ${COSMOS_CONFIG_FILE}"
    warn "Pass 1 of 2: infrastructure is provisioned. Cosmos has not started yet."
    warn "  After Cosmos generates cosmos.config.json, run this script again (Pass 2)"
    warn "  to set DefaultDataPath=/srv/cosmos-storage automatically."
    COSMOS_INIT_PENDING=true
fi

# =============================================================================
# PHASE 7: APPLY CHANGES
# =============================================================================
step "Phase 7: Applying Changes"

if ! "${DOCKER_DAEMON_CHANGED}" && ! "${DROPIN_CHANGED}" && ! "${COSMOS_CONFIG_CHANGED}"; then
    ok "No configuration changes were made — system already matches Golden Build v${GOLDEN_BUILD_VERSION}"
fi

# Reload systemd if the drop-in changed
if "${DROPIN_CHANGED}"; then
    info "Reloading systemd unit files..."
    systemctl daemon-reload
    ok "systemd reloaded"
fi

# Restart Docker if daemon.json changed (brief downtime for running containers)
if "${DOCKER_DAEMON_CHANGED}"; then
    info "Restarting Docker daemon (daemon.json changed)..."
    systemctl restart docker
    ok "Docker restarted"
    # Give Docker a moment to settle
    sleep 2
fi

# Restart or start CosmosCloud if appropriate
COSMOS_SERVICE_ACTIVE=false
if "${COSMOS_SERVICE_EXISTS}" || \
   systemctl list-unit-files CosmosCloud.service --no-legend 2>/dev/null | grep -q CosmosCloud; then
    COSMOS_SERVICE_EXISTS=true
    if systemctl is-active --quiet CosmosCloud 2>/dev/null; then
        COSMOS_SERVICE_ACTIVE=true
    fi
fi

if "${DROPIN_CHANGED}" && "${COSMOS_SERVICE_EXISTS}"; then
    if "${COSMOS_SERVICE_ACTIVE}" || "${COSMOS_WAS_RUNNING}"; then
        info "Restarting CosmosCloud (drop-in changed)..."
        systemctl restart CosmosCloud
        ok "CosmosCloud restarted"
    else
        info "CosmosCloud is not running — drop-in will take effect on next start"
    fi
elif "${COSMOS_WAS_RUNNING}" && ! "${DROPIN_CHANGED}"; then
    # Was stopped only for config change; drop-in didn't change; restart it
    if ! systemctl is-active --quiet CosmosCloud 2>/dev/null; then
        info "Starting CosmosCloud (was stopped for config change)..."
        systemctl start CosmosCloud
        ok "CosmosCloud started"
    fi
fi

# =============================================================================
# PHASE 8: VALIDATION
# =============================================================================
step "Phase 8: Validation"

VALIDATION_FAILED=false

check_pass() { ok "$1"; }
check_fail() { fail "$1"; VALIDATION_FAILED=true; }

check() {
    local label="$1" actual="$2" expected="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        check_pass "${label}"
    else
        check_fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

check_dir() {
    local path="$1" expected_owner="$2" expected_mode="$3"
    if [[ ! -d "${path}" ]]; then
        check_fail "${path}: directory does not exist"
        return
    fi
    local actual_owner actual_mode
    actual_owner="$(stat -c '%U:%G' "${path}")"
    actual_mode="$(stat -c '%a' "${path}")"
    if [[ "${actual_owner}" == "${expected_owner}" && "${actual_mode}" == "${expected_mode}" ]]; then
        check_pass "${path}  (${expected_owner} ${expected_mode})"
    else
        check_fail "${path}: expected ${expected_owner} ${expected_mode}, got ${actual_owner} ${actual_mode}"
    fi
}

# --- User checks ---
if id "${MEDIA_USER}" &>/dev/null; then
    check_pass "media user exists (UID=$(id -u "${MEDIA_USER}"))"
    check "media shell" "$(getent passwd "${MEDIA_USER}" | cut -d: -f7)" "${MEDIA_SHELL}"
else
    check_fail "media user does not exist"
fi

if id -nG "${MEDIA_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx "${DOCKER_GROUP}"; then
    check_pass "media is in docker group"
else
    check_fail "media is not in docker group"
fi

# --- Docker checks ---
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")"
check "Docker data-root" "${DOCKER_ROOT}" "/srv/docker"

DOCKER_LOG_DRIVER="$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || echo "")"
check "Docker logging driver" "${DOCKER_LOG_DRIVER}" "json-file"

if [[ -f "${DOCKER_DAEMON_JSON}" ]]; then
    MAX_SIZE="$(python3 -c "import json; c=json.load(open('${DOCKER_DAEMON_JSON}')); print(c.get('log-opts',{}).get('max-size',''))" 2>/dev/null || echo "")"
    MAX_FILE="$(python3 -c "import json; c=json.load(open('${DOCKER_DAEMON_JSON}')); print(c.get('log-opts',{}).get('max-file',''))" 2>/dev/null || echo "")"
    check "log-opts max-size" "${MAX_SIZE}" "100m"
    check "log-opts max-file" "${MAX_FILE}" "5"
else
    check_fail "daemon.json not found at ${DOCKER_DAEMON_JSON}"
fi

# --- Filesystem checks ---
check_dir "/srv/cosmos"         "media:media" "750"
check_dir "/srv/cosmos/config"  "media:media" "711"
check_dir "/srv/cosmos-storage" "media:media" "755"
check_dir "/srv/media"          "media:media" "775"
check_dir "/srv/backups"        "media:media" "750"
check_dir "/srv/docker"         "root:root"   "710"

# --- systemd drop-in ---
if [[ -f "${DROPIN_FILE}" ]]; then
    check_pass "systemd drop-in exists"
    if grep -q "^User=media$" "${DROPIN_FILE}" && \
       grep -q "^ProtectSystem=strict$" "${DROPIN_FILE}" && \
       grep -q "^NoNewPrivileges=true$" "${DROPIN_FILE}"; then
        check_pass "drop-in contains required directives"
    else
        check_fail "drop-in is missing one or more required directives"
    fi
else
    check_fail "systemd drop-in not found: ${DROPIN_FILE}"
fi

# --- CosmosCloud process checks (only if running) ---
if systemctl is-active --quiet CosmosCloud 2>/dev/null; then
    COSMOS_PID="$(systemctl show CosmosCloud --property=MainPID --value 2>/dev/null || echo "")"
    if [[ -n "${COSMOS_PID}" && "${COSMOS_PID}" != "0" ]]; then
        COSMOS_PROC_USER="$(ps -o user= -p "${COSMOS_PID}" 2>/dev/null | tr -d ' ' || echo "")"
        check "CosmosCloud runs as" "${COSMOS_PROC_USER}" "media"

        CONFIG_ENV="$(tr '\0' '\n' < "/proc/${COSMOS_PID}/environ" 2>/dev/null | grep '^COSMOS_CONFIG_FOLDER=' | cut -d= -f2- || echo "")"
        check "COSMOS_CONFIG_FOLDER" "${CONFIG_ENV}" "/srv/cosmos/config/"

        NO_NEW_PRIVS="$(grep -i NoNewPrivs "/proc/${COSMOS_PID}/status" 2>/dev/null | awk '{print $2}' || echo "")"
        check "NoNewPrivileges" "${NO_NEW_PRIVS}" "1"
    fi
else
    warn "CosmosCloud is not running — process-level checks skipped"
fi

# --- cosmos.config.json ---
if [[ -f "${COSMOS_CONFIG_FILE}" ]]; then
    DEFAULT_PATH="$(python3 -c "import json; c=json.load(open('${COSMOS_CONFIG_FILE}')); print(c.get('DockerConfig',{}).get('DefaultDataPath',''))" 2>/dev/null || echo "")"
    check "DefaultDataPath" "${DEFAULT_PATH}" "/srv/cosmos-storage"
else
    warn "cosmos.config.json not found — DefaultDataPath check skipped (Pass 1 complete; run again after first Cosmos startup)"
fi

# =============================================================================
# SUMMARY
# =============================================================================
step "Summary"

if "${VALIDATION_FAILED}"; then
    fail "One or more validation checks failed — review the output above."
    printf "\n"
    exit 1
fi

if "${COSMOS_INIT_PENDING}"; then
    printf "${YELLOW}${BOLD}Golden Build v%s infrastructure provisioned — Cosmos initialization pending.${NC}\n\n" "${GOLDEN_BUILD_VERSION}"
    printf "Pass 1 complete: all infrastructure is in place.\n"
    printf "cosmos.config.json does not exist yet — Cosmos has not started for the first time.\n\n"
    printf "${YELLOW}Pass 2 required:${NC}\n"
    printf "  1. Start CosmosCloud and complete initial setup:\n"
    printf "       sudo systemctl start CosmosCloud\n"
    printf "     Open the Cosmos web UI and complete the setup wizard.\n\n"
    printf "  2. Run this installer again to set DefaultDataPath:\n"
    printf "       sudo bash %s\n\n" "${SCRIPT_NAME}"
    printf "  3. Confirm the complete Golden Build:\n"
    printf "       sudo bash validate-golden-build-v1.2.sh\n\n"
else
    printf "${GREEN}${BOLD}All checks passed.${NC}\n"
    printf "${GREEN}${BOLD}Golden Build v%s installation complete.${NC}\n\n" "${GOLDEN_BUILD_VERSION}"
fi

if "${DOCKER_DAEMON_CHANGED}" || "${DROPIN_CHANGED}" || "${COSMOS_CONFIG_CHANGED}"; then
    printf "Backups of modified files are in: %s\n" "${BACKUP_DIR}"
    ls -lh "${BACKUP_DIR}/" 2>/dev/null | grep "${BACKUP_TS}" || true
fi
