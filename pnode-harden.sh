#!/bin/bash
#
# ChillXand pNode Operator Tasks (pnode-harden.sh)
#
# As of v1.1.0, the bulk of system hardening (sysctls, fail2ban, SSH lockdown,
# disk hygiene, journald/logrotate, cleanup cron, tmpfs /tmp, etc.) is applied
# automatically by the controller installer (install-controller-proxy.go).
#
# This script now only handles operator-controlled tasks that require explicit
# decision per node:
#   - Section 3:  Ubuntu Pro attach (requires a token)
#   - Section 13: UFW verification (read-only audit of expected rules)
#   - Section 22: Full apt update + upgrade (excludes Xandeum packages)
#   - Section 24: /xandeum-pages storage allocation
#
# Default: DRY-RUN mode (shows what would be done)
# Use -x flag to actually execute changes
#

set -e

# Version
VERSION="1.1.0"
MARKER_DIR="/etc/chillxand"
MARKER_FILE="${MARKER_DIR}/pnode-harden.version"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Mode
DRY_RUN=true
PRO_TOKEN=""
SKIP_XANDEUM_PAGES=false

# Summary tracking
declare -A STATUS
declare -A ACTION

# Expected UFW rules (read-only verification only)
EXPECTED_UFW_PORTS=(
    "22/tcp:Anywhere:SSH"
    "5000/udp:Anywhere:Pod UDP"
    "9001/udp:Anywhere:Pod UDP 9001"
)
EXPECTED_LOCALHOST_PORTS=("80" "3000" "4000")
EXPECTED_3001_IPS=(
    "74.208.201.137:New Master USA"
    "85.215.145.173:Control2 Germany"
    "194.164.163.124:Control3 Spain"
)

# Usage
usage() {
    echo "ChillXand pNode Operator Tasks v${VERSION}"
    echo ""
    echo "Usage: $0 [-x] [-t <token>] [-S]"
    echo ""
    echo "Default mode is DRY-RUN - shows what would be done without making changes."
    echo ""
    echo "Options:"
    echo "  -x              Execute changes (default is dry-run)"
    echo "  -t <token>      Ubuntu Pro token (Section 3)"
    echo "  -S              Skip /xandeum-pages storage allocation (Section 24)"
    echo "  -h              Show this help message"
    echo ""
    echo "Sections covered:"
    echo "  Section 3:  Ubuntu Pro & LivePatch attach"
    echo "  Section 13: UFW rule verification"
    echo "  Section 22: System apt update/upgrade (excludes Xandeum packages)"
    echo "  Section 24: /xandeum-pages sparse file allocation"
    echo ""
    echo "All other hardening is applied automatically by the controller installer."
    exit 0
}

# Parse arguments
while getopts "xt:Sh" opt; do
    case $opt in
        x) DRY_RUN=false ;;
        t) PRO_TOKEN="$OPTARG" ;;
        S) SKIP_XANDEUM_PAGES=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

# ============================================
# UBUNTU 24 VALIDATION
# ============================================
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
UBUNTU_MAJOR=$(echo "$UBUNTU_VERSION" | cut -d. -f1)

if [[ "$UBUNTU_MAJOR" != "24" ]]; then
    echo -e "${RED}This script requires Ubuntu 24.x (detected: ${UBUNTU_VERSION})${NC}"
    exit 1
fi

# ============================================
# CHILLXAND USER VALIDATION
# ============================================
if ! id "chillxand" &>/dev/null; then
    echo -e "${RED}User 'chillxand' does not exist. Run the controller installer first.${NC}"
    exit 1
fi

# ============================================
# HELPER FUNCTIONS
# ============================================
log_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

log_section() {
    echo ""
    echo -e "${GREEN}▶ $1${NC}"
}

log_status() {
    echo -e "  ${YELLOW}Current:${NC} $1"
}

log_action() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}Will do:${NC} $1"
    else
        echo -e "  ${GREEN}Action:${NC} $1"
    fi
}

log_ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "  ${YELLOW}!${NC} $1"
}

log_error() {
    echo -e "  ${RED}✗${NC} $1"
}

