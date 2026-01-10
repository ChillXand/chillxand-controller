#!/bin/bash
#
# ChillXand pNode Hardening Script (pnode-harden.sh)
# Hardens and optimizes Ubuntu 24 servers for pNode operation
#
# Default: DRY-RUN mode (shows what would be done)
# Use -x flag to actually execute changes
#

set -e

# Version
VERSION="1.0.9"
SCRIPT_URL="https://raw.githubusercontent.com/chillxand/chillxand-controller/main/pnode-harden.sh"
INSTALL_PATH="/usr/local/bin/pnode-harden"
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

# Summary tracking
declare -A STATUS
declare -A ACTION

# Expected UFW rules
EXPECTED_UFW_PORTS=(
    "22/tcp:Anywhere:SSH"
    "5000/udp:Anywhere:Pod UDP"
    "9001/udp:Anywhere:Pod UDP 9001"
)
EXPECTED_LOCALHOST_PORTS=("80" "3000" "4000" "8000")
EXPECTED_3001_IPS=(
    "74.208.234.116:Master USA"
    "85.215.145.173:Control2 Germany"
    "194.164.163.124:Control3 Spain"
)

# Usage
usage() {
    echo "ChillXand pNode Hardening Script v${VERSION}"
    echo ""
    echo "Usage: $0 [-x] [-u] [-t <token>]"
    echo ""
    echo "Default mode is DRY-RUN - shows what would be changed without making changes."
    echo ""
    echo "Options:"
    echo "  -x              Execute changes (default is dry-run)"
    echo "  -u              Update to latest version from GitHub"
    echo "  -t <token>      Ubuntu Pro token (optional, required only if Pro not attached)"
    echo "  -h              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Dry-run, see what would change"
    echo "  $0 -x           # Execute (if Ubuntu Pro already attached)"
    echo "  $0 -u           # Update script to latest version"
    echo "  $0 -x -t 'C1xxx...'  # Execute with Ubuntu Pro token"
    exit 0
}

# Self-update function
self_update() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              pnode-harden Self-Update                          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Current version: ${BOLD}v${VERSION}${NC}"
    echo ""
    
    # Download to temp file
    TEMP_FILE=$(mktemp)
    
    echo -e "  ${CYAN}Downloading latest version...${NC}"
    
    if command -v curl &>/dev/null; then
        if ! curl -sSL "$SCRIPT_URL" -o "$TEMP_FILE" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} Failed to download update"
            rm -f "$TEMP_FILE"
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -qO "$TEMP_FILE" "$SCRIPT_URL" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} Failed to download update"
            rm -f "$TEMP_FILE"
            exit 1
        fi
    else
        echo -e "  ${RED}✗${NC} Neither curl nor wget found"
        exit 1
    fi
    
    # Verify download
    if [[ ! -s "$TEMP_FILE" ]]; then
        echo -e "  ${RED}✗${NC} Downloaded file is empty"
        rm -f "$TEMP_FILE"
        exit 1
    fi
    
    # Check it's a valid bash script
    if ! head -1 "$TEMP_FILE" | grep -q "^#!/bin/bash"; then
        echo -e "  ${RED}✗${NC} Downloaded file is not a valid bash script"
        rm -f "$TEMP_FILE"
        exit 1
    fi
    
    # Get new version
    NEW_VERSION=$(grep -oP '^VERSION="\K[^"]+' "$TEMP_FILE" | head -1 || echo "unknown")
    
    if [[ "$NEW_VERSION" == "$VERSION" ]]; then
        echo -e "  ${GREEN}✓${NC} Already running latest version (v${VERSION})"
        rm -f "$TEMP_FILE"
        exit 0
    fi
    
    echo -e "  ${GREEN}✓${NC} New version available: ${BOLD}v${NEW_VERSION}${NC}"
    
    # Determine install location
    SCRIPT_PATH="$0"
    if [[ "$SCRIPT_PATH" == "/usr/local/bin/pnode-harden" ]]; then
        INSTALL_TARGET="$SCRIPT_PATH"
    elif [[ -f "$INSTALL_PATH" ]]; then
        INSTALL_TARGET="$INSTALL_PATH"
    else
        INSTALL_TARGET="$INSTALL_PATH"
    fi
    
    echo -e "  ${CYAN}Installing to:${NC} $INSTALL_TARGET"
    
    # Install
    mv "$TEMP_FILE" "$INSTALL_TARGET"
    chmod +x "$INSTALL_TARGET"
    
    echo ""
    echo -e "  ${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  Updated: v${VERSION} → v${NEW_VERSION}                               ${NC}"
    echo -e "  ${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    exit 0
}

# Parse arguments
DO_UPDATE=false
while getopts "xut:h" opt; do
    case $opt in
        x) DRY_RUN=false ;;
        u) DO_UPDATE=true ;;
        t) PRO_TOKEN="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Handle update before root check (update needs root but we want nice error)
