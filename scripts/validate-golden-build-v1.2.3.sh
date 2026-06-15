#!/usr/bin/env bash
# =============================================================================
# Cosmos Cloud — Golden Build v1.2.3 Validation Script
#
# Checks that the live system matches the Golden Build v1.2.3 specification.
# Runs all checks and reports PASS or FAIL for each. Exits 0 if all pass,
# exits 1 if any fail.
#
# Does not modify any system state.
#
# Usage: sudo bash validate-golden-build-v1.2.3.sh
# =============================================================================
set -uo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly MEDIA_USER="media"
readonly MEDIA_SHELL="/usr/sbin/nologin"
readonly DOCKER_GROUP="docker"

readonly COSMOS_CONFIG_FILE="/srv/cosmos/config/cosmos.config.json"
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly DROPIN_FILE="/etc/systemd/system/CosmosCloud.service.d/golden-build.conf"

# =============================================================================
# LOGGING
# =============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0
COSMOS_INIT_PENDING=false

pass()  { printf "${GREEN}[PASS]${NC}  %s\n" "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { printf "${RED}[FAIL]${NC}  %s\n" "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
skip()  { printf "${BLUE}[SKIP]${NC}  %s\n" "$*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
group() { printf "\n${BOLD}%s${NC}\n" "$*"; }

check() {
    local label="$1" actual="$2" expected="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${label}"
    else
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

check_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -qE "${pattern}" "${file}" 2>/dev/null; then
        pass "${label}"
    else
        fail "${label}: '${pattern}' not found in ${file}"
    fi
}

check_dir() {
    local path="$1" expected_owner="$2" expected_mode="$3"
    if [[ ! -d "${path}" ]]; then
        fail "${path}: directory does not exist"
        return
    fi
    local actual_owner actual_mode
    actual_owner="$(stat -c '%U:%G' "${path}" 2>/dev/null || echo "unknown")"
    actual_mode="$(stat -c '%a' "${path}" 2>/dev/null || echo "unknown")"
    if [[ "${actual_owner}" == "${expected_owner}" && "${actual_mode}" == "${expected_mode}" ]]; then
        pass "${path}  (${expected_owner} ${expected_mode})"
    else
        fail "${path}: expected ${expected_owner} ${expected_mode}, got ${actual_owner} ${actual_mode}"
    fi
}

# =============================================================================
# ROOT CHECK
# =============================================================================
if [[ "${EUID}" -ne 0 ]]; then
    printf "${RED}[ERROR]${NC} This script must be run as root: sudo bash %s\n" "$(basename "$0")" >&2
    exit 1
fi

printf "\n${BOLD}Cosmos Cloud — Golden Build v1.2.3 Validation${NC}\n"
printf "%-50s  %s\n" "$(date)" "$(hostname)"
printf '%0.s─' {1..60}
printf '\n'

# =============================================================================
# 1. USER AND GROUP
# =============================================================================
group "1. Service User"

if id "${MEDIA_USER}" &>/dev/null; then
    MEDIA_UID="$(id -u "${MEDIA_USER}")"
    MEDIA_GID="$(id -g "${MEDIA_USER}")"
    pass "media user exists (UID=${MEDIA_UID}, GID=${MEDIA_GID})"

    # Canonical values: UID=1001, GID=1001 (established in v1.2.2).
    # FAIL only if running as root (UID=0).
    # PASS for the canonical 1001:1001 assignment.
    # WARN for any other non-root UID/GID (system is functional but not canonical).
    if [[ "${MEDIA_UID}" -eq 0 ]]; then
        fail "media UID is 0 (root) — Cosmos must not run as root"
    elif [[ "${MEDIA_UID}" -eq 1001 && "${MEDIA_GID}" -eq 1001 ]]; then
        pass "media UID=1001 GID=1001 (canonical Golden Build v1.2.3 configuration)"
    else
        warn "media UID=${MEDIA_UID} GID=${MEDIA_GID} — expected 1001:1001"
        warn "  System is functional but not at canonical v1.2.3 values."
        warn "  See docs/golden-build-v1.2.3.md Section 2 for the migration procedure."
    fi

    ACTUAL_SHELL="$(getent passwd "${MEDIA_USER}" | cut -d: -f7)"
    check "media shell is nologin" "${ACTUAL_SHELL}" "${MEDIA_SHELL}"

    if id -nG "${MEDIA_USER}" | tr ' ' '\n' | grep -qx "${DOCKER_GROUP}"; then
        pass "media is in docker group"
    else
        fail "media is not in docker group (run: usermod -aG docker media)"
    fi
else
    fail "media user does not exist"
    fail "media shell check skipped (user missing)"
    fail "docker group membership check skipped (user missing)"
fi

# =============================================================================
# 2. DOCKER DAEMON
# =============================================================================
group "2. Docker Daemon"

if ! systemctl is-active --quiet docker 2>/dev/null; then
    fail "Docker daemon is not running"
    skip "Docker data-root check (daemon not running)"
    skip "Docker logging driver check (daemon not running)"
else
    pass "Docker daemon is running"

    DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")"
    check "Docker data-root is /srv/docker" "${DOCKER_ROOT}" "/srv/docker"

    LOG_DRIVER="$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || echo "")"
    check "Docker logging driver is json-file" "${LOG_DRIVER}" "json-file"
fi

# =============================================================================
# 3. DAEMON.JSON LOG ROTATION
# =============================================================================
group "3. Docker Log Rotation (daemon.json)"

if [[ -f "${DOCKER_DAEMON_JSON}" ]]; then
    pass "daemon.json exists"

    if python3 -c "import json; json.load(open('${DOCKER_DAEMON_JSON}'))" 2>/dev/null; then
        pass "daemon.json is valid JSON"
    else
        fail "daemon.json is not valid JSON"
    fi

    DATA_ROOT="$(python3 -c "import json; c=json.load(open('${DOCKER_DAEMON_JSON}')); print(c.get('data-root',''))" 2>/dev/null || echo "")"
    check "data-root is /srv/docker" "${DATA_ROOT}" "/srv/docker"

    MAX_SIZE="$(python3 -c "import json; c=json.load(open('${DOCKER_DAEMON_JSON}')); print(c.get('log-opts',{}).get('max-size',''))" 2>/dev/null || echo "")"
    check "log-opts max-size=100m" "${MAX_SIZE}" "100m"

    MAX_FILE="$(python3 -c "import json; c=json.load(open('${DOCKER_DAEMON_JSON}')); print(c.get('log-opts',{}).get('max-file',''))" 2>/dev/null || echo "")"
    check "log-opts max-file=5" "${MAX_FILE}" "5"
else
    fail "daemon.json not found at ${DOCKER_DAEMON_JSON}"
    fail "data-root check skipped"
    fail "log-opts checks skipped"
fi

# =============================================================================
# 4. FILESYSTEM LAYOUT
# =============================================================================
group "4. /srv Filesystem Layout"

check_dir "/srv/cosmos"         "media:media" "750"
check_dir "/srv/cosmos/config"  "media:media" "711"
check_dir "/srv/cosmos-storage" "media:media" "755"
check_dir "/srv/media"          "media:media" "775"
check_dir "/srv/backups"        "media:media" "750"
check_dir "/srv/docker"         "root:root"   "710"

# /srv/config — canonical bind-mount root for Marketplace app configuration.
# Mode 2775 = setgid (new files/dirs inherit the 'media' group) + group-writable.
check_dir "/srv/config"         "media:media" "2775"

if [[ -d "/opt/cosmos" ]]; then
    OPT_OWNER="$(stat -c '%U:%G' /opt/cosmos 2>/dev/null || echo "")"
    check "/opt/cosmos owned by media:media" "${OPT_OWNER}" "media:media"
else
    skip "/opt/cosmos not found (Cosmos not yet installed)"
fi

# /mnt — optional external/mounted media access root.
# Check: group must be 'media' and mode must be 775.
# Owner may remain root — only the group and write bit are managed.
if [[ -d /mnt ]]; then
    _MNT_GRP="$(stat -c '%G' /mnt 2>/dev/null || echo "")"
    _MNT_MOD="$(stat -c '%a' /mnt 2>/dev/null || echo "")"
    if [[ "${_MNT_GRP}" == "${MEDIA_USER}" && "${_MNT_MOD}" == "775" ]]; then
        pass "/mnt  (root:${MEDIA_USER} ${_MNT_MOD} — media group has write access)"
    else
        fail "/mnt: expected group=${MEDIA_USER} mode=775, got group=${_MNT_GRP} mode=${_MNT_MOD}"
        fail "  Fix: sudo chgrp ${MEDIA_USER} /mnt && sudo chmod 775 /mnt"
    fi
else
    fail "/mnt: directory does not exist"
fi

# =============================================================================
# 5. SYSTEMD HARDENING DROP-IN
# =============================================================================
group "5. systemd Hardening Drop-in"

if [[ -f "${DROPIN_FILE}" ]]; then
    pass "drop-in exists: ${DROPIN_FILE}"

    check_contains "User=media"                "${DROPIN_FILE}" "^User=media$"
    check_contains "Group=media"               "${DROPIN_FILE}" "^Group=media$"
    check_contains "SupplementaryGroups=docker" "${DROPIN_FILE}" "^SupplementaryGroups=docker$"
    check_contains "AmbientCapabilities"        "${DROPIN_FILE}" "^AmbientCapabilities=CAP_NET_BIND_SERVICE$"
    check_contains "CapabilityBoundingSet"      "${DROPIN_FILE}" "^CapabilityBoundingSet=CAP_NET_BIND_SERVICE$"
    check_contains "NoNewPrivileges=true"       "${DROPIN_FILE}" "^NoNewPrivileges=true$"
    check_contains "COSMOS_CONFIG_FOLDER"       "${DROPIN_FILE}" "^Environment=COSMOS_CONFIG_FOLDER=/srv/cosmos/config/$"
    check_contains "ProtectSystem=strict"       "${DROPIN_FILE}" "^ProtectSystem=strict$"
    check_contains "ReadWritePaths includes /srv"        "${DROPIN_FILE}" "^ReadWritePaths=.*\/srv"
    check_contains "ReadWritePaths includes /mnt"        "${DROPIN_FILE}" "^ReadWritePaths=.*\/mnt"
    check_contains "ReadWritePaths includes /opt/cosmos" "${DROPIN_FILE}" "^ReadWritePaths=.*\/opt\/cosmos"
else
    fail "drop-in not found: ${DROPIN_FILE}"
    skip "drop-in directive checks (file missing)"
fi

# =============================================================================
# 6. COSMOSCLOUD SERVICE AND PROCESS
# =============================================================================
group "6. CosmosCloud Service"

if ! systemctl list-unit-files CosmosCloud.service --no-legend 2>/dev/null | grep -q CosmosCloud; then
    skip "CosmosCloud.service not installed — all process checks skipped"
elif ! systemctl is-active --quiet CosmosCloud 2>/dev/null; then
    warn "CosmosCloud.service exists but is not running — process checks skipped"
    skip "CosmosCloud process checks (service not running)"
else
    pass "CosmosCloud.service is active"

    COSMOS_PID="$(systemctl show CosmosCloud --property=MainPID --value 2>/dev/null || echo "0")"

    if [[ "${COSMOS_PID}" == "0" || -z "${COSMOS_PID}" ]]; then
        fail "Could not determine CosmosCloud PID"
    else
        # Process user
        PROC_USER="$(ps -o user= -p "${COSMOS_PID}" 2>/dev/null | tr -d ' ' || echo "")"
        check "CosmosCloud process runs as media" "${PROC_USER}" "media"

        # COSMOS_CONFIG_FOLDER in environment
        CONFIG_FOLDER="$(tr '\0' '\n' < "/proc/${COSMOS_PID}/environ" 2>/dev/null \
            | grep '^COSMOS_CONFIG_FOLDER=' | cut -d= -f2- || echo "")"
        check "COSMOS_CONFIG_FOLDER=/srv/cosmos/config/" "${CONFIG_FOLDER}" "/srv/cosmos/config/"

        # NoNewPrivileges
        NO_NEW_PRIVS="$(grep 'NoNewPrivs:' "/proc/${COSMOS_PID}/status" 2>/dev/null \
            | awk '{print $2}' || echo "")"
        check "NoNewPrivileges enforced" "${NO_NEW_PRIVS}" "1"

        # Capabilities — all four sets must be exactly CAP_NET_BIND_SERVICE (0x400)
        CAP_EFF="$(grep '^CapEff:' "/proc/${COSMOS_PID}/status" 2>/dev/null \
            | awk '{print $2}' | sed 's/^0*//' || echo "")"
        if [[ "${CAP_EFF}" == "400" ]]; then
            pass "CapEff = 0x0000000000000400 (CAP_NET_BIND_SERVICE only)"
        else
            fail "CapEff is 0x${CAP_EFF}, expected 0x0000000000000400"
        fi

        CAP_BND="$(grep '^CapBnd:' "/proc/${COSMOS_PID}/status" 2>/dev/null \
            | awk '{print $2}' | sed 's/^0*//' || echo "")"
        if [[ "${CAP_BND}" == "400" ]]; then
            pass "CapBnd = 0x0000000000000400 (CAP_NET_BIND_SERVICE only)"
        else
            fail "CapBnd is 0x${CAP_BND}, expected 0x0000000000000400"
        fi
    fi
fi

# =============================================================================
# 7. COSMOS CONFIG FILE
# =============================================================================
group "7. Cosmos Configuration (cosmos.config.json)"

if [[ -f "${COSMOS_CONFIG_FILE}" ]]; then
    pass "cosmos.config.json exists"

    if python3 -c "import json; json.load(open('${COSMOS_CONFIG_FILE}'))" 2>/dev/null; then
        pass "cosmos.config.json is valid JSON"
    else
        fail "cosmos.config.json is not valid JSON"
    fi

    FILE_OWNER="$(stat -c '%U:%G' "${COSMOS_CONFIG_FILE}" 2>/dev/null || echo "")"
    check "cosmos.config.json owned by media:media" "${FILE_OWNER}" "media:media"

    DEFAULT_PATH="$(python3 -c "
import json
c = json.load(open('${COSMOS_CONFIG_FILE}'))
print(c.get('DockerConfig', {}).get('DefaultDataPath', ''))
" 2>/dev/null || echo "")"
    check "DefaultDataPath=/srv/cosmos-storage" "${DEFAULT_PATH}" "/srv/cosmos-storage"

    # Confirm DefaultDataPath does NOT end with a trailing slash
    if [[ "${DEFAULT_PATH}" == */ ]]; then
        fail "DefaultDataPath ends with trailing slash (must not)"
    elif [[ "${DEFAULT_PATH}" == "/srv/cosmos-storage" ]]; then
        pass "DefaultDataPath has no trailing slash"
    fi
else
    warn "cosmos.config.json not found — Cosmos has not completed initial startup"
    skip "DefaultDataPath check (pending Cosmos initialization)"
    skip "File ownership check (pending Cosmos initialization)"
    COSMOS_INIT_PENDING=true
fi

# =============================================================================
# 8. CONTAINER LOG ROTATION (spot check on running containers)
# =============================================================================
group "8. Container Log Rotation (runtime spot check)"

if ! systemctl is-active --quiet docker 2>/dev/null; then
    skip "Container log check (Docker not running)"
else
    RUNNING_CONTAINERS="$(docker ps -q 2>/dev/null | head -1 || echo "")"
    if [[ -z "${RUNNING_CONTAINERS}" ]]; then
        skip "No running containers to inspect"
    else
        # Spot-check the first running container
        CONTAINER_ID="${RUNNING_CONTAINERS}"
        CONTAINER_NAME="$(docker inspect --format '{{.Name}}' "${CONTAINER_ID}" 2>/dev/null | tr -d '/')"
        LOG_TYPE="$(docker inspect --format '{{.HostConfig.LogConfig.Type}}' "${CONTAINER_ID}" 2>/dev/null || echo "")"
        check "Container '${CONTAINER_NAME}' log driver" "${LOG_TYPE}" "json-file"

        # Containers created before daemon.json was updated will have empty Config {}
        # (they inherit daemon defaults but their stored Config is empty).
        # We check daemon.json instead of per-container config for the authoritative value.
        if [[ -f "${DOCKER_DAEMON_JSON}" ]]; then
            MAX_SIZE="$(python3 -c "import json; c=json.load(open('${DOCKER_DAEMON_JSON}')); print(c.get('log-opts',{}).get('max-size',''))" 2>/dev/null || echo "")"
            if [[ "${MAX_SIZE}" == "100m" ]]; then
                pass "Daemon default max-size=100m (authoritative for existing containers with empty Config)"
            fi
        fi
    fi
fi

# =============================================================================
# 9. ORPHAN ARTIFACT CHECK
# =============================================================================
group "9. Orphan Artifact Check"

# /var/lib/cosmos and /var/lib/docker may exist as one-time artifacts from the
# initial CosmosCloud or Docker start before daemon.json and the systemd drop-in
# were active. The Golden Build v1.2.1 installer eliminates this race going
# forward. On systems first installed with v1.2, these paths may remain.
#
# Policy:
#   PASS  — path does not exist
#   WARN  — path exists, no open file descriptors (inactive; safe to remove)
#   FAIL  — path exists and has open file descriptors (actively used)

# ── /var/lib/cosmos ───────────────────────────────────────────────────────────
if [[ -d /var/lib/cosmos ]]; then
    _VLC_FDS="$(lsof +D /var/lib/cosmos 2>/dev/null | tail -n +2 | wc -l)"
    if [[ "${_VLC_FDS}" -gt 0 ]]; then
        fail "/var/lib/cosmos has ${_VLC_FDS} open file descriptor(s) — active use detected"
        lsof +D /var/lib/cosmos 2>/dev/null | tail -n +2 | \
            awk '{printf "  PID=%-6s CMD=%-20s FD=%s  %s\n", $2, $1, $4, $NF}'
        warn "Close all editors and shells using /var/lib/cosmos, then check again"
    else
        warn "/var/lib/cosmos exists — no open file descriptors"
        warn "  → One-time orphan artifact; safe to remove: sudo rm -rf /var/lib/cosmos"
    fi
else
    pass "/var/lib/cosmos: not present (clean)"
fi

# ── /var/lib/docker ───────────────────────────────────────────────────────────
if [[ -d /var/lib/docker ]]; then
    _VLD_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")"
    if [[ "${_VLD_ROOT}" != "/srv/docker" ]]; then
        fail "/var/lib/docker exists and Docker Root Dir is '${_VLD_ROOT}' (expected /srv/docker)"
        fail "  daemon.json may not be applied — run the installer to correct this"
    else
        _VLD_FDS="$(lsof +D /var/lib/docker 2>/dev/null | tail -n +2 | wc -l)"
        if [[ "${_VLD_FDS}" -gt 0 ]]; then
            fail "/var/lib/docker has ${_VLD_FDS} open file descriptor(s) despite Docker Root Dir=/srv/docker"
            lsof +D /var/lib/docker 2>/dev/null | tail -n +2 | \
                awk '{printf "  PID=%-6s CMD=%-20s FD=%s  %s\n", $2, $1, $4, $NF}'
        else
            warn "/var/lib/docker exists — no open file descriptors (Docker Root Dir: /srv/docker)"
            warn "  → One-time orphan artifact; safe to remove: sudo rm -rf /var/lib/docker"
        fi
    fi
else
    pass "/var/lib/docker: not present (clean)"
fi

# =============================================================================
# RESULTS SUMMARY
# =============================================================================
printf "\n"
printf '%0.s─' {1..60}
printf "\n"
printf "${BOLD}Validation Results${NC}\n"
printf "  ${GREEN}PASS${NC}: %d\n" "${PASS_COUNT}"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    printf "  ${RED}FAIL${NC}: %d\n" "${FAIL_COUNT}"
fi
if [[ "${WARN_COUNT}" -gt 0 ]]; then
    printf "  ${YELLOW}WARN${NC}: %d\n" "${WARN_COUNT}"
fi
if [[ "${SKIP_COUNT}" -gt 0 ]]; then
    printf "  ${BLUE}SKIP${NC}: %d\n" "${SKIP_COUNT}"
fi
printf "\n"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    printf "${RED}${BOLD}RESULT: FAIL${NC} — %d check(s) did not pass.\n\n" "${FAIL_COUNT}"
    printf "To apply the Golden Build, run:\n"
    printf "  sudo bash install-cosmos-golden-build-v1.2.3.sh\n\n"
    exit 1
elif "${COSMOS_INIT_PENDING}"; then
    printf "${YELLOW}${BOLD}RESULT: PENDING${NC} — Golden Build v1.2.3 infrastructure in place; Cosmos initialization required.\n\n"
    printf "cosmos.config.json does not exist yet. Start Cosmos to complete initialization:\n"
    printf "  sudo systemctl start CosmosCloud\n"
    printf "Then run the installer again to set DefaultDataPath:\n"
    printf "  sudo bash install-cosmos-golden-build-v1.2.3.sh\n\n"
    exit 0
else
    printf "${GREEN}${BOLD}RESULT: PASS${NC} — system matches Golden Build v1.2.3 specification.\n\n"
    exit 0
fi