# Helper: Fix dpkg interrupted state if detected (also done by installer; defense-in-depth here)
fix_dpkg_if_needed() {
    local audit_output
    audit_output=$(dpkg --audit 2>&1 || true)

    local needs_fix=false
    if [[ -n "$audit_output" ]]; then
        needs_fix=true
    elif ! dpkg --configure --pending --dry-run &>/dev/null; then
        needs_fix=true
    fi

    if [[ "$needs_fix" == true ]]; then
        log_warn "Detected dpkg interrupted state"
        if [[ "$DRY_RUN" == true ]]; then
            log_action "Run dpkg --configure -a to fix interrupted state"
        else
            log_action "Running dpkg --configure -a to fix interrupted state..."
            if dpkg --configure -a; then
                log_ok "dpkg interrupted state fixed"
            else
                log_error "dpkg --configure -a had errors (continuing anyway)"
            fi
        fi
        return 0
    fi
    return 1
}

# Helper: Find xandeum packages from apt (managed via /update/pod, not apt upgrade)
get_xandeum_packages() {
    apt list --installed 2>/dev/null | grep -i 'xandeum\|xandminer\|pod-package' | cut -d'/' -f1
}

# Helper: Hold xandeum packages to prevent apt upgrade from touching them
hold_xandeum_packages() {
    local held=()
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        apt-mark hold "$pkg" &>/dev/null && held+=("$pkg")
    done < <(get_xandeum_packages)
    if [[ ${#held[@]} -gt 0 ]]; then
        log_warn "Held Xandeum packages from apt upgrade: ${held[*]}"
    fi
}

# Helper: Unhold xandeum packages after apt upgrade completes
unhold_xandeum_packages() {
    local unheld=()
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        apt-mark unhold "$pkg" &>/dev/null && unheld+=("$pkg")
    done < <(get_xandeum_packages)
    if [[ ${#unheld[@]} -gt 0 ]]; then
        log_ok "Unheld Xandeum packages: ${unheld[*]}"
    fi
}

# ============================================
# MODE BANNER
# ============================================
echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                     DRY-RUN MODE                               ║${NC}"
    echo -e "${YELLOW}║         No changes will be made. Use -x to execute.            ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                     EXECUTE MODE                               ║${NC}"
    echo -e "${GREEN}║                Changes will be applied.                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "  ${BOLD}pnode-harden.sh v${VERSION}${NC}"
echo ""
echo -e "  Hostname:        $(hostname)"
echo -e "  Ubuntu:          ${UBUNTU_VERSION}"
echo -e "  Kernel:          $(uname -r)"
echo -e "  User:            chillxand ✓"
echo -e "  Disk:            $(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')"

# Show previous run info if marker exists
if [[ -f "$MARKER_FILE" ]]; then
    PREV_VERSION=$(grep "^VERSION=" "$MARKER_FILE" 2>/dev/null | cut -d= -f2)
    PREV_DATE=$(grep "^RUN_DATE=" "$MARKER_FILE" 2>/dev/null | cut -d= -f2)
    echo -e "  Last hardened:   v${PREV_VERSION} on ${PREV_DATE}"
else
    echo -e "  Last hardened:   ${YELLOW}never${NC}"
fi

# ============================================
# 1b. DPKG PRE-FLIGHT CHECK
# ============================================
log_section "DPKG Pre-flight Check"

if fix_dpkg_if_needed; then
    STATUS[dpkg_fix]="fixed"
    ACTION[dpkg_fix]="dpkg --configure -a"
else
    log_ok "dpkg state is clean"
    STATUS[dpkg_fix]="clean"
    ACTION[dpkg_fix]="none"
fi

# ============================================
# 3. UBUNTU PRO & LIVEPATCH
# ============================================
log_section "Ubuntu Pro & LivePatch"

if pro status 2>/dev/null | grep -q "Subscription: Ubuntu Pro"; then
    log_ok "Ubuntu Pro is attached"
    STATUS[ubuntu_pro]="attached"
    ACTION[ubuntu_pro]="none"
else
    log_status "Ubuntu Pro is NOT attached"
    STATUS[ubuntu_pro]="not attached"
    if [[ -n "$PRO_TOKEN" ]]; then
        log_action "Attach Ubuntu Pro with provided token"
        ACTION[ubuntu_pro]="attach"
        if [[ "$DRY_RUN" == false ]]; then
            pro attach "$PRO_TOKEN"
        fi
    else
        log_warn "No token provided (-t). Cannot attach Ubuntu Pro."
        ACTION[ubuntu_pro]="NEEDS TOKEN"
    fi
fi

# Check LivePatch
if canonical-livepatch status &>/dev/null; then
    log_ok "LivePatch is active"
    STATUS[livepatch]="active"
else
    log_status "LivePatch is not active"
    STATUS[livepatch]="not active"
fi

# ============================================
# 13. UFW VERIFICATION (read-only audit)
# ============================================
log_section "UFW Firewall Verification"

UFW_ISSUES=()

if ! command -v ufw &>/dev/null; then
    log_error "UFW not installed"
    STATUS[ufw]="not installed"
    ACTION[ufw]="MANUAL: install ufw"
else
    UFW_STATUS=$(ufw status verbose 2>/dev/null)

    if echo "$UFW_STATUS" | grep -q "Status: active"; then
        log_ok "UFW is active"

        # Check default policies
        if echo "$UFW_STATUS" | grep -q "Default:.*deny (incoming)"; then
            log_ok "Default deny incoming"
        else
            UFW_ISSUES+=("Default incoming not set to deny")
        fi

        if echo "$UFW_STATUS" | grep -q "Default:.*allow (outgoing)"; then
            log_ok "Default allow outgoing"
        else
            UFW_ISSUES+=("Default outgoing not set to allow")
        fi

        # Check required public ports
        UFW_NUMBERED=$(ufw status 2>/dev/null)

        for rule in "${EXPECTED_UFW_PORTS[@]}"; do
            port="${rule%%:*}"
            rest="${rule#*:}"
            desc="${rest##*:}"

            if echo "$UFW_NUMBERED" | grep -q "$port.*ALLOW.*Anywhere"; then
                log_ok "Port $port open ($desc)"
            else
                UFW_ISSUES+=("Port $port not open ($desc)")
            fi
        done

        # Check localhost ports
        for port in "${EXPECTED_LOCALHOST_PORTS[@]}"; do
            if echo "$UFW_NUMBERED" | grep -q "$port.*127.0.0.1"; then
                log_ok "Port $port localhost only"
            else
                UFW_ISSUES+=("Port $port should be localhost only")
            fi
        done

        # Check 3001 IP rules
        for ip_rule in "${EXPECTED_3001_IPS[@]}"; do
            ip="${ip_rule%%:*}"
            desc="${ip_rule##*:}"

            if echo "$UFW_NUMBERED" | grep -q "3001.*$ip"; then
                log_ok "Port 3001 allowed from $ip ($desc)"
            else
                UFW_ISSUES+=("Port 3001 missing rule for $ip ($desc)")
            fi
        done

        # Check 3001 deny rule
        if echo "$UFW_NUMBERED" | grep -q "3001.*DENY"; then
            log_ok "Port 3001 default deny in place"
        else
            UFW_ISSUES+=("Port 3001 missing default deny rule")
        fi

        if [[ ${#UFW_ISSUES[@]} -eq 0 ]]; then
            STATUS[ufw]="verified"
            ACTION[ufw]="none"
        else
            STATUS[ufw]="${#UFW_ISSUES[@]} issues"
            ACTION[ufw]="MANUAL FIX"
            log_warn "UFW issues found:"
            for issue in "${UFW_ISSUES[@]}"; do
                log_warn "  - $issue"
            done
        fi
    else
        log_error "UFW is not active"
        STATUS[ufw]="inactive"
        ACTION[ufw]="MANUAL: enable ufw"
    fi
fi

# ============================================
# 22. SYSTEM UPDATE
# ============================================
log_section "System Update"

if [[ "$DRY_RUN" == true ]]; then
    log_action "Run apt update && apt upgrade -y (excluding Xandeum packages)"
    ACTION[system_update]="will update"
else
    log_action "Running apt update && apt upgrade (excluding Xandeum packages)..."

    # Hold Xandeum packages so apt upgrade doesn't touch them
    hold_xandeum_packages

    apt_update_output=$(apt update 2>&1) || true
    echo "$apt_update_output"
    if echo "$apt_update_output" | grep -q "dpkg was interrupted\|dpkg --configure -a"; then
        log_warn "dpkg interrupted state detected during apt update, fixing..."
        fix_dpkg_if_needed
        apt update
    fi
    apt upgrade -y

    # Unhold Xandeum packages
    unhold_xandeum_packages

    ACTION[system_update]="completed"
fi

# ============================================
# 24. XANDEUM-PAGES STORAGE
# ============================================
if [[ "$SKIP_XANDEUM_PAGES" == true ]]; then
    log_section "Xandeum Pages Storage (SKIPPED via -S flag)"
    STATUS[xandeum_pages]="skipped"
    ACTION[xandeum_pages]="skip (-S)"
else
log_section "Xandeum Pages Storage"

XANDEUM_PAGES="/xandeum-pages"
BUFFER_GB=12
BUFFER_BYTES=$((BUFFER_GB * 1024 * 1024 * 1024))
MIN_XANDEUM_GB=50  # Minimum viable xandeum-pages size

# Detect filesystem type - ZFS/btrfs/containers don't support fallocate
ROOT_FSTYPE=$(df -T / | awk 'NR==2 {print $2}')
USE_TRUNCATE=false
if [[ "$ROOT_FSTYPE" == "zfs" || "$ROOT_FSTYPE" == "btrfs" || "$ROOT_FSTYPE" == "overlay" || "$ROOT_FSTYPE" == "fuse"* ]]; then
    USE_TRUNCATE=true
    log_status "Filesystem: $ROOT_FSTYPE (using truncate for sparse file)"
fi

# Get current free space
FREE_BYTES=$(df -B1 / | awk 'NR==2 {print $4}')
FREE_GB=$((FREE_BYTES / 1024 / 1024 / 1024))

# Get current xandeum-pages size if it exists
if [[ -f "$XANDEUM_PAGES" ]]; then
    CURRENT_BYTES=$(stat -c %s "$XANDEUM_PAGES" 2>/dev/null || echo "0")
else
    CURRENT_BYTES=0
fi
CURRENT_GB=$((CURRENT_BYTES / 1024 / 1024 / 1024))

# Dynamic calculation: use all available space minus buffer
TARGET_BYTES=$((CURRENT_BYTES + FREE_BYTES - BUFFER_BYTES))
TARGET_GB=$((TARGET_BYTES / 1024 / 1024 / 1024))

log_status "Current: ${CURRENT_GB}GB, Free: ${FREE_GB}GB, Buffer: ${BUFFER_GB}GB"

# Helper function to allocate file (uses truncate for ZFS, fallocate otherwise)
allocate_file() {
    local size="$1"
    local file="$2"
    if [[ "$USE_TRUNCATE" == true ]]; then
        truncate -s "$size" "$file"
    else
        if ! fallocate -l "$size" "$file" 2>/dev/null; then
            log_warn "fallocate failed, falling back to truncate (sparse file)"
            truncate -s "$size" "$file"
        fi
    fi
}

# Ensure target is reasonable
if [[ $TARGET_GB -lt $MIN_XANDEUM_GB ]]; then
    log_error "Insufficient space: target would be ${TARGET_GB}GB (minimum: ${MIN_XANDEUM_GB}GB)"
    log_warn "Free up space or reduce buffer"
    STATUS[xandeum_pages]="insufficient space"
    ACTION[xandeum_pages]="MANUAL"
elif [[ -f "$XANDEUM_PAGES" ]]; then
    DIFF_GB=$(( (TARGET_GB > CURRENT_GB) ? (TARGET_GB - CURRENT_GB) : (CURRENT_GB - TARGET_GB) ))

    if [[ $DIFF_GB -le 1 ]]; then
        log_ok "/xandeum-pages is ${CURRENT_GB}GB (${FREE_GB}GB free, ${BUFFER_GB}GB buffer)"
        STATUS[xandeum_pages]="${CURRENT_GB}GB"
        ACTION[xandeum_pages]="none"
    elif [[ $TARGET_GB -gt $CURRENT_GB ]]; then
        GROW_BY=$((TARGET_GB - CURRENT_GB))
        log_action "Grow /xandeum-pages by ${GROW_BY}GB (${CURRENT_GB}GB → ${TARGET_GB}GB, leaving ${BUFFER_GB}GB free)"
        STATUS[xandeum_pages]="${CURRENT_GB}GB"
        ACTION[xandeum_pages]="grow to ${TARGET_GB}GB"

        if [[ "$DRY_RUN" == false ]]; then
            allocate_file "${TARGET_BYTES}" "$XANDEUM_PAGES"
            log_ok "Grew /xandeum-pages to ${TARGET_GB}GB"
        fi
    else
        SHRINK_BY=$((CURRENT_GB - TARGET_GB))
        log_action "Shrink /xandeum-pages by ${SHRINK_BY}GB (${CURRENT_GB}GB → ${TARGET_GB}GB)"
        STATUS[xandeum_pages]="${CURRENT_GB}GB (oversized)"
        ACTION[xandeum_pages]="shrink to ${TARGET_GB}GB"

        if [[ "$DRY_RUN" == false ]]; then
            truncate -s "${TARGET_BYTES}" "$XANDEUM_PAGES"
            log_ok "Shrunk /xandeum-pages to ${TARGET_GB}GB"
        fi
    fi
else
    log_status "/xandeum-pages does not exist"
    log_action "Create /xandeum-pages at ${TARGET_GB}GB (leaving ${BUFFER_GB}GB free)"
    STATUS[xandeum_pages]="missing"
    ACTION[xandeum_pages]="create ${TARGET_GB}GB"

    if [[ "$DRY_RUN" == false ]]; then
        allocate_file "${TARGET_BYTES}" "$XANDEUM_PAGES"
        chmod 600 "$XANDEUM_PAGES"
        chown root:root "$XANDEUM_PAGES"
        log_ok "Created /xandeum-pages at ${TARGET_GB}GB"
    fi
fi
fi # end SKIP_XANDEUM_PAGES

# ============================================
# 25. WRITE VERSION MARKER
# ============================================
if [[ "$DRY_RUN" == false ]]; then
    log_section "Writing Version Marker"
    mkdir -p "$MARKER_DIR"
    cat > "$MARKER_FILE" << EOF
VERSION=${VERSION}
RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)
EOF
    chmod 644 "$MARKER_FILE"
    log_ok "Marker written to $MARKER_FILE"
fi

# ============================================
# SUMMARY
# ============================================
log_header "SUMMARY - pnode-harden.sh v${VERSION}"

echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}${BOLD}DRY-RUN MODE - No changes were made${NC}"
    echo -e "${YELLOW}Run with -x flag to execute these changes${NC}"
else
    echo -e "${GREEN}${BOLD}EXECUTE MODE - Changes applied${NC}"
    echo -e "${GREEN}Version ${VERSION} recorded in ${MARKER_FILE}${NC}"
fi

echo ""
echo -e "${BOLD}Component                 Status               Action${NC}"
echo "─────────────────────────────────────────────────────────────────"
printf "%-25s %-20s %s\n" "DPKG state" "${STATUS[dpkg_fix]:-unknown}" "${ACTION[dpkg_fix]:-check}"
printf "%-25s %-20s %s\n" "Ubuntu Pro" "${STATUS[ubuntu_pro]:-unknown}" "${ACTION[ubuntu_pro]:-check}"
printf "%-25s %-20s %s\n" "LivePatch" "${STATUS[livepatch]:-unknown}" "-"
printf "%-25s %-20s %s\n" "UFW Firewall" "${STATUS[ufw]:-unknown}" "${ACTION[ufw]:-check}"
printf "%-25s %-20s %s\n" "Xandeum Pages" "${STATUS[xandeum_pages]:-unknown}" "${ACTION[xandeum_pages]:-check}"
printf "%-25s %-20s %s\n" "System Update" "-" "${ACTION[system_update]:-will update}"

echo ""

# Warnings
if [[ "${ACTION[ubuntu_pro]}" == "NEEDS TOKEN" ]]; then
    echo -e "${YELLOW}⚠ Ubuntu Pro requires token: https://ubuntu.com/pro/dashboard${NC}"
    echo -e "${YELLOW}  Run: $0 -x -t 'YOUR_TOKEN'${NC}"
    echo ""
fi

if [[ "${ACTION[ufw]}" == "MANUAL FIX" ]]; then
    echo -e "${YELLOW}⚠ UFW has configuration issues - review above${NC}"
    echo ""
fi

# Disk usage
echo -e "${BOLD}Disk Usage:${NC}"
df -h / | awk 'NR==2 {print "  " $3 " used / " $2 " total (" $5 ")"}'
echo ""

# Top consumers
echo -e "${BOLD}Top Disk Consumers:${NC}"
du -sh /* 2>/dev/null | sort -h | tail -5 | while read line; do
    echo "  $line"
done
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${CYAN}To apply these changes, run:${NC}"
    if [[ "${ACTION[ubuntu_pro]}" == "NEEDS TOKEN" ]]; then
        echo -e "  ${BOLD}sudo $0 -x -t 'YOUR_UBUNTU_PRO_TOKEN'${NC}"
    else
        echo -e "  ${BOLD}sudo $0 -x${NC}"
    fi
    echo ""
fi