if [[ "$DO_UPDATE" == true ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: Update requires root (use sudo)${NC}"
        exit 1
    fi
    self_update
fi

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
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  ██████╗ ██████╗ ██████╗ ██████╗ ██████╗ ██╗                   ║${NC}"
    echo -e "${RED}║  ██╔═══╝ ██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██║                  ║${NC}"
    echo -e "${RED}║  █████╗  ██████╔╝██████╔╝██║   ██║██████╔╝██║                  ║${NC}"
    echo -e "${RED}║  ██╔══╝  ██╔══██╗██╔══██╗██║   ██║██╔══██╗╚═╝                  ║${NC}"
    echo -e "${RED}║  ██████╗ ██║  ██║██║  ██║╚██████╔╝██║  ██║██╗                  ║${NC}"
    echo -e "${RED}║  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝                  ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║            THIS SCRIPT REQUIRES UBUNTU 24.x                    ║${NC}"
    echo -e "${RED}║            Detected version: ${UBUNTU_VERSION}                             ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    exit 1
fi

# ============================================
# CHILLXAND USER VALIDATION
# ============================================
if ! id "chillxand" &>/dev/null; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  ██████╗ ██████╗ ██████╗ ██████╗ ██████╗ ██╗                   ║${NC}"
    echo -e "${RED}║  ██╔═══╝ ██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██║                  ║${NC}"
    echo -e "${RED}║  █████╗  ██████╔╝██████╔╝██║   ██║██████╔╝██║                  ║${NC}"
    echo -e "${RED}║  ██╔══╝  ██╔══██╗██╔══██╗██║   ██║██╔══██╗╚═╝                  ║${NC}"
    echo -e "${RED}║  ██████╗ ██║  ██║██║  ██║╚██████╔╝██║  ██║██╗                  ║${NC}"
    echo -e "${RED}║  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝                  ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║            USER 'chillxand' DOES NOT EXIST                     ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  This script requires the 'chillxand' user to exist.           ║${NC}"
    echo -e "${RED}║  Please create the user first or run the pNode installer.      ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
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
# 1. CHILLXAND USER SUDO
# ============================================
log_section "ChillXand User Sudo Privileges"

log_ok "User 'chillxand' exists"

# Check sudo group
if groups chillxand 2>/dev/null | grep -q sudo; then
    log_ok "User 'chillxand' is in sudo group"
    STATUS[chillxand_user]="has sudo"
    ACTION[chillxand_user]="none"
else
    log_status "User 'chillxand' not in sudo group"
    log_action "Add 'chillxand' to sudo group"
    STATUS[chillxand_user]="no sudo group"
    ACTION[chillxand_user]="add to sudo"
    if [[ "$DRY_RUN" == false ]]; then
        usermod -aG sudo chillxand
    fi
fi

# Check passwordless sudo
SUDOERS_FILE="/etc/sudoers.d/chillxand"
if [[ -f "$SUDOERS_FILE" ]] && grep -q "NOPASSWD" "$SUDOERS_FILE" 2>/dev/null; then
    log_ok "Passwordless sudo configured"
else
    log_status "Passwordless sudo not configured"
    log_action "Configure passwordless sudo for chillxand"
    if [[ "$DRY_RUN" == false ]]; then
        echo "chillxand ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
    fi
fi

# ============================================
# 2. UPDATE NOTIFIER
# ============================================
log_section "Update Notifier"

if dpkg -l 2>/dev/null | grep -q update-notifier-common; then
    log_ok "update-notifier-common is installed"
    STATUS[update_notifier]="installed"
    ACTION[update_notifier]="none"
else
    log_status "update-notifier-common is NOT installed"
    log_action "Install update-notifier-common"
    STATUS[update_notifier]="not installed"
    ACTION[update_notifier]="install"
    if [[ "$DRY_RUN" == false ]]; then
        apt update && apt install update-notifier-common -y
    fi
fi

# ============================================
# 3. UBUNTU PRO & LIVEPATCH
# ============================================
log_section "Ubuntu Pro & LivePatch"

# Check for enabled Pro services OR Account line (both prove Pro is attached)
if pro status 2>/dev/null | grep -qE "(^(esm-|livepatch)[[:space:]]+yes[[:space:]]+enabled|^Account:)"; then
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
# 4. UNATTENDED UPGRADES
# ============================================
log_section "Unattended Upgrades"

UNATTENDED_CONF="/etc/apt/apt.conf.d/99-chillxand-unattended.conf"

# Ensure package is installed
if dpkg -l 2>/dev/null | grep -q "unattended-upgrades"; then
    log_ok "unattended-upgrades package is installed"
    STATUS[unattended_pkg]="installed"
else
    log_status "unattended-upgrades is NOT installed"
    log_action "Install unattended-upgrades"
    STATUS[unattended_pkg]="not installed"
    if [[ "$DRY_RUN" == false ]]; then
        apt update
        apt install unattended-upgrades -y
        echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
        dpkg-reconfigure -f noninteractive unattended-upgrades
    fi
fi

# Define our desired config
read -r -d '' DESIRED_UNATTENDED_CONFIG << 'EOF' || true
// ChillXand pNode Unattended Upgrades Configuration
// This file overrides settings in 50unattended-upgrades

// Enable updates from these origins
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Cleanup settings
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Don't auto-reboot - pNode needs to stay running
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# Check if our config file exists and matches
if [[ -f "$UNATTENDED_CONF" ]]; then
    # Check if key settings are present
    if grep -q "Remove-Unused-Kernel-Packages.*true" "$UNATTENDED_CONF" && \
       grep -q "Remove-Unused-Dependencies.*true" "$UNATTENDED_CONF" && \
       grep -q "Automatic-Reboot.*false" "$UNATTENDED_CONF" && \
       grep -q "distro_codename}-updates" "$UNATTENDED_CONF"; then
        log_ok "ChillXand unattended config is in place"
        log_ok "Origins: security, updates, ESM enabled"
        log_ok "Remove-Unused-Kernel-Packages = true"
        log_ok "Remove-Unused-Dependencies = true"
        log_ok "Automatic-Reboot = false"
        STATUS[unattended_conf]="configured"
        ACTION[unattended_conf]="none"
    else
        log_status "ChillXand unattended config exists but incomplete"
        log_action "Update unattended config"
        STATUS[unattended_conf]="incomplete"
        ACTION[unattended_conf]="update"
        if [[ "$DRY_RUN" == false ]]; then
            echo "$DESIRED_UNATTENDED_CONFIG" > "$UNATTENDED_CONF"
        fi
    fi
else
    log_status "ChillXand unattended config not present"
    log_action "Create /etc/apt/apt.conf.d/99-chillxand-unattended.conf"
    STATUS[unattended_conf]="missing"
    ACTION[unattended_conf]="create"
    if [[ "$DRY_RUN" == false ]]; then
        echo "$DESIRED_UNATTENDED_CONFIG" > "$UNATTENDED_CONF"
        log_ok "Created $UNATTENDED_CONF"
    fi
fi

# ============================================
# 5. LOGROTATE
# ============================================
log_section "Logrotate (Space Optimization)"

LOGROTATE_CONF="/etc/logrotate.conf"
CURRENT_ROTATE=$(grep -E "^rotate " "$LOGROTATE_CONF" 2>/dev/null | awk '{print $2}' || echo "not set")
CURRENT_INTERVAL=$(grep -E "^(daily|weekly|monthly)" "$LOGROTATE_CONF" 2>/dev/null | head -1 || echo "not set")

# Check for compress (just check if line exists, don't output it)
if grep -qE "^compress" "$LOGROTATE_CONF" 2>/dev/null; then
    CURRENT_COMPRESS="yes"
else
    CURRENT_COMPRESS="no"
fi

if [[ "$CURRENT_INTERVAL" == "daily" && "$CURRENT_ROTATE" == "3" && "$CURRENT_COMPRESS" == "yes" ]]; then
    log_ok "Logrotate optimized (daily, 3 days, compressed)"
    STATUS[logrotate]="optimized"
    ACTION[logrotate]="none"
else
    log_status "Interval: $CURRENT_INTERVAL, Rotate: $CURRENT_ROTATE, Compress: $CURRENT_COMPRESS"
    log_action "Set to daily, 3 days retention, compressed"
    STATUS[logrotate]="not optimized"
    ACTION[logrotate]="configure"
    if [[ "$DRY_RUN" == false ]]; then
        [[ ! -f "${LOGROTATE_CONF}.backup" ]] && cp "$LOGROTATE_CONF" "${LOGROTATE_CONF}.backup"
        cat > "$LOGROTATE_CONF" << 'EOF'
# ChillXand pNode optimized logrotate configuration
daily
su root adm
rotate 3
create
compress
delaycompress
maxage 3
include /etc/logrotate.d
EOF
    fi
fi

# ============================================
# 6. JOURNALD CONFIGURATION
# ============================================
log_section "Journald Configuration"

JOURNALD_CONF="/etc/systemd/journald.conf"

# Check if already configured with our settings
if grep -q "^SystemMaxUse=200M" "$JOURNALD_CONF" 2>/dev/null; then
    log_ok "Journald already configured with size limits"
    STATUS[journald]="configured"
    ACTION[journald]="none"
else
    log_status "Journald not configured with size limits"
    log_action "Set journal limits (200M max, 3 days retention)"
    STATUS[journald]="not configured"
    ACTION[journald]="configure"
    if [[ "$DRY_RUN" == false ]]; then
        [[ ! -f "${JOURNALD_CONF}.backup" ]] && cp "$JOURNALD_CONF" "${JOURNALD_CONF}.backup"
        cat > "$JOURNALD_CONF" << 'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
SystemMaxFiles=5
MaxRetentionSec=3d
RuntimeMaxUse=50M
EOF
        systemctl restart systemd-journald
    fi
fi

# ============================================
# 7. SPACE OPTIMIZATION
# ============================================
log_section "Space Optimization Settings"

# Apport
if systemctl is-enabled apport &>/dev/null; then
    log_status "Apport (crash reporter) is enabled"
    log_action "Disable apport"
    STATUS[apport]="enabled"
    if [[ "$DRY_RUN" == false ]]; then
        systemctl disable apport
        systemctl stop apport 2>/dev/null || true
    fi
else
    log_ok "Apport is already disabled"
    STATUS[apport]="disabled"
fi

# APT cache config
APT_CACHE_CONF="/etc/apt/apt.conf.d/70debconf"
if [[ -f "$APT_CACHE_CONF" ]] && grep -q "Cache-Limit" "$APT_CACHE_CONF" 2>/dev/null; then
    log_ok "APT cache limits configured"
    STATUS[apt_cache]="configured"
else
    log_status "APT cache limits not configured"
    log_action "Set APT cache limits"
    STATUS[apt_cache]="not configured"
    if [[ "$DRY_RUN" == false ]]; then
        cat > "$APT_CACHE_CONF" << 'EOF'
APT::Cache-Limit "100000000";
APT::Cache-Start "100000000";
EOF
    fi
fi

# APT periodic autoclean
APT_PERIODIC_CONF="/etc/apt/apt.conf.d/02periodic"
if [[ -f "$APT_PERIODIC_CONF" ]] && grep -q "AutocleanInterval" "$APT_PERIODIC_CONF" 2>/dev/null; then
    log_ok "APT weekly autoclean configured"
    STATUS[apt_autoclean]="configured"
else
    log_status "APT autoclean not configured"
    log_action "Enable weekly APT autoclean"
    STATUS[apt_autoclean]="not configured"
    if [[ "$DRY_RUN" == false ]]; then
        echo 'APT::Periodic::AutocleanInterval "7";' > "$APT_PERIODIC_CONF"
    fi
fi

# ============================================
# 8. REMOVE EXTRA LOCALES
# ============================================
log_section "Locale Cleanup"

LOCALE_ARCHIVE="/usr/lib/locale/locale-archive"
if [[ -f "$LOCALE_ARCHIVE" ]]; then
    LOCALE_SIZE=$(du -h "$LOCALE_ARCHIVE" 2>/dev/null | awk '{print $1}')
    LOCALE_COUNT=$(locale -a 2>/dev/null | wc -l)
    
    if [[ $LOCALE_COUNT -gt 10 ]]; then
        log_status "Found $LOCALE_COUNT locales ($LOCALE_SIZE)"
        log_action "Keep only en_US.UTF-8, remove others"
        STATUS[locales]="$LOCALE_COUNT locales"
        ACTION[locales]="cleanup"
        
        if [[ "$DRY_RUN" == false ]]; then
            # Install localepurge if not present
            if ! command -v localepurge &>/dev/null; then
                echo "localepurge localepurge/nopurge multiselect en, en_US, en_US.UTF-8" | debconf-set-selections
                echo "localepurge localepurge/use-dpkg-feature boolean true" | debconf-set-selections
                DEBIAN_FRONTEND=noninteractive apt install -y localepurge
            fi
            # Configure to keep only English
            cat > /etc/locale.nopurge << 'EOF'
MANDELETE
DONTBOTHERNEWLOCALE
SHOWFREEDSPACE
en
en_US
en_US.UTF-8
EOF
            # Run localepurge to clean package locale files
            localepurge 2>/dev/null || true
            
            # Check if locales were actually cleaned
            NEW_LOCALE_COUNT=$(locale -a 2>/dev/null | wc -l)
            if [[ $NEW_LOCALE_COUNT -gt 10 ]]; then
                # Fallback: regenerate locale archive with only en_US.UTF-8
                log_warn "localepurge insufficient ($NEW_LOCALE_COUNT locales), using locale-gen --purge"
                sed -i '/^[^#]/d' /etc/locale.gen 2>/dev/null || true
                echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
                locale-gen --purge en_US.UTF-8 2>/dev/null || true
            fi
        fi
    else
        log_ok "Locales already minimal ($LOCALE_COUNT)"
        STATUS[locales]="minimal"
        ACTION[locales]="none"
    fi
else
    log_ok "No locale archive found"
    STATUS[locales]="none"
    ACTION[locales]="none"
fi

# ============================================
# 9. REMOVE MAN PAGES/DOCS
# ============================================
log_section "Documentation Cleanup"

DOC_SIZE=$(du -sh /usr/share/doc 2>/dev/null | awk '{print $1}' || echo "0")
MAN_SIZE=$(du -sh /usr/share/man 2>/dev/null | awk '{print $1}' || echo "0")

# Check if already configured to not install docs
if [[ -f /etc/dpkg/dpkg.cfg.d/01_nodoc ]]; then
    log_ok "Already configured to skip docs on install"
    STATUS[docs]="configured"
    ACTION[docs]="none"
else
    log_status "Docs: $DOC_SIZE, Man pages: $MAN_SIZE"
    log_action "Remove existing docs and prevent future installs"
    STATUS[docs]="$DOC_SIZE + $MAN_SIZE"
    ACTION[docs]="cleanup"
    
    if [[ "$DRY_RUN" == false ]]; then
        # Remove existing docs
        rm -rf /usr/share/doc/*
        rm -rf /usr/share/man/*
        rm -rf /usr/share/info/*
        rm -rf /usr/share/lintian/*
        
        # Prevent future doc installs
        cat > /etc/dpkg/dpkg.cfg.d/01_nodoc << 'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
EOF
    fi
fi

# ============================================
# 10. TMPFS FOR /tmp
# ============================================
log_section "tmpfs for /tmp"

if mount | grep -q "tmpfs on /tmp"; then
    log_ok "/tmp is already tmpfs"
    STATUS[tmpfs]="enabled"
    ACTION[tmpfs]="none"
elif grep -q "^tmpfs.*/tmp" /etc/fstab 2>/dev/null; then
    log_ok "/tmp tmpfs configured (will apply on reboot)"
    STATUS[tmpfs]="configured"
    ACTION[tmpfs]="none"
else
    log_status "/tmp is on disk"
    log_action "Configure /tmp as tmpfs (applies on reboot)"
    STATUS[tmpfs]="on disk"
    ACTION[tmpfs]="configure"
    if [[ "$DRY_RUN" == false ]]; then
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=256M 0 0" >> /etc/fstab
    fi
fi

# ============================================
# 11. CLEANUP CRON JOB
# ============================================
log_section "Cleanup Cron Job"

CLEANUP_SCRIPT="/usr/local/bin/cleanup-logs"
CRON_FILE="/etc/cron.d/chillxand-cleanup"

# Ensure cron is installed
if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null; then
    log_status "Cron not installed"
    log_action "Install cron package"
    if [[ "$DRY_RUN" == false ]]; then
        apt update
        apt install -y cron
        systemctl enable cron
        systemctl start cron
    fi
else
    log_ok "Cron is installed"
fi

if [[ -f "$CLEANUP_SCRIPT" && -f "$CRON_FILE" ]]; then
    log_ok "Cleanup script and cron job exist"
    STATUS[cleanup_cron]="configured"
    ACTION[cleanup_cron]="none"
else
    log_status "Cleanup script/cron not configured"
    log_action "Create cleanup script and daily 3 AM cron job"
    STATUS[cleanup_cron]="not configured"
    ACTION[cleanup_cron]="create"
    
    if [[ "$DRY_RUN" == false ]]; then
        cat > "$CLEANUP_SCRIPT" << 'EOF'
#!/bin/bash
# ChillXand pNode Log Cleanup Script

# System journal cleanup
journalctl --vacuum-time=3d
journalctl --vacuum-size=200M

# Pod logs cleanup - keep last 3 days, compress old ones
POD_LOGS_DIR="/root/pod-logs"
if [[ -d "$POD_LOGS_DIR" ]]; then
    # Compress logs older than 1 day
    find "$POD_LOGS_DIR" -type f -name "*.log" -mtime +1 -exec gzip -f {} \; 2>/dev/null || true
    # Delete compressed logs older than 3 days
    find "$POD_LOGS_DIR" -type f -name "*.gz" -mtime +3 -delete 2>/dev/null || true
    # Delete any logs older than 7 days regardless of type
    find "$POD_LOGS_DIR" -type f -mtime +7 -delete 2>/dev/null || true
fi

# APT cleanup
apt autoremove -y
apt autoclean

# Temp files cleanup
find /tmp -type f -atime +1 -delete 2>/dev/null || true
find /var/tmp -type f -atime +1 -delete 2>/dev/null || true

# Clear user caches
rm -rf /root/.npm /root/.cache 2>/dev/null || true

logger "ChillXand cleanup completed"
EOF
        chmod +x "$CLEANUP_SCRIPT"
        
        echo "# ChillXand daily cleanup - runs at 3 AM" > "$CRON_FILE"
        echo "0 3 * * * root /usr/local/bin/cleanup-logs" >> "$CRON_FILE"
        echo "" >> "$CRON_FILE"
        chmod 644 "$CRON_FILE"
    fi
fi

# ============================================
# 12. FAIL2BAN
# ============================================
log_section "Fail2ban"

if command -v fail2ban-client &>/dev/null && systemctl is-active fail2ban &>/dev/null; then
    log_ok "Fail2ban is installed and running"
    STATUS[fail2ban]="active"
    ACTION[fail2ban]="none"
elif dpkg -l 2>/dev/null | grep -q "fail2ban"; then
    log_status "Fail2ban installed but not running"
    log_action "Enable and start fail2ban"
    STATUS[fail2ban]="installed"
    ACTION[fail2ban]="enable"
    if [[ "$DRY_RUN" == false ]]; then
        systemctl enable fail2ban
        systemctl start fail2ban
    fi
else
    log_status "Fail2ban not installed"
    log_action "Install and configure fail2ban"
    STATUS[fail2ban]="not installed"
    ACTION[fail2ban]="install"
    
    if [[ "$DRY_RUN" == false ]]; then
        apt update
        apt install -y fail2ban
        
        # Create local jail config
        cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port    = ssh
filter  = sshd
maxretry = 3
EOF
        systemctl enable fail2ban
        systemctl start fail2ban
    fi
fi

# ============================================
# 13. UFW FIREWALL
# ============================================
log_section "UFW Firewall"

UFW_CHANGES_MADE=false

# Install UFW if not present
if ! command -v ufw &>/dev/null; then
    log_status "UFW not installed"
    log_action "Install UFW"
    if [[ "$DRY_RUN" == false ]]; then
        apt update
        apt install -y ufw
    fi
    UFW_CHANGES_MADE=true
else
    log_ok "UFW is installed"
fi

# Get current status
UFW_STATUS=$(ufw status verbose 2>/dev/null)
UFW_RULES=$(ufw status numbered 2>/dev/null)

# Check if UFW is active
if ! echo "$UFW_STATUS" | grep -q "Status: active"; then
    log_status "UFW is not active"
    log_action "Enable UFW (will ensure SSH is allowed first)"
    if [[ "$DRY_RUN" == false ]]; then
        # CRITICAL: Allow SSH before enabling UFW to prevent lockout
        ufw allow 22/tcp comment 'SSH'
        # Set default policies
        ufw default deny incoming
        ufw default allow outgoing
        # Enable UFW non-interactively
        echo "y" | ufw enable
        UFW_CHANGES_MADE=true
        # Refresh status
        UFW_STATUS=$(ufw status verbose 2>/dev/null)
        UFW_RULES=$(ufw status numbered 2>/dev/null)
    fi
else
    log_ok "UFW is active"
fi

# Check and fix default policies
if ! echo "$UFW_STATUS" | grep -q "Default:.*deny (incoming)"; then
    log_status "Default incoming policy is not 'deny'"
    log_action "Set default incoming to deny"
    if [[ "$DRY_RUN" == false ]]; then
        ufw default deny incoming
        UFW_CHANGES_MADE=true
    fi
else
    log_ok "Default deny incoming"
fi

if ! echo "$UFW_STATUS" | grep -q "Default:.*allow (outgoing)"; then
    log_status "Default outgoing policy is not 'allow'"
    log_action "Set default outgoing to allow"
    if [[ "$DRY_RUN" == false ]]; then
        ufw default allow outgoing
        UFW_CHANGES_MADE=true
    fi
else
    log_ok "Default allow outgoing"
fi

# Check and add public port rules
for rule in "${EXPECTED_UFW_PORTS[@]}"; do
    port="${rule%%:*}"
    rest="${rule#*:}"
    desc="${rest##*:}"
    
    if echo "$UFW_RULES" | grep -q "$port.*ALLOW.*Anywhere"; then
        log_ok "Port $port open ($desc)"
    else
        log_status "Port $port not open ($desc)"
        log_action "Allow $port from anywhere"
        if [[ "$DRY_RUN" == false ]]; then
            ufw allow "$port" comment "$desc"
            UFW_CHANGES_MADE=true
        fi
    fi
done

# Check and add localhost-only rules
for port in "${EXPECTED_LOCALHOST_PORTS[@]}"; do
    if echo "$UFW_RULES" | grep -q "$port.*ALLOW.*127.0.0.1"; then
        log_ok "Port $port localhost only"
    else
        log_status "Port $port not restricted to localhost"
        log_action "Allow port $port from localhost only"
        if [[ "$DRY_RUN" == false ]]; then
            # First, delete any existing rules for this port that allow from anywhere
            # We need to be careful here - get rule numbers and delete from highest to lowest
            RULE_NUMS=$(ufw status numbered 2>/dev/null | grep -E "^\[.*\].*$port" | grep -v "127.0.0.1" | sed 's/\[\s*\([0-9]*\)\].*/\1/' | sort -rn)
            for num in $RULE_NUMS; do
                echo "y" | ufw delete "$num" 2>/dev/null || true
            done
            # Now add the localhost-only rule
            ufw allow from 127.0.0.1 to any port "$port" comment "Localhost only"
            UFW_CHANGES_MADE=true
        fi
    fi
done

# Check and add 3001 IP-specific rules
for ip_rule in "${EXPECTED_3001_IPS[@]}"; do
    ip="${ip_rule%%:*}"
    desc="${ip_rule##*:}"
    
    if echo "$UFW_RULES" | grep -q "3001.*ALLOW.*$ip"; then
        log_ok "Port 3001 allowed from $ip ($desc)"
    else
        log_status "Port 3001 missing rule for $ip ($desc)"
        log_action "Allow 3001 from $ip"
        if [[ "$DRY_RUN" == false ]]; then
            ufw allow from "$ip" to any port 3001 comment "$desc"
            UFW_CHANGES_MADE=true
        fi
    fi
done

# Check and add 3001 deny rule (must come after allow rules)
if echo "$UFW_RULES" | grep -q "3001.*DENY"; then
    log_ok "Port 3001 default deny in place"
else
    log_status "Port 3001 missing default deny rule"
    log_action "Add deny rule for port 3001"
    if [[ "$DRY_RUN" == false ]]; then
        ufw deny 3001 comment "Deny all other 3001 access"
        UFW_CHANGES_MADE=true
    fi
fi

# Set final status
if [[ "$UFW_CHANGES_MADE" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        STATUS[ufw]="needs config"
        ACTION[ufw]="configure"
    else
        STATUS[ufw]="configured"
        ACTION[ufw]="updated"
        # Reload to apply changes
        ufw reload
    fi
else
    STATUS[ufw]="verified"
    ACTION[ufw]="none"
fi

# ============================================
# 14. KERNEL SYSCTL HARDENING & NETWORK TUNING
# ============================================
log_section "Kernel Sysctl Hardening & Network Tuning"

SYSCTL_CONF="/etc/sysctl.d/99-chillxand-hardening.conf"

# Define the desired sysctl configuration
read -r -d '' DESIRED_SYSCTL_CONFIG << 'EOF' || true
# ChillXand pNode Kernel Hardening

# Disable IP forwarding (not a router)
net.ipv4.ip_forward = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable SYN cookies (SYN flood protection)
net.ipv4.tcp_syncookies = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Restrict kernel pointer exposure
kernel.kptr_restrict = 2

# Restrict dmesg access
kernel.dmesg_restrict = 1

# Disable magic SysRq key
kernel.sysrq = 0

# ═══════════════════════════════════════════
# NETWORK PERFORMANCE (Critical for pNode UDP)
# ═══════════════════════════════════════════

# Increase UDP buffer sizes (prevents RcvbufErrors)
net.core.rmem_max = 26214400
net.core.rmem_default = 26214400
net.core.wmem_max = 26214400
net.core.wmem_default = 26214400

# Increase connection tracking limit
net.netfilter.nf_conntrack_max = 262144

# Reduce swappiness (prefer RAM over swap)
vm.swappiness = 10

# Increase local port range
net.ipv4.ip_local_port_range = 1024 65535

# Reuse TIME_WAIT sockets faster
net.ipv4.tcp_tw_reuse = 1

# Increase socket backlog for high connection rates
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
EOF

# Check if file exists and compare contents
if [[ -f "$SYSCTL_CONF" ]]; then
    CURRENT_SYSCTL=$(cat "$SYSCTL_CONF")
    if [[ "$CURRENT_SYSCTL" == "$DESIRED_SYSCTL_CONFIG" ]]; then
        log_ok "Kernel hardening & network tuning already configured"
        STATUS[sysctl]="configured"
        ACTION[sysctl]="none"
    else
        log_status "Sysctl config exists but differs from expected"
        log_action "Update sysctl config (adds network tuning)"
        STATUS[sysctl]="outdated"
        ACTION[sysctl]="update"
        if [[ "$DRY_RUN" == false ]]; then
            echo "$DESIRED_SYSCTL_CONFIG" > "$SYSCTL_CONF"
            sysctl -p "$SYSCTL_CONF" 2>/dev/null || true
            log_ok "Updated sysctl config and applied settings"
        fi
    fi
else
    log_status "Kernel hardening not configured"
    log_action "Apply sysctl security and network tuning settings"
    STATUS[sysctl]="not configured"
    ACTION[sysctl]="configure"
    
    if [[ "$DRY_RUN" == false ]]; then
        echo "$DESIRED_SYSCTL_CONFIG" > "$SYSCTL_CONF"
        sysctl -p "$SYSCTL_CONF" 2>/dev/null || true
        log_ok "Created sysctl config and applied settings"
    fi
fi

# ============================================
# 15. DISABLE UNCOMMON NETWORK PROTOCOLS
# ============================================
log_section "Disable Uncommon Network Protocols"

MODPROBE_CONF="/etc/modprobe.d/chillxand-blacklist-protocols.conf"
BLACKLIST_PROTOCOLS=("dccp" "sctp" "rds" "tipc")

if [[ -f "$MODPROBE_CONF" ]]; then
    log_ok "Uncommon network protocols already blacklisted"
    STATUS[net_protocols]="blacklisted"
    ACTION[net_protocols]="none"
else
    log_status "Uncommon protocols not blacklisted"
    log_action "Blacklist DCCP, SCTP, RDS, TIPC"
    STATUS[net_protocols]="not blacklisted"
    ACTION[net_protocols]="blacklist"
    
    if [[ "$DRY_RUN" == false ]]; then
        cat > "$MODPROBE_CONF" << 'EOF'
# ChillXand pNode - Disable uncommon network protocols
# These are rarely used and reduce attack surface

# Datagram Congestion Control Protocol
install dccp /bin/true
blacklist dccp

# Stream Control Transmission Protocol
install sctp /bin/true
blacklist sctp

# Reliable Datagram Sockets
install rds /bin/true
blacklist rds

# Transparent Inter-Process Communication
install tipc /bin/true
blacklist tipc
EOF
    fi
fi

# ============================================
# 16. SECURE SHARED MEMORY
# ============================================
log_section "Secure Shared Memory"

# Check if /run/shm is mounted with security options
if mount | grep -q "/run/shm.*noexec.*nosuid.*nodev"; then
    log_ok "/run/shm already secured (noexec,nosuid,nodev)"
    STATUS[shm]="secured"
    ACTION[shm]="none"
elif grep -q "^tmpfs.*/run/shm.*noexec" /etc/fstab 2>/dev/null; then
    log_ok "/run/shm security configured (will apply on reboot)"
    STATUS[shm]="configured"
    ACTION[shm]="none"
else
    log_status "/run/shm not secured"
    log_action "Add noexec,nosuid,nodev to /run/shm"
    STATUS[shm]="not secured"
    ACTION[shm]="secure"
    
    if [[ "$DRY_RUN" == false ]]; then
        # Remove any existing /run/shm entry
        sed -i '/\/run\/shm/d' /etc/fstab
        # Add secured entry
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
        # Remount if currently mounted
        if mount | grep -q "/run/shm"; then
            mount -o remount,noexec,nosuid,nodev /run/shm 2>/dev/null || true
        fi
    fi
fi

# ============================================
# 17. DISABLE CTRL-ALT-DELETE
# ============================================
log_section "Disable Ctrl-Alt-Delete Reboot"

CTRL_ALT_DEL="/etc/systemd/system/ctrl-alt-del.target"

if [[ -L "$CTRL_ALT_DEL" ]] && [[ "$(readlink -f "$CTRL_ALT_DEL")" == "/dev/null" ]]; then
    log_ok "Ctrl-Alt-Delete already disabled"
    STATUS[ctrl_alt_del]="disabled"
    ACTION[ctrl_alt_del]="none"
else
    log_status "Ctrl-Alt-Delete can trigger reboot"
    log_action "Disable Ctrl-Alt-Delete"
    STATUS[ctrl_alt_del]="enabled"
    ACTION[ctrl_alt_del]="disable"
    
    if [[ "$DRY_RUN" == false ]]; then
        # Mask the ctrl-alt-del target
        systemctl mask ctrl-alt-del.target 2>/dev/null || true
        # Also disable the socket if it exists
        systemctl mask ctrl-alt-del.socket 2>/dev/null || true
        systemctl daemon-reload
    fi
fi

# ============================================
# 18. RESTRICT CRON ACCESS
# ============================================
log_section "Restrict Cron Access"

CRON_ALLOW="/etc/cron.allow"

if [[ -f "$CRON_ALLOW" ]] && grep -q "root" "$CRON_ALLOW" && grep -q "chillxand" "$CRON_ALLOW"; then
    log_ok "Cron restricted to root and chillxand"
    STATUS[cron_restrict]="restricted"
    ACTION[cron_restrict]="none"
else
    log_status "Cron not restricted"
    log_action "Restrict cron to root and chillxand only"
    STATUS[cron_restrict]="unrestricted"
    ACTION[cron_restrict]="restrict"
    
    if [[ "$DRY_RUN" == false ]]; then
        # Create cron.allow with only permitted users
        cat > "$CRON_ALLOW" << 'EOF'
root
chillxand
EOF
        chmod 600 "$CRON_ALLOW"
        # Remove cron.deny if it exists (cron.allow takes precedence)
        rm -f /etc/cron.deny
    fi
fi

# ============================================
# 19. FILE DESCRIPTOR LIMITS
# ============================================
log_section "File Descriptor Limits"

LIMITS_CONF="/etc/security/limits.d/99-chillxand.conf"

if [[ -f "$LIMITS_CONF" ]] && grep -q "nofile" "$LIMITS_CONF" 2>/dev/null; then
    log_ok "File descriptor limits already configured"
    STATUS[fd_limits]="configured"
    ACTION[fd_limits]="none"
else
    log_status "File descriptor limits not configured"
    log_action "Set nofile limits to 65535"
    STATUS[fd_limits]="default"
    ACTION[fd_limits]="configure"
    
    if [[ "$DRY_RUN" == false ]]; then
        cat > "$LIMITS_CONF" << 'EOF'
# ChillXand pNode - Increased file descriptor limits
# Prevents "too many open files" errors under load

* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
chillxand soft nofile 65535
chillxand hard nofile 65535
EOF
        log_ok "Created $LIMITS_CONF"
    fi
fi

# ============================================
# 20. UI/DESKTOP REMOVAL
# ============================================
log_section "UI/Desktop Components"

BOOT_TARGET=$(systemctl get-default)

UI_PACKAGES_FOUND=()
UI_CHECK_PACKAGES=(
    "ubuntu-desktop"
    "gnome-shell"
    "gnome-session"
    "kde-plasma-desktop"
    "xfce4"
    "lxde"
    "xserver-xorg"
    "lightdm"
    "gdm3"
    "plymouth"
    "gsettings-desktop-schemas"
    "python3-xkit"
)

for pkg in "${UI_CHECK_PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        UI_PACKAGES_FOUND+=("$pkg")
    fi
done

QXL_LOADED=false
if lsmod 2>/dev/null | grep -q qxl; then
    QXL_LOADED=true
fi

if [[ "$BOOT_TARGET" == "multi-user.target" && ${#UI_PACKAGES_FOUND[@]} -eq 0 && "$QXL_LOADED" == false ]]; then
    log_ok "System is headless (no UI detected)"
    STATUS[ui]="headless"
    ACTION[ui]="none"
else
    STATUS[ui]="UI present"
    
    if [[ "$BOOT_TARGET" != "multi-user.target" ]]; then
        log_status "Boot target: $BOOT_TARGET"
        log_action "Set to multi-user.target"
    fi
    
    if [[ ${#UI_PACKAGES_FOUND[@]} -gt 0 ]]; then
        log_status "UI packages: ${UI_PACKAGES_FOUND[*]}"
        log_action "Remove UI packages"
    fi
    
    if [[ "$QXL_LOADED" == true ]]; then
        log_status "QXL graphics driver loaded"
        log_action "Blacklist QXL driver"
    fi
    
    ACTION[ui]="remove"
    
    if [[ "$DRY_RUN" == false ]]; then
        systemctl set-default multi-user.target
        
        BLACKLIST_FILE="/etc/modprobe.d/blacklist-graphics.conf"
        grep -q "blacklist qxl" "$BLACKLIST_FILE" 2>/dev/null || echo "blacklist qxl" >> "$BLACKLIST_FILE"
        
        apt remove --purge -y ubuntu-desktop* gnome-* kde-* xfce4* lxde* 2>/dev/null || true
        apt remove --purge -y xserver-xorg* lightdm* gdm3* 2>/dev/null || true
        apt remove --purge -y plymouth* 2>/dev/null || true
        apt remove --purge -y gsettings-desktop-schemas python3-xkit 2>/dev/null || true
        apt autoremove --purge -y
        apt autoclean
        journalctl --vacuum-time=1s
        update-initramfs -u
    fi
fi

# ============================================
# 21. KEYPAIR SECURITY
# ============================================
log_section "pNode Keypair Security"

KEYPAIR_PATH="/local/keypairs/pnode-keypair.json"

if [[ -f "$KEYPAIR_PATH" ]]; then
    KEYPAIR_PERMS=$(stat -c "%a" "$KEYPAIR_PATH" 2>/dev/null)
    KEYPAIR_OWNER=$(stat -c "%U:%G" "$KEYPAIR_PATH" 2>/dev/null)
    
    if [[ "$KEYPAIR_PERMS" == "600" && "$KEYPAIR_OWNER" == "root:root" ]]; then
        log_ok "Keypair secured (600, root:root)"
        STATUS[keypair]="secured"
        ACTION[keypair]="none"
    else
        log_status "Keypair: $KEYPAIR_PERMS, $KEYPAIR_OWNER"
        log_action "Set to 600, root:root"
        STATUS[keypair]="not secured"
        ACTION[keypair]="secure"
        if [[ "$DRY_RUN" == false ]]; then
            chmod 600 "$KEYPAIR_PATH"
            chown root:root "$KEYPAIR_PATH"
        fi
    fi
else
    log_warn "Keypair not found at $KEYPAIR_PATH"
    STATUS[keypair]="not found"
    ACTION[keypair]="none"
fi

# ============================================
# 22. SSH HARDENING
# ============================================
log_section "SSH Security Hardening"

# Safety check for authorized_keys
AUTHORIZED_KEYS_FOUND=()
while IFS= read -r keyfile; do
    [[ -s "$keyfile" ]] && AUTHORIZED_KEYS_FOUND+=("$keyfile")
done < <(find /home -name "authorized_keys" -type f 2>/dev/null)
[[ -s /root/.ssh/authorized_keys ]] && AUTHORIZED_KEYS_FOUND+=("/root/.ssh/authorized_keys")
# Also check /etc/ssh/users
while IFS= read -r keyfile; do
    [[ -s "$keyfile" ]] && AUTHORIZED_KEYS_FOUND+=("$keyfile")
done < <(find /etc/ssh/users -name "authorized_keys" -type f 2>/dev/null)

if [[ ${#AUTHORIZED_KEYS_FOUND[@]} -eq 0 ]]; then
    log_error "NO AUTHORIZED_KEYS FOUND - SSH hardening would lock you out!"
    log_warn "Add SSH keys first: ssh-copy-id user@this-server"
    STATUS[ssh]="NO KEYS"
    ACTION[ssh]="BLOCKED"
else
    log_ok "Found ${#AUTHORIZED_KEYS_FOUND[@]} authorized_keys file(s)"
    
    SSH_HARDENING_CONF="/etc/ssh/sshd_config.d/99-chillxand-hardening.conf"
    REQUIRED_SETTINGS=(
        "PasswordAuthentication no"
        "PermitRootLogin prohibit-password"
        "PubkeyAuthentication yes"
        "PermitEmptyPasswords no"
        "ChallengeResponseAuthentication no"
        "KbdInteractiveAuthentication no"
    )
    
    CONFIG_COMPLETE=true
    if [[ -f "$SSH_HARDENING_CONF" ]]; then
        for setting in "${REQUIRED_SETTINGS[@]}"; do
            grep -q "^${setting}$" "$SSH_HARDENING_CONF" 2>/dev/null || CONFIG_COMPLETE=false
        done
    else
        CONFIG_COMPLETE=false
    fi
    
    if [[ "$CONFIG_COMPLETE" == true ]]; then
        EFFECTIVE_PASSWORD_AUTH=$(sshd -T 2>/dev/null | grep -i "^passwordauthentication" | awk '{print $2}')
        if [[ "$EFFECTIVE_PASSWORD_AUTH" == "no" ]]; then
            log_ok "SSH hardening complete and active"
            STATUS[ssh]="hardened"
            ACTION[ssh]="none"
        else
            log_warn "Config exists but password auth still enabled"
            STATUS[ssh]="config conflict"
            ACTION[ssh]="investigate"
        fi
    else
        log_status "SSH hardening config missing or incomplete"
        log_action "Create/update SSH hardening config"
        STATUS[ssh]="not hardened"
        ACTION[ssh]="harden"
        
        if [[ "$DRY_RUN" == false ]]; then
            cat > "$SSH_HARDENING_CONF" << 'EOF'
# ChillXand pNode SSH Hardening
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
            if sshd -t 2>&1; then
                systemctl restart sshd
            else
                log_error "SSH config invalid - removing"
                rm -f "$SSH_HARDENING_CONF"
            fi
        fi
    fi
fi

# ============================================
# 23. SYSTEM UPDATE
# ============================================
log_section "System Update"

if [[ "$DRY_RUN" == true ]]; then
    log_action "Run apt update && apt upgrade -y"
    ACTION[system_update]="will update"
else
    log_action "Running apt update && apt upgrade..."
    apt update && apt upgrade -y
    ACTION[system_update]="completed"
fi

# ============================================
# 24. REDUCE EXT4 RESERVED BLOCKS
# ============================================
log_section "Ext4 Reserved Blocks"

# Get root device
ROOT_DEV=$(df / | awk 'NR==2 {print $1}')

if [[ -b "$ROOT_DEV" ]]; then
    # Get current reserved block percentage
    RESERVED_PCT=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep "Reserved block count" | head -1)
    BLOCK_COUNT=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep "Block count:" | awk '{print $3}')
    RESERVED_COUNT=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep "Reserved block count:" | awk '{print $4}')
    
    if [[ -n "$BLOCK_COUNT" && -n "$RESERVED_COUNT" && "$BLOCK_COUNT" -gt 0 ]]; then
        CURRENT_RESERVED_PCT=$(awk "BEGIN {printf \"%.1f\", ($RESERVED_COUNT / $BLOCK_COUNT) * 100}")
        
        # Check if greater than 1%
        if awk "BEGIN {exit !($CURRENT_RESERVED_PCT > 1.5)}"; then
            log_status "Reserved blocks at ${CURRENT_RESERVED_PCT}% on $ROOT_DEV"
            log_action "Reduce reserved blocks from ${CURRENT_RESERVED_PCT}% to 1%"
            STATUS[reserved_blocks]="${CURRENT_RESERVED_PCT}%"
            ACTION[reserved_blocks]="reduce to 1%"
            
            if [[ "$DRY_RUN" == false ]]; then
                tune2fs -m 1 "$ROOT_DEV"
                log_ok "Reduced reserved blocks to 1%"
            fi
        else
            log_ok "Reserved blocks already at ${CURRENT_RESERVED_PCT}% on $ROOT_DEV"
            STATUS[reserved_blocks]="${CURRENT_RESERVED_PCT}%"
            ACTION[reserved_blocks]="none"
        fi
    else
        log_warn "Could not read reserved block info from $ROOT_DEV"
        STATUS[reserved_blocks]="unknown"
        ACTION[reserved_blocks]="skip"
    fi
else
    log_warn "Root device $ROOT_DEV not found or not a block device"
    STATUS[reserved_blocks]="unknown"
    ACTION[reserved_blocks]="skip"
fi

# ============================================
# 25. XANDEUM-PAGES STORAGE
# ============================================
log_section "Xandeum Pages Storage"

XANDEUM_PAGES="/xandeum-pages"
BUFFER_GB=12
BUFFER_BYTES=$((BUFFER_GB * 1024 * 1024 * 1024))
MIN_XANDEUM_GB=50  # Minimum viable xandeum-pages size

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
# TARGET = current_size + free_space - buffer
TARGET_BYTES=$((CURRENT_BYTES + FREE_BYTES - BUFFER_BYTES))
TARGET_GB=$((TARGET_BYTES / 1024 / 1024 / 1024))

# Log current state
log_status "Current: ${CURRENT_GB}GB, Free: ${FREE_GB}GB, Buffer: ${BUFFER_GB}GB"

# Ensure target is reasonable
if [[ $TARGET_GB -lt $MIN_XANDEUM_GB ]]; then
    log_error "Insufficient space: target would be ${TARGET_GB}GB (minimum: ${MIN_XANDEUM_GB}GB)"
    log_warn "Free up space or reduce buffer"
    STATUS[xandeum_pages]="insufficient space"
    ACTION[xandeum_pages]="MANUAL"
elif [[ -f "$XANDEUM_PAGES" ]]; then
    # File exists - check if we need to resize
    DIFF_GB=$(( (TARGET_GB > CURRENT_GB) ? (TARGET_GB - CURRENT_GB) : (CURRENT_GB - TARGET_GB) ))
    
    if [[ $DIFF_GB -le 1 ]]; then
        # Within 1GB tolerance - no change needed
        log_ok "/xandeum-pages is ${CURRENT_GB}GB (${FREE_GB}GB free, ${BUFFER_GB}GB buffer)"
        STATUS[xandeum_pages]="${CURRENT_GB}GB"
        ACTION[xandeum_pages]="none"
    elif [[ $TARGET_GB -gt $CURRENT_GB ]]; then
        # Grow to use available space
        GROW_BY=$((TARGET_GB - CURRENT_GB))
        log_action "Grow /xandeum-pages by ${GROW_BY}GB (${CURRENT_GB}GB → ${TARGET_GB}GB, leaving ${BUFFER_GB}GB free)"
        STATUS[xandeum_pages]="${CURRENT_GB}GB"
        ACTION[xandeum_pages]="grow to ${TARGET_GB}GB"
        
        if [[ "$DRY_RUN" == false ]]; then
            fallocate -l "${TARGET_BYTES}" "$XANDEUM_PAGES"
            log_ok "Grew /xandeum-pages to ${TARGET_GB}GB"
        fi
    else
        # Shrink (unusual - only if buffer was increased or space needed)
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
    # Create new file
    log_status "/xandeum-pages does not exist"
    log_action "Create /xandeum-pages at ${TARGET_GB}GB (leaving ${BUFFER_GB}GB free)"
    STATUS[xandeum_pages]="missing"
    ACTION[xandeum_pages]="create ${TARGET_GB}GB"
    
    if [[ "$DRY_RUN" == false ]]; then
        fallocate -l "${TARGET_BYTES}" "$XANDEUM_PAGES"
        chmod 600 "$XANDEUM_PAGES"
        chown root:root "$XANDEUM_PAGES"
        log_ok "Created /xandeum-pages at ${TARGET_GB}GB"
    fi
fi

# ============================================
# 26. WRITE VERSION MARKER
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
printf "%-25s %-20s %s\n" "ChillXand Sudo" "${STATUS[chillxand_user]:-unknown}" "${ACTION[chillxand_user]:-check}"
printf "%-25s %-20s %s\n" "Update Notifier" "${STATUS[update_notifier]:-unknown}" "${ACTION[update_notifier]:-check}"
printf "%-25s %-20s %s\n" "Ubuntu Pro" "${STATUS[ubuntu_pro]:-unknown}" "${ACTION[ubuntu_pro]:-check}"
printf "%-25s %-20s %s\n" "LivePatch" "${STATUS[livepatch]:-unknown}" "-"
printf "%-25s %-20s %s\n" "Unattended Upgrades" "${STATUS[unattended_pkg]:-unknown}" "${ACTION[unattended_conf]:-check}"
printf "%-25s %-20s %s\n" "Logrotate" "${STATUS[logrotate]:-unknown}" "${ACTION[logrotate]:-check}"
printf "%-25s %-20s %s\n" "Journald" "${STATUS[journald]:-unknown}" "${ACTION[journald]:-check}"
printf "%-25s %-20s %s\n" "Apport" "${STATUS[apport]:-unknown}" "-"
printf "%-25s %-20s %s\n" "Locales" "${STATUS[locales]:-unknown}" "${ACTION[locales]:-check}"
printf "%-25s %-20s %s\n" "Docs/Man Pages" "${STATUS[docs]:-unknown}" "${ACTION[docs]:-check}"
printf "%-25s %-20s %s\n" "tmpfs /tmp" "${STATUS[tmpfs]:-unknown}" "${ACTION[tmpfs]:-check}"
printf "%-25s %-20s %s\n" "Cleanup Cron" "${STATUS[cleanup_cron]:-unknown}" "${ACTION[cleanup_cron]:-check}"
printf "%-25s %-20s %s\n" "Fail2ban" "${STATUS[fail2ban]:-unknown}" "${ACTION[fail2ban]:-check}"
printf "%-25s %-20s %s\n" "UFW Firewall" "${STATUS[ufw]:-unknown}" "${ACTION[ufw]:-check}"
printf "%-25s %-20s %s\n" "Kernel/Network Tuning" "${STATUS[sysctl]:-unknown}" "${ACTION[sysctl]:-check}"
printf "%-25s %-20s %s\n" "Network Protocols" "${STATUS[net_protocols]:-unknown}" "${ACTION[net_protocols]:-check}"
printf "%-25s %-20s %s\n" "Shared Memory" "${STATUS[shm]:-unknown}" "${ACTION[shm]:-check}"
printf "%-25s %-20s %s\n" "Ctrl-Alt-Delete" "${STATUS[ctrl_alt_del]:-unknown}" "${ACTION[ctrl_alt_del]:-check}"
printf "%-25s %-20s %s\n" "Cron Restriction" "${STATUS[cron_restrict]:-unknown}" "${ACTION[cron_restrict]:-check}"
printf "%-25s %-20s %s\n" "File Descriptor Limits" "${STATUS[fd_limits]:-unknown}" "${ACTION[fd_limits]:-check}"
printf "%-25s %-20s %s\n" "UI/Desktop" "${STATUS[ui]:-unknown}" "${ACTION[ui]:-check}"
printf "%-25s %-20s %s\n" "Keypair" "${STATUS[keypair]:-unknown}" "${ACTION[keypair]:-check}"
printf "%-25s %-20s %s\n" "SSH Hardening" "${STATUS[ssh]:-unknown}" "${ACTION[ssh]:-check}"
printf "%-25s %-20s %s\n" "Reserved Blocks" "${STATUS[reserved_blocks]:-unknown}" "${ACTION[reserved_blocks]:-check}"
printf "%-25s %-20s %s\n" "Xandeum Pages" "${STATUS[xandeum_pages]:-unknown}" "${ACTION[xandeum_pages]:-check}"
printf "%-25s %-20s %s\n" "System Update" "-" "${ACTION[system_update]:-will update}"

echo ""

# Warnings
if [[ "${ACTION[ubuntu_pro]}" == "NEEDS TOKEN" ]]; then
    echo -e "${YELLOW}⚠ Ubuntu Pro requires token: https://ubuntu.com/pro/dashboard${NC}"
    echo -e "${YELLOW}  Run: $0 -x -t 'YOUR_TOKEN'${NC}"
    echo ""
fi

if [[ "${ACTION[ssh]}" == "BLOCKED" ]]; then
    echo -e "${RED}⚠ SSH hardening blocked - no authorized_keys found!${NC}"
    echo -e "${RED}  From local machine: ssh-copy-id user@$(hostname)${NC}"
    echo ""
fi

if [[ "${ACTION[tmpfs]}" == "configure" && "$DRY_RUN" == false ]]; then
    echo -e "${CYAN}ℹ tmpfs for /tmp configured - requires reboot to take effect${NC}"
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
