#!/usr/bin/env bash
#
# Hecate Node Installer (systemd + podman)
# Usage: curl -fsSL https://hecate.io/install.sh | bash
#
# Installs:
#   - podman (rootless containers)
#   - hecate-daemon (via Podman Quadlet)
#   - hecate-reconciler (watches ~/.hecate/gitops/)
#   - hecate CLI (from hecate-cli releases)
#   - hecate-web (Tauri desktop app, workstations only)
#   - Ollama (optional, for local LLM)
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

HECATE_VERSION="${HECATE_VERSION:-latest}"
INSTALL_DIR="${HECATE_INSTALL_DIR:-$HOME/.hecate}"
BIN_DIR="${HECATE_BIN_DIR:-$HOME/.local/bin}"
GITOPS_DIR="${INSTALL_DIR}/gitops"
QUADLET_DIR="${HOME}/.config/containers/systemd"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
REPO_BASE="https://github.com/hecate-social"

# Docker image (GitHub Container Registry)
HECATE_IMAGE="ghcr.io/hecate-social/hecate-daemon:0.8.0"

# Flags
HEADLESS=false
DAEMON_ONLY=false

# Node role
NODE_ROLE="standalone"  # standalone, cluster, inference

# Feature roles
ROLE_WORKSTATION=false
ROLE_SERVICES=false
ROLE_AI=false

# Cluster join
CLUSTER_COOKIE=""
CLUSTER_PEERS=""

# Hardware detection results
DETECTED_RAM_GB=0
DETECTED_CPU_CORES=0
DETECTED_HAS_AVX2=false
DETECTED_HAS_GPU=false
DETECTED_GPU_TYPE=""
DETECTED_STORAGE_GB=0
DETECTED_STORAGE_PATH=""

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal()   { error "$@"; exit 1; }
section() { echo ""; echo -e "${MAGENTA}${BOLD}━━━ $* ━━━${NC}"; echo ""; }

command_exists() { command -v "$1" &>/dev/null; }

confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [ "$HEADLESS" = true ]; then
        [ "$default" = "y" ]
        return
    fi

    local yn_hint="[y/N]"
    [ "$default" = "y" ] && yn_hint="[Y/n]"

    echo -en "${CYAN}?${NC} ${prompt} ${yn_hint} " > /dev/tty
    read -r response < /dev/tty
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy] ]]
}

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        *)       fatal "Unsupported OS: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             fatal "Unsupported architecture: $(uname -m)" ;;
    esac
}

get_local_ip() {
    local os
    os=$(detect_os)
    if [ "$os" = "linux" ]; then
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
    elif [ "$os" = "darwin" ]; then
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1"
    else
        echo "127.0.0.1"
    fi
}

get_latest_release() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/hecate-social/${repo}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' \
        | sed -E 's/.*"([^"]+)".*/\1/' || echo ""
}

download_file() {
    local url="$1"
    local dest="$2"
    info "Downloading: ${url##*/}"
    curl -fsSL "$url" -o "$dest" || fatal "Failed to download: $url"
}

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------

show_banner() {
    echo ""
    echo "    🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺"
    echo ""
    echo -e "    ${MAGENTA}${BOLD}🔥🗝️🔥  H E C A T E  🔥🗝️🔥${NC}"
    echo -e "         ${DIM}Powered by Macula${NC}"
    echo ""
    echo "    🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺"
    echo ""
}

# -----------------------------------------------------------------------------
# Hardware Detection
# -----------------------------------------------------------------------------

detect_hardware() {
    section "Detecting Hardware"

    local os
    os=$(detect_os)

    # Detect RAM
    if [ "$os" = "linux" ]; then
        DETECTED_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")
    elif [ "$os" = "darwin" ]; then
        DETECTED_RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}' || echo "0")
    fi

    # Detect CPU cores
    if [ "$os" = "linux" ]; then
        DETECTED_CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
    elif [ "$os" = "darwin" ]; then
        DETECTED_CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "1")
    fi

    # Detect AVX2 support
    if [ "$os" = "linux" ]; then
        if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
            DETECTED_HAS_AVX2=true
        fi
    elif [ "$os" = "darwin" ]; then
        if sysctl -n machdep.cpu.features 2>/dev/null | grep -qi avx2; then
            DETECTED_HAS_AVX2=true
        fi
    fi

    # Detect GPU
    if [ "$os" = "linux" ]; then
        if command_exists nvidia-smi && nvidia-smi &>/dev/null; then
            DETECTED_HAS_GPU=true
            DETECTED_GPU_TYPE="nvidia"
        elif [ -d /sys/class/drm ] && ls /sys/class/drm/card*/device/vendor 2>/dev/null | xargs grep -l 0x1002 &>/dev/null; then
            DETECTED_HAS_GPU=true
            DETECTED_GPU_TYPE="amd"
        fi
    elif [ "$os" = "darwin" ]; then
        if [ "$(detect_arch)" = "arm64" ]; then
            DETECTED_HAS_GPU=true
            DETECTED_GPU_TYPE="apple"
        fi
    fi

    # Detect storage
    if [ "$os" = "linux" ]; then
        if [ -d "/bulk0" ] && df /bulk0 &>/dev/null; then
            DETECTED_STORAGE_GB=$(df -BG /bulk0 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}' || echo "0")
            DETECTED_STORAGE_PATH="/bulk0"
        else
            DETECTED_STORAGE_GB=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}' || echo "0")
            DETECTED_STORAGE_PATH="$HOME"
        fi
    elif [ "$os" = "darwin" ]; then
        DETECTED_STORAGE_GB=$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
        DETECTED_STORAGE_PATH="$HOME"
    fi

    # Display results
    echo -e "  ${BOLD}RAM:${NC}        ${DETECTED_RAM_GB} GB"
    echo -e "  ${BOLD}CPU Cores:${NC}  ${DETECTED_CPU_CORES}"
    echo -e "  ${BOLD}AVX2:${NC}       $([ "$DETECTED_HAS_AVX2" = true ] && echo "${GREEN}Yes${NC}" || echo "No")"
    if [ "$DETECTED_HAS_GPU" = true ]; then
        echo -e "  ${BOLD}GPU:${NC}        ${GREEN}${DETECTED_GPU_TYPE}${NC}"
    else
        echo -e "  ${BOLD}GPU:${NC}        None detected"
    fi
    echo -e "  ${BOLD}Storage:${NC}    ${DETECTED_STORAGE_GB} GB free"
    echo ""
}

# -----------------------------------------------------------------------------
# Firewall Configuration
# -----------------------------------------------------------------------------

configure_firewall() {
    section "Firewall Configuration"

    # Detect active firewall
    local fw_tool=""
    local fw_active=false

    # Check ufw (Ubuntu/Debian)
    if command_exists ufw; then
        if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
            fw_tool="ufw"
            fw_active=true
        elif sudo ufw status 2>/dev/null | grep -q "Status: inactive"; then
            fw_tool="ufw"
            fw_active=false
        fi
    fi

    # Check firewalld (RHEL/Fedora)
    if [ -z "$fw_tool" ] && command_exists firewall-cmd; then
        if sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
            fw_tool="firewalld"
            fw_active=true
        fi
    fi

    # Check nftables (Arch/modern distros)
    if [ -z "$fw_tool" ] && command_exists nft; then
        if sudo nft list ruleset 2>/dev/null | grep -q "table"; then
            fw_tool="nftables"
            fw_active=true
        else
            fw_tool="nftables"
            fw_active=false
        fi
    fi

    # Check iptables (legacy)
    if [ -z "$fw_tool" ] && command_exists iptables; then
        local rules_count
        rules_count=$(sudo iptables -L -n 2>/dev/null | grep -c "^Chain" || echo "0")
        if [ "$rules_count" -gt 3 ]; then
            fw_tool="iptables"
            fw_active=true
        else
            fw_tool="iptables"
            fw_active=false
        fi
    fi

    # No firewall found
    if [ -z "$fw_tool" ]; then
        ok "No firewall detected - all ports open by default"
        echo ""
        echo "For reference, these ports will be used:"
        show_required_ports
        return
    fi

    # Show firewall status
    if [ "$fw_active" = false ]; then
        info "Firewall (${fw_tool}) installed but not active"
    else
        info "Active firewall: ${fw_tool}"
    fi
    echo ""
    show_required_ports
    echo ""

    # Offer to configure even if inactive
    local prompt="Configure firewall rules?"
    if [ "$fw_active" = false ]; then
        prompt="Add firewall rules? (will apply when ${fw_tool} is enabled)"
    fi

    if ! confirm "$prompt" "y"; then
        warn "Skipping firewall configuration"
        return
    fi

    case "$fw_tool" in
        ufw)       configure_ufw ;;
        firewalld) configure_firewalld ;;
        nftables)  configure_nftables ;;
        iptables)  configure_iptables ;;
    esac
}

show_required_ports() {
    case "$NODE_ROLE" in
        inference)
            echo "Required ports for Inference node:"
            echo -e "  ${CYAN}11434/tcp${NC}  - Ollama API"
            echo -e "  ${CYAN}22/tcp${NC}     - SSH"
            ;;
        standalone)
            echo "Required ports for Standalone node:"
            echo -e "  ${CYAN}4433/udp${NC}   - Macula mesh (QUIC)"
            echo -e "  ${CYAN}22/tcp${NC}     - SSH"
            ;;
        cluster)
            echo "Required ports for Cluster node:"
            echo -e "  ${CYAN}4433/udp${NC}   - Macula mesh (QUIC)"
            echo -e "  ${CYAN}4369/tcp${NC}   - EPMD (Erlang)"
            echo -e "  ${CYAN}9100/tcp${NC}   - Erlang distribution"
            echo -e "  ${CYAN}22/tcp${NC}     - SSH"
            ;;
    esac
}

configure_ufw() {
    info "Configuring ufw..."
    sudo ufw allow ssh

    case "$NODE_ROLE" in
        inference)
            sudo ufw allow 11434/tcp comment 'Ollama API'
            ;;
        standalone)
            sudo ufw allow 4433/udp comment 'Macula mesh'
            ;;
        cluster)
            sudo ufw allow 4433/udp comment 'Macula mesh'
            sudo ufw allow 4369/tcp comment 'EPMD'
            sudo ufw allow 9100/tcp comment 'Erlang dist'
            ;;
    esac

    if ! sudo ufw status | grep -q "Status: active"; then
        sudo ufw --force enable
    fi
    sudo ufw reload
    ok "ufw configured"
}

configure_firewalld() {
    info "Configuring firewalld..."

    case "$NODE_ROLE" in
        inference)
            sudo firewall-cmd --permanent --add-port=11434/tcp
            ;;
        standalone)
            sudo firewall-cmd --permanent --add-port=4433/udp
            ;;
        cluster)
            sudo firewall-cmd --permanent --add-port=4433/udp
            sudo firewall-cmd --permanent --add-port=4369/tcp
            sudo firewall-cmd --permanent --add-port=9100/tcp
            ;;
    esac

    sudo firewall-cmd --reload
    ok "firewalld configured"
}

configure_nftables() {
    info "Configuring nftables..."

    sudo nft add table inet hecate 2>/dev/null || true
    sudo nft add chain inet hecate input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || true

    case "$NODE_ROLE" in
        inference)
            sudo nft add rule inet hecate input tcp dport 11434 accept comment \"Ollama API\"
            ;;
        standalone)
            sudo nft add rule inet hecate input udp dport 4433 accept comment \"Macula mesh\"
            ;;
        cluster)
            sudo nft add rule inet hecate input udp dport 4433 accept comment \"Macula mesh\"
            sudo nft add rule inet hecate input tcp dport 4369 accept comment \"EPMD\"
            sudo nft add rule inet hecate input tcp dport 9100 accept comment \"Erlang dist\"
            ;;
    esac

    ok "nftables configured"
    info "To persist: sudo nft list ruleset > /etc/nftables.conf"
}

configure_iptables() {
    info "Configuring iptables..."

    case "$NODE_ROLE" in
        inference)
            sudo iptables -A INPUT -p tcp --dport 11434 -j ACCEPT -m comment --comment "Ollama API"
            ;;
        standalone)
            sudo iptables -A INPUT -p udp --dport 4433 -j ACCEPT -m comment --comment "Macula mesh"
            ;;
        cluster)
            sudo iptables -A INPUT -p udp --dport 4433 -j ACCEPT -m comment --comment "Macula mesh"
            sudo iptables -A INPUT -p tcp --dport 4369 -j ACCEPT -m comment --comment "EPMD"
            sudo iptables -A INPUT -p tcp --dport 9100 -j ACCEPT -m comment --comment "Erlang dist"
            ;;
    esac

    ok "iptables configured"
    info "To persist: sudo iptables-save > /etc/iptables/rules.v4"
}

# -----------------------------------------------------------------------------
# Node Role Selection
# -----------------------------------------------------------------------------

select_node_role() {
    section "Node Role Selection"

    echo "What type of node is this?"
    echo ""
    echo -e "  ${BOLD}1)${NC} Standalone     ${DIM}- Single machine, everything local (default)${NC}"
    echo -e "  ${BOLD}2)${NC} Cluster        ${DIM}- Join BEAM cluster with other nodes${NC}"
    echo -e "  ${BOLD}3)${NC} Inference      ${DIM}- Dedicated Ollama server (no daemon)${NC}"
    echo ""

    if [ "$HEADLESS" = true ]; then
        NODE_ROLE="standalone"
        info "Headless mode: defaulting to standalone"
        return
    fi

    echo -en "  Enter choice [1]: " > /dev/tty
    read -r choice < /dev/tty
    choice="${choice:-1}"

    case "$choice" in
        1) NODE_ROLE="standalone" ;;
        2)
            NODE_ROLE="cluster"
            echo ""
            echo "BEAM cluster configuration:"
            echo ""
            echo -en "  Erlang cookie (shared secret): " > /dev/tty
            read -r CLUSTER_COOKIE < /dev/tty
            echo -en "  Peer nodes (comma-separated, e.g., beam00.lab,beam01.lab): " > /dev/tty
            read -r CLUSTER_PEERS < /dev/tty

            if [ -z "$CLUSTER_COOKIE" ]; then
                warn "No cookie provided — generating random cookie"
                CLUSTER_COOKIE=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
            fi
            ;;
        3)
            NODE_ROLE="inference"
            ROLE_AI=true
            ROLE_WORKSTATION=false
            ROLE_SERVICES=false
            ;;
        *) NODE_ROLE="standalone" ;;
    esac

    echo ""
    ok "Node role: ${NODE_ROLE}"
}

# -----------------------------------------------------------------------------
# Feature Role Selection
# -----------------------------------------------------------------------------

# Ollama host (for remote Ollama servers)
OLLAMA_HOST="http://localhost:11434"

select_feature_roles() {
    section "Feature Selection"

    # Standalone and cluster: workstation + services by default
    ROLE_WORKSTATION=true
    ROLE_SERVICES=true

    if [ "$DAEMON_ONLY" = true ]; then
        ROLE_WORKSTATION=false
        ROLE_SERVICES=true
        info "Daemon-only mode: services role only"
        return
    fi

    if [ "$HEADLESS" = true ]; then
        info "Headless mode: services only"
        ROLE_WORKSTATION=false
        return
    fi

    echo "This node will run: daemon + services (default)"
    echo ""

    # Ask about workstation (hecate-web)
    if confirm "Install Hecate Web (desktop app)?" "y"; then
        ROLE_WORKSTATION=true
    else
        ROLE_WORKSTATION=false
    fi

    echo ""

    # Ask about Ollama configuration
    echo "Ollama Configuration (AI/LLM features):"
    echo ""
    echo -e "  ${BOLD}1)${NC} Local          ${DIM}- Install Ollama on this machine (recommended)${NC}"
    echo -e "  ${BOLD}2)${NC} Remote         ${DIM}- Use Ollama on another server${NC}"
    echo -e "  ${BOLD}3)${NC} Skip           ${DIM}- No AI features${NC}"
    echo ""
    echo -en "  Enter choice [1]: " > /dev/tty
    read -r ollama_choice < /dev/tty
    ollama_choice="${ollama_choice:-1}"

    case "$ollama_choice" in
        1)
            ROLE_AI=true
            ok "Will install Ollama locally"
            ;;
        2)
            echo ""
            echo -en "  Ollama URL (e.g., 192.168.1.50 or host00.lab:11434): " > /dev/tty
            read -r ollama_host < /dev/tty
            if [ -n "$ollama_host" ]; then
                # Add http:// if not present
                if [[ ! "$ollama_host" =~ ^https?:// ]]; then
                    ollama_host="http://${ollama_host}"
                fi
                # Add port if not present
                if [[ ! "$ollama_host" =~ :[0-9]+$ ]]; then
                    ollama_host="${ollama_host}:11434"
                fi
                OLLAMA_HOST="$ollama_host"
                ROLE_AI=false
                ok "Using remote Ollama: ${OLLAMA_HOST}"
            else
                warn "No URL provided, skipping AI features"
                ROLE_AI=false
            fi
            ;;
        3|*)
            ROLE_AI=false
            info "AI features disabled"
            ;;
    esac

    echo ""
    local roles=()
    [ "$ROLE_WORKSTATION" = true ] && roles+=("hecate-web")
    [ "$ROLE_SERVICES" = true ] && roles+=("services")
    [ "$ROLE_AI" = true ] && roles+=("ollama (local)")
    [ "$OLLAMA_HOST" != "http://localhost:11434" ] && roles+=("ollama (${OLLAMA_HOST})")
    ok "Selected features: ${roles[*]}"
}

# -----------------------------------------------------------------------------
# Podman Installation
# -----------------------------------------------------------------------------

check_podman() {
    if command_exists podman; then
        local version
        version=$(podman --version 2>/dev/null | awk '{print $3}')
        ok "podman installed: ${version}"
        return 0
    fi
    return 1
}

install_podman() {
    section "Installing Podman"

    local os
    os=$(detect_os)

    if [ "$os" = "darwin" ]; then
        if command_exists brew; then
            info "Installing podman via Homebrew..."
            brew install podman
        else
            fatal "Homebrew is required to install podman on macOS"
        fi
    elif [ "$os" = "linux" ]; then
        echo "Podman provides rootless containers for running Hecate services."
        echo ""
        echo -e "${YELLOW}${BOLD}Requires sudo for package installation${NC}"
        echo ""

        if ! confirm "Install podman?" "y"; then
            fatal "podman is required for Hecate"
        fi

        if command_exists pacman; then
            sudo pacman -S --noconfirm --needed podman
        elif command_exists apt-get; then
            sudo apt-get update -qq && sudo apt-get install -y -qq podman
        elif command_exists dnf; then
            sudo dnf install -y -q podman
        elif command_exists zypper; then
            sudo zypper install -y podman
        else
            fatal "Could not detect package manager — install podman manually"
        fi
    fi

    if ! command_exists podman; then
        fatal "podman installation failed"
    fi

    ok "podman installed"

    # Enable lingering for user services to survive logout
    if command_exists loginctl; then
        info "Enabling lingering for systemd user services..."
        loginctl enable-linger "$(whoami)" 2>/dev/null || true
        ok "User services will persist after logout"
    fi
}

ensure_podman() {
    if ! check_podman; then
        install_podman
    else
        # Ensure lingering is enabled
        if command_exists loginctl; then
            loginctl enable-linger "$(whoami)" 2>/dev/null || true
        fi
    fi
}

# -----------------------------------------------------------------------------
# Directory Layout
# -----------------------------------------------------------------------------

create_directory_layout() {
    section "Creating Directory Layout"

    # Core directories
    mkdir -p "${INSTALL_DIR}/hecate-daemon/sqlite"
    mkdir -p "${INSTALL_DIR}/hecate-daemon/reckon-db"
    mkdir -p "${INSTALL_DIR}/hecate-daemon/sockets"
    mkdir -p "${INSTALL_DIR}/hecate-daemon/run"
    mkdir -p "${INSTALL_DIR}/hecate-daemon/connectors"
    mkdir -p "${INSTALL_DIR}/config"
    mkdir -p "${INSTALL_DIR}/secrets"

    # GitOps directories
    mkdir -p "${GITOPS_DIR}/system"
    mkdir -p "${GITOPS_DIR}/apps"

    # Podman Quadlet directory
    mkdir -p "${QUADLET_DIR}"

    # systemd user directory
    mkdir -p "${SYSTEMD_USER_DIR}"

    # Binary directory
    mkdir -p "${BIN_DIR}"

    ok "Directory layout created at ${INSTALL_DIR}"
}

# -----------------------------------------------------------------------------
# GitOps Seeding
# -----------------------------------------------------------------------------

seed_gitops() {
    section "Seeding GitOps"

    local gitops_repo="${REPO_BASE}/hecate-gitops.git"
    local tmpdir
    tmpdir=$(mktemp -d)

    info "Fetching Quadlet templates from hecate-gitops..."

    if command_exists git; then
        git clone --depth 1 "${gitops_repo}" "${tmpdir}" 2>/dev/null || {
            warn "Could not clone hecate-gitops, using embedded defaults"
            create_default_quadlet_files
            rm -rf "${tmpdir}"
            return
        }

        # Copy system Quadlet files (always)
        if [ -d "${tmpdir}/quadlet/system" ]; then
            cp "${tmpdir}/quadlet/system/"* "${GITOPS_DIR}/system/" 2>/dev/null || true
            ok "Seeded system Quadlet files"
        fi

        # Copy reconciler
        if [ -d "${tmpdir}/reconciler" ]; then
            cp "${tmpdir}/reconciler/hecate-reconciler.sh" "${BIN_DIR}/hecate-reconciler"
            chmod +x "${BIN_DIR}/hecate-reconciler"
            ok "Installed reconciler: ${BIN_DIR}/hecate-reconciler"

            cp "${tmpdir}/reconciler/hecate-reconciler.service" "${SYSTEMD_USER_DIR}/hecate-reconciler.service"
            ok "Installed reconciler service"
        fi

        rm -rf "${tmpdir}"
    else
        warn "git not found, using embedded defaults"
        create_default_quadlet_files
    fi

    # Apply hardware-specific configuration
    update_hardware_config
}

create_default_quadlet_files() {
    # Fallback: create minimal Quadlet files inline
    cat > "${GITOPS_DIR}/system/hecate-daemon.container" << 'EOF'
[Unit]
Description=Hecate Daemon (core)
After=network-online.target
Wants=network-online.target

[Container]
Image=ghcr.io/hecate-social/hecate-daemon:0.8.0
ContainerName=hecate-daemon
AutoUpdate=registry
Network=host
Volume=%h/.hecate/hecate-daemon:/data:Z
EnvironmentFile=%h/.hecate/gitops/system/hecate-daemon.env

# Health check: daemon socket presence
HealthCmd=test -S /data/sockets/api.sock
HealthInterval=30s
HealthRetries=3
HealthTimeout=5s
HealthStartPeriod=15s

[Service]
Restart=on-failure
RestartSec=10s
TimeoutStartSec=120s

[Install]
WantedBy=default.target
EOF

    cat > "${GITOPS_DIR}/system/hecate-daemon.env" << EOF
# Hecate Daemon Configuration
# Generated by installer on $(date -Iseconds)

# Mesh
HECATE_MESH_BOOTSTRAP=boot.macula.io:4433
HECATE_MESH_REALM=io.macula

# API (Unix socket)
HECATE_API_SOCKET=/data/sockets/api.sock
HECATE_DATA_DIR=/data

# LLM
HECATE_LLM_BACKEND=ollama
HECATE_LLM_ENDPOINT=${OLLAMA_HOST}

# Hardware (detected)
HECATE_RAM_GB=${DETECTED_RAM_GB}
HECATE_CPU_CORES=${DETECTED_CPU_CORES}
HECATE_GPU=${DETECTED_GPU_TYPE:-none}
EOF

    ok "Created default Quadlet files"
}

update_hardware_config() {
    info "Updating hardware configuration..."

    local gpu_type="none"
    if [ "$DETECTED_HAS_GPU" = true ]; then
        gpu_type="${DETECTED_GPU_TYPE}"
    fi

    local env_file="${GITOPS_DIR}/system/hecate-daemon.env"

    # Update env file with detected hardware values
    if [ -f "${env_file}" ]; then
        # Use sed to update existing values
        sed -i "s|^HECATE_RAM_GB=.*|HECATE_RAM_GB=${DETECTED_RAM_GB}|" "${env_file}" 2>/dev/null || true
        sed -i "s|^HECATE_CPU_CORES=.*|HECATE_CPU_CORES=${DETECTED_CPU_CORES}|" "${env_file}" 2>/dev/null || true
        sed -i "s|^HECATE_GPU=.*|HECATE_GPU=${gpu_type}|" "${env_file}" 2>/dev/null || true
        sed -i "s|^HECATE_LLM_ENDPOINT=.*|HECATE_LLM_ENDPOINT=${OLLAMA_HOST}|" "${env_file}" 2>/dev/null || true
    fi

    # Add cluster config if in cluster mode
    if [ "$NODE_ROLE" = "cluster" ]; then
        if [ -n "$CLUSTER_COOKIE" ]; then
            if ! grep -q "^HECATE_ERLANG_COOKIE=" "${env_file}" 2>/dev/null; then
                echo "" >> "${env_file}"
                echo "# BEAM Cluster" >> "${env_file}"
                echo "HECATE_ERLANG_COOKIE=${CLUSTER_COOKIE}" >> "${env_file}"
            else
                sed -i "s|^HECATE_ERLANG_COOKIE=.*|HECATE_ERLANG_COOKIE=${CLUSTER_COOKIE}|" "${env_file}" 2>/dev/null || true
            fi
        fi
        if [ -n "$CLUSTER_PEERS" ]; then
            if ! grep -q "^HECATE_CLUSTER_PEERS=" "${env_file}" 2>/dev/null; then
                echo "HECATE_CLUSTER_PEERS=${CLUSTER_PEERS}" >> "${env_file}"
            else
                sed -i "s|^HECATE_CLUSTER_PEERS=.*|HECATE_CLUSTER_PEERS=${CLUSTER_PEERS}|" "${env_file}" 2>/dev/null || true
            fi
        fi
    fi

    ok "Hardware config: ${DETECTED_RAM_GB}GB RAM, ${DETECTED_CPU_CORES} cores, GPU: ${gpu_type}"
    if [ "$OLLAMA_HOST" != "http://localhost:11434" ]; then
        ok "Remote Ollama: ${OLLAMA_HOST}"
    fi
}

# -----------------------------------------------------------------------------
# LLM Provider Configuration
# -----------------------------------------------------------------------------

setup_llm_secrets() {
    section "LLM Provider Configuration"

    local secrets_file="${INSTALL_DIR}/secrets/llm-providers.env"
    local has_keys=false

    # Check for API keys in environment
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        info "Found ANTHROPIC_API_KEY in environment"
        has_keys=true
    fi

    if [ -n "${OPENAI_API_KEY:-}" ]; then
        info "Found OPENAI_API_KEY in environment"
        has_keys=true
    fi

    if [ -n "${GOOGLE_API_KEY:-}" ]; then
        info "Found GOOGLE_API_KEY in environment"
        has_keys=true
    fi

    if [ "$has_keys" = true ]; then
        cat > "${secrets_file}" << EOF
# LLM Provider API Keys
# Generated by installer on $(date -Iseconds)
EOF
        chmod 600 "${secrets_file}"

        [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "${secrets_file}"
        [ -n "${OPENAI_API_KEY:-}" ] && echo "OPENAI_API_KEY=${OPENAI_API_KEY}" >> "${secrets_file}"
        [ -n "${GOOGLE_API_KEY:-}" ] && echo "GOOGLE_API_KEY=${GOOGLE_API_KEY}" >> "${secrets_file}"

        ok "LLM provider secrets saved to ${secrets_file}"
    else
        info "No LLM API keys found in environment"
        info "To add later: export ANTHROPIC_API_KEY=... and re-run install"
    fi
}

# -----------------------------------------------------------------------------
# Reconciler Installation
# -----------------------------------------------------------------------------

install_reconciler() {
    section "Installing Reconciler"

    # Check if reconciler was already copied during seed_gitops
    if [ ! -x "${BIN_DIR}/hecate-reconciler" ]; then
        warn "Reconciler not found — creating embedded version"
        create_embedded_reconciler
    fi

    # Ensure service file exists
    if [ ! -f "${SYSTEMD_USER_DIR}/hecate-reconciler.service" ]; then
        cat > "${SYSTEMD_USER_DIR}/hecate-reconciler.service" << EOF
[Unit]
Description=Hecate Reconciler (watches gitops, manages Quadlet units)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/hecate-reconciler --watch
Restart=on-failure
RestartSec=10s

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hecate-reconciler

# Environment
Environment=HECATE_GITOPS_DIR=%h/.hecate/gitops

[Install]
WantedBy=default.target
EOF
    fi

    # Install inotify-tools if not available (needed for watch mode)
    if ! command_exists inotifywait; then
        info "Installing inotify-tools (for filesystem watching)..."
        if command_exists pacman; then
            sudo pacman -S --noconfirm --needed inotify-tools
        elif command_exists apt-get; then
            sudo apt-get install -y -qq inotify-tools
        elif command_exists dnf; then
            sudo dnf install -y -q inotify-tools
        elif command_exists zypper; then
            sudo zypper install -y inotify-tools
        else
            warn "Could not install inotify-tools — reconciler will use polling"
        fi
    fi

    # Reload and enable
    systemctl --user daemon-reload
    systemctl --user enable hecate-reconciler.service
    ok "Reconciler enabled"
}

create_embedded_reconciler() {
    # Minimal embedded reconciler for when git clone fails
    cat > "${BIN_DIR}/hecate-reconciler" << 'RECONCILER'
#!/usr/bin/env bash
# hecate-reconciler — Syncs Quadlet .container files from gitops to systemd
set -euo pipefail

GITOPS_DIR="${HECATE_GITOPS_DIR:-${HOME}/.hecate/gitops}"
QUADLET_DIR="${HOME}/.config/containers/systemd"
LOG_PREFIX="[hecate-reconciler]"

log_info()  { echo "${LOG_PREFIX} INFO  $(date +%H:%M:%S) $*"; }
log_warn()  { echo "${LOG_PREFIX} WARN  $(date +%H:%M:%S) $*" >&2; }

preflight() {
    command -v podman &>/dev/null || { echo "podman not installed" >&2; exit 1; }
    command -v systemctl &>/dev/null || { echo "systemctl not available" >&2; exit 1; }
    [ -d "${GITOPS_DIR}" ] || { echo "gitops dir not found: ${GITOPS_DIR}" >&2; exit 1; }
    mkdir -p "${QUADLET_DIR}"
}

desired_units() {
    local files=()
    for dir in "${GITOPS_DIR}/system" "${GITOPS_DIR}/apps"; do
        if [ -d "${dir}" ]; then
            for f in "${dir}"/*.container; do
                [ -f "${f}" ] && files+=("${f}")
            done
        fi
    done
    [ ${#files[@]} -gt 0 ] && printf '%s\n' "${files[@]}"
}

actual_units() {
    local files=()
    for f in "${QUADLET_DIR}"/*.container; do
        if [ -L "${f}" ]; then
            local target
            target=$(readlink -f "${f}" 2>/dev/null || true)
            if [[ "${target}" == "${GITOPS_DIR}"/* ]]; then
                files+=("${f}")
            fi
        fi
    done
    [ ${#files[@]} -gt 0 ] && printf '%s\n' "${files[@]}"
}

reconcile() {
    local changed=0

    while IFS= read -r src; do
        local name dest
        name=$(basename "${src}")
        dest="${QUADLET_DIR}/${name}"

        if [ -L "${dest}" ]; then
            local current_target
            current_target=$(readlink -f "${dest}")
            [ "${current_target}" = "${src}" ] && continue
            log_info "UPDATE ${name}"
            rm "${dest}"
        elif [ -e "${dest}" ]; then
            log_warn "SKIP ${name} (non-symlink exists)"
            continue
        else
            log_info "ADD ${name}"
        fi

        ln -s "${src}" "${dest}"
        changed=1
    done < <(desired_units)

    while IFS= read -r dest; do
        local target
        target=$(readlink -f "${dest}")
        if [ ! -f "${target}" ]; then
            local name unit_name
            name=$(basename "${dest}")
            unit_name="${name%.container}.service"
            log_info "REMOVE ${name}"
            systemctl --user stop "${unit_name}" 2>/dev/null || true
            rm "${dest}"
            changed=1
        fi
    done < <(actual_units)

    if [ ${changed} -eq 1 ]; then
        log_info "Reloading systemd..."
        systemctl --user daemon-reload
        while IFS= read -r src; do
            local name unit_name
            name=$(basename "${src}")
            unit_name="${name%.container}.service"
            if ! systemctl --user is-active --quiet "${unit_name}" 2>/dev/null; then
                log_info "Starting ${unit_name}..."
                systemctl --user start "${unit_name}" || log_warn "Failed to start ${unit_name}"
            fi
        done < <(desired_units)
        log_info "Reconciliation complete"
    else
        log_info "No changes detected"
    fi
}

show_status() {
    echo "=== Hecate Reconciler Status ==="
    echo ""
    echo "Gitops dir:  ${GITOPS_DIR}"
    echo "Quadlet dir: ${QUADLET_DIR}"
    echo ""
    echo "--- Desired State (gitops) ---"
    while IFS= read -r src; do
        echo "  $(basename "${src}")"
    done < <(desired_units)
    echo ""
    echo "--- Actual State (systemd) ---"
    for f in "${QUADLET_DIR}"/*.container; do
        [ -f "${f}" ] || [ -L "${f}" ] || continue
        local name unit_name status sym=""
        name=$(basename "${f}")
        unit_name="${name%.container}.service"
        status=$(systemctl --user is-active "${unit_name}" 2>/dev/null || echo "inactive")
        [ -L "${f}" ] && sym=" -> $(readlink "${f}")"
        echo "  ${name} [${status}]${sym}"
    done
}

watch_loop() {
    log_info "Watching ${GITOPS_DIR} for changes..."
    log_info "Initial reconciliation..."
    reconcile
    while true; do
        if command -v inotifywait &>/dev/null; then
            inotifywait -r -q -e create -e delete -e modify -e moved_to -e moved_from \
                --timeout 300 "${GITOPS_DIR}/system" "${GITOPS_DIR}/apps" 2>/dev/null || true
        else
            sleep 30
        fi
        sleep 1
        log_info "Change detected, reconciling..."
        reconcile
    done
}

case "${1:---watch}" in
    --once)   preflight; reconcile ;;
    --watch)  preflight; watch_loop ;;
    --status) preflight; show_status ;;
    --help|-h)
        echo "Usage: hecate-reconciler [--once|--watch|--status]"
        echo ""
        echo "  --once    One-shot reconciliation"
        echo "  --watch   Continuous watch mode (default)"
        echo "  --status  Show current state"
        ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac
RECONCILER

    chmod +x "${BIN_DIR}/hecate-reconciler"
    ok "Embedded reconciler installed"
}

# -----------------------------------------------------------------------------
# Deploy Hecate
# -----------------------------------------------------------------------------

deploy_hecate() {
    section "Deploying Hecate"

    # Configure LLM secrets
    setup_llm_secrets

    # Run reconciler once to symlink Quadlet files
    info "Running initial reconciliation..."
    "${BIN_DIR}/hecate-reconciler" --once

    # Start the reconciler service
    systemctl --user start hecate-reconciler.service
    ok "Reconciler started"

    # Wait for daemon to start
    info "Waiting for hecate-daemon to start..."
    local retries=60
    local socket_path="${INSTALL_DIR}/hecate-daemon/sockets/api.sock"
    while [ $retries -gt 0 ]; do
        if [ -S "${socket_path}" ]; then
            ok "Daemon socket ready at ${socket_path}"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [ $retries -eq 0 ]; then
        warn "Daemon socket not ready yet"
        echo ""
        echo -e "${CYAN}Troubleshooting:${NC}"
        echo "  systemctl --user status hecate-daemon"
        echo "  journalctl --user -u hecate-daemon -f"
        echo "  podman logs hecate-daemon"
        echo ""
    fi
}

# -----------------------------------------------------------------------------
# Ollama Setup
# -----------------------------------------------------------------------------

check_ollama() {
    if command_exists ollama; then
        local ollama_version
        ollama_version=$(ollama --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        ok "Ollama installed: v${ollama_version:-unknown}"

        if curl -s http://localhost:11434/api/tags &>/dev/null; then
            ok "Ollama service is running"
        else
            info "Starting Ollama service..."
            if command_exists systemctl && systemctl is-enabled ollama &>/dev/null; then
                sudo systemctl start ollama 2>/dev/null || true
            else
                ollama serve > /dev/null 2>&1 &
            fi
            sleep 2
        fi
        return 0
    fi
    return 1
}

install_ollama() {
    section "Installing Ollama"

    echo "Ollama provides local LLM inference."
    echo ""

    if ! confirm "Install Ollama?" "y"; then
        warn "Skipping Ollama"
        return 1
    fi

    # Install zstd if needed
    if ! command_exists zstd; then
        info "Installing zstd..."
        if command_exists apt-get; then
            sudo apt-get update -qq && sudo apt-get install -y -qq zstd
        elif command_exists dnf; then
            sudo dnf install -y -q zstd
        elif command_exists pacman; then
            sudo pacman -S --noconfirm zstd
        fi
    fi

    info "Running Ollama install script..."
    # Run Ollama installer (disable strict mode - their script has VERSION_ID bug on Arch)
    ( set +eu; curl -fsSL https://ollama.com/install.sh | sh ) || true

    if ! command_exists ollama; then
        warn "Ollama installation failed"
        return 1
    fi

    ok "Ollama installed"

    # Start service
    if command_exists systemctl; then
        sudo systemctl enable ollama 2>/dev/null || true
        sudo systemctl start ollama 2>/dev/null || true
    else
        ollama serve > /dev/null 2>&1 &
    fi

    sleep 2
    ok "Ollama service started"
}

select_ollama_models() {
    if ! command_exists ollama; then
        return
    fi

    # Wait for Ollama to be ready
    info "Waiting for Ollama server..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -s http://localhost:11434/api/tags &>/dev/null; then
            ok "Ollama server ready"
            break
        fi
        retries=$((retries - 1))
        sleep 1
    done

    if [ $retries -eq 0 ]; then
        warn "Ollama server not responding"
        info "Start manually with: ollama serve"
        return
    fi

    echo ""
    echo "Which models would you like to pull?"
    echo ""
    echo -e "${BOLD}General Purpose:${NC}"
    echo -e "  ${BOLD}1)${NC}  llama3.2        ${DIM}- 2GB, Meta's latest, fast${NC}"
    echo -e "  ${BOLD}2)${NC}  llama3.2:1b     ${DIM}- 1GB, lightweight${NC}"
    echo -e "  ${BOLD}3)${NC}  llama3.3        ${DIM}- 43GB, flagship quality${NC}"
    echo -e "  ${BOLD}4)${NC}  mistral         ${DIM}- 4GB, excellent reasoning${NC}"
    echo -e "  ${BOLD}5)${NC}  mixtral         ${DIM}- 26GB, MoE powerhouse${NC}"
    echo ""
    echo -e "${BOLD}Coding:${NC}"
    echo -e "  ${BOLD}6)${NC}  codellama       ${DIM}- 4GB, code generation${NC}"
    echo -e "  ${BOLD}7)${NC}  codellama:34b   ${DIM}- 19GB, advanced coding${NC}"
    echo -e "  ${BOLD}8)${NC}  deepseek-coder  ${DIM}- 1GB, fast code completion${NC}"
    echo -e "  ${BOLD}9)${NC}  qwen2.5-coder   ${DIM}- 4GB, multilingual code${NC}"
    echo -e "  ${BOLD}10)${NC} starcoder2      ${DIM}- 2GB, code infill${NC}"
    echo ""
    echo -e "${BOLD}Reasoning:${NC}"
    echo -e "  ${BOLD}11)${NC} deepseek-r1     ${DIM}- 4GB, step-by-step reasoning${NC}"
    echo -e "  ${BOLD}12)${NC} deepseek-r1:70b ${DIM}- 43GB, flagship reasoning${NC}"
    echo -e "  ${BOLD}13)${NC} qwq             ${DIM}- 20GB, math/logic specialist${NC}"
    echo ""
    echo -e "${BOLD}Compact & Fast:${NC}"
    echo -e "  ${BOLD}14)${NC} phi3            ${DIM}- 2GB, Microsoft's compact${NC}"
    echo -e "  ${BOLD}15)${NC} phi3:medium     ${DIM}- 8GB, balanced${NC}"
    echo -e "  ${BOLD}16)${NC} gemma2          ${DIM}- 5GB, Google's efficient${NC}"
    echo -e "  ${BOLD}17)${NC} gemma2:27b      ${DIM}- 16GB, larger Google${NC}"
    echo ""
    echo -e "${BOLD}Multilingual:${NC}"
    echo -e "  ${BOLD}18)${NC} qwen2.5         ${DIM}- 4GB, Chinese/English${NC}"
    echo -e "  ${BOLD}19)${NC} qwen2.5:32b     ${DIM}- 20GB, advanced multilingual${NC}"
    echo -e "  ${BOLD}20)${NC} aya             ${DIM}- 5GB, 100+ languages${NC}"
    echo ""
    echo -e "${BOLD}Vision:${NC}"
    echo -e "  ${BOLD}21)${NC} llava           ${DIM}- 5GB, image understanding${NC}"
    echo -e "  ${BOLD}22)${NC} llava:34b       ${DIM}- 20GB, advanced vision${NC}"
    echo -e "  ${BOLD}23)${NC} bakllava        ${DIM}- 5GB, visual reasoning${NC}"
    echo ""
    echo -e "${BOLD}Embedding:${NC}"
    echo -e "  ${BOLD}24)${NC} nomic-embed-text ${DIM}- 274MB, text embeddings${NC}"
    echo -e "  ${BOLD}25)${NC} mxbai-embed-large ${DIM}- 670MB, high quality${NC}"
    echo ""
    echo -e "  ${BOLD}s)${NC}  Skip            ${DIM}- Don't pull any models${NC}"
    echo ""
    echo -e "${DIM}Enter choices separated by spaces (e.g., 1 6 11):${NC}"
    echo -en "  > " > /dev/tty
    read -r model_choices < /dev/tty

    if [ -z "$model_choices" ] || [ "$model_choices" = "s" ] || [ "$model_choices" = "S" ]; then
        info "Skipping model download"
        return
    fi

    for choice in $model_choices; do
        case "$choice" in
            1)  pull_model "llama3.2" ;;
            2)  pull_model "llama3.2:1b" ;;
            3)  pull_model "llama3.3" ;;
            4)  pull_model "mistral" ;;
            5)  pull_model "mixtral" ;;
            6)  pull_model "codellama" ;;
            7)  pull_model "codellama:34b" ;;
            8)  pull_model "deepseek-coder" ;;
            9)  pull_model "qwen2.5-coder" ;;
            10) pull_model "starcoder2" ;;
            11) pull_model "deepseek-r1" ;;
            12) pull_model "deepseek-r1:70b" ;;
            13) pull_model "qwq" ;;
            14) pull_model "phi3" ;;
            15) pull_model "phi3:medium" ;;
            16) pull_model "gemma2" ;;
            17) pull_model "gemma2:27b" ;;
            18) pull_model "qwen2.5" ;;
            19) pull_model "qwen2.5:32b" ;;
            20) pull_model "aya" ;;
            21) pull_model "llava" ;;
            22) pull_model "llava:34b" ;;
            23) pull_model "bakllava" ;;
            24) pull_model "nomic-embed-text" ;;
            25) pull_model "mxbai-embed-large" ;;
            *)  warn "Unknown choice: $choice" ;;
        esac
    done
}

pull_model() {
    local model="$1"
    info "Pulling ${model}..."
    if ollama pull "$model"; then
        ok "${model} ready"
    else
        warn "Failed to pull ${model}"
    fi
}

setup_ollama() {
    if [ "$ROLE_AI" = false ]; then
        return
    fi

    if ! check_ollama; then
        install_ollama
    fi

    select_ollama_models
}

# -----------------------------------------------------------------------------
# Web UI Installation
# -----------------------------------------------------------------------------

install_webkit_deps() {
    # webkit2gtk is required by hecate-web (Tauri runtime)
    # Check using pkg-config for the 4.1 API (Tauri v2 requirement)
    if command_exists pkg-config && pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
        return 0
    fi

    info "Installing webkit2gtk (required by Hecate Web)..."
    if command_exists pacman; then
        sudo pacman -S --noconfirm --needed webkit2gtk-4.1
    elif command_exists apt-get; then
        sudo apt-get update -qq && sudo apt-get install -y -qq libwebkit2gtk-4.1-dev
    elif command_exists dnf; then
        sudo dnf install -y -q webkit2gtk4.1-devel
    elif command_exists zypper; then
        sudo zypper install -y webkit2gtk3-devel
    else
        warn "Could not detect package manager — install webkit2gtk-4.1 manually"
        return 1
    fi

    ok "webkit2gtk installed"
}

install_web() {
    if [ "$ROLE_WORKSTATION" = false ]; then
        return
    fi

    section "Installing Hecate Web"

    install_webkit_deps || {
        warn "Skipping Hecate Web (missing webkit2gtk)"
        return
    }

    local os arch version url
    os=$(detect_os)
    arch=$(detect_arch)

    version=$(get_latest_release "hecate-web")
    if [ -z "$version" ]; then
        version="v0.1.0"
    fi

    url="${REPO_BASE}/hecate-web/releases/download/${version}/hecate-web-${os}-${arch}.tar.gz"

    local tmpfile
    tmpfile=$(mktemp)

    download_file "$url" "$tmpfile"
    tar -xzf "$tmpfile" -C "$BIN_DIR" 2>/dev/null || tar -xzf "$tmpfile" -C "$BIN_DIR"
    rm -f "$tmpfile"

    chmod +x "${BIN_DIR}/hecate-web"

    ok "Hecate Web ${version} installed"
}

# -----------------------------------------------------------------------------
# CLI Wrapper
# -----------------------------------------------------------------------------

install_cli() {
    section "Installing Hecate CLI"

    local cli_version="${HECATE_CLI_VERSION:-v0.1.0}"
    local cli_url="${REPO_BASE}/hecate-cli/releases/download/${cli_version}/hecate"
    local registry_url="${REPO_BASE}/hecate-cli/releases/download/${cli_version}/registry.json"
    local registry_dir="${HOME}/.local/share/hecate"

    mkdir -p "${BIN_DIR}" "${registry_dir}"

    # Try downloading from GitHub releases first
    if download_file "${cli_url}" "${BIN_DIR}/hecate" 2>/dev/null; then
        chmod +x "${BIN_DIR}/hecate"
        download_file "${registry_url}" "${registry_dir}/registry.json" 2>/dev/null || true
        ok "Hecate CLI ${cli_version} installed from release"
        return 0
    fi

    # Fallback: clone the repo and copy the script
    info "Release not available, installing from source..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if git clone --depth 1 "${REPO_BASE}/hecate-cli.git" "${tmp_dir}/hecate-cli" 2>/dev/null; then
        cp "${tmp_dir}/hecate-cli/scripts/hecate.sh" "${BIN_DIR}/hecate"
        chmod +x "${BIN_DIR}/hecate"
        cp "${tmp_dir}/hecate-cli/plugins/registry.json" "${registry_dir}/registry.json" 2>/dev/null || true
        rm -rf "${tmp_dir}"
        ok "Hecate CLI installed from source"
        return 0
    fi
    rm -rf "${tmp_dir}"

    # Last resort: seed from gitops clone if available
    if [[ -f "${GITOPS_DIR}/../hecate-cli/scripts/hecate.sh" ]]; then
        cp "${GITOPS_DIR}/../hecate-cli/scripts/hecate.sh" "${BIN_DIR}/hecate"
        chmod +x "${BIN_DIR}/hecate"
        ok "Hecate CLI installed from local source"
        return 0
    fi

    warn "Could not download hecate CLI. Install manually:"
    warn "  ${REPO_BASE}/hecate-cli"
}

# -----------------------------------------------------------------------------
# PATH Setup
# -----------------------------------------------------------------------------

setup_path() {
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        local shell_profile=""
        if [ -f "$HOME/.zshrc" ]; then
            shell_profile="$HOME/.zshrc"
        elif [ -f "$HOME/.bashrc" ]; then
            shell_profile="$HOME/.bashrc"
        fi

        if [ -n "$shell_profile" ]; then
            if ! grep -q "$BIN_DIR" "$shell_profile" 2>/dev/null; then
                echo "" >> "$shell_profile"
                echo "# Hecate" >> "$shell_profile"
                echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$shell_profile"
            fi
        fi

        export PATH="$PATH:$BIN_DIR"
    fi
    ok "PATH configured"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

show_summary() {
    section "Installation Complete"

    local local_ip
    local_ip=$(get_local_ip)

    echo -e "${GREEN}${BOLD}Hecate is ready.${NC}"
    echo ""
    echo -e "${BOLD}Node:${NC}"
    echo -e "  Role:     ${NODE_ROLE}"
    echo -e "  IP:       ${local_ip}"
    echo ""
    echo -e "${BOLD}Components:${NC}"
    echo -e "  ${CYAN}hecate${NC}            - CLI (node management + plugins)"
    echo -e "  ${CYAN}hecate-reconciler${NC} - GitOps reconciler"
    [ "$ROLE_WORKSTATION" = true ] && echo -e "  ${CYAN}hecate-web${NC}        - Desktop app"
    if [ "$ROLE_AI" = true ] && command_exists ollama; then
        echo -e "  ${CYAN}ollama${NC}            - LLM backend (local)"
    elif [ "$OLLAMA_HOST" != "http://localhost:11434" ]; then
        echo -e "  ${CYAN}ollama${NC}            - LLM backend (${OLLAMA_HOST})"
    fi
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  hecate status      - Service status"
    echo -e "  hecate logs        - View logs"
    echo -e "  hecate health      - Check health"
    [ "$ROLE_WORKSTATION" = true ] && echo -e "  hecate-web         - Launch desktop app"
    echo ""
    echo -e "Socket:    ${INSTALL_DIR}/hecate-daemon/sockets/api.sock"
    echo -e "Ollama:    ${OLLAMA_HOST}"
    echo -e "GitOps:    ${GITOPS_DIR}"
    echo ""

    if [ "$NODE_ROLE" = "cluster" ]; then
        echo -e "${CYAN}${BOLD}BEAM Cluster:${NC}"
        echo -e "  Cookie: ${CLUSTER_COOKIE}"
        [ -n "$CLUSTER_PEERS" ] && echo -e "  Peers:  ${CLUSTER_PEERS}"
        echo ""
    fi

    echo -e "${DIM}To install plugins:${NC}"
    echo -e "  Copy .container files to ${GITOPS_DIR}/apps/"
    echo -e "  The reconciler will pick them up automatically."
    echo ""
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

show_help() {
    echo "Hecate Node Installer (systemd + podman)"
    echo ""
    echo "Usage: curl -fsSL https://hecate.io/install.sh | bash"
    echo ""
    echo "Options:"
    echo "  --daemon-only     Install daemon without desktop app"
    echo "  --headless        Non-interactive mode"
    echo "  --help            Show this help"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    for arg in "$@"; do
        case "$arg" in
            --headless) HEADLESS=true ;;
            --daemon-only) DAEMON_ONLY=true ;;
            --help|-h) show_help; exit 0 ;;
        esac
    done

    show_banner
    detect_hardware
    select_node_role

    # Inference mode has a different flow
    if [ "$NODE_ROLE" = "inference" ]; then
        run_inference_install
        return
    fi

    select_feature_roles

    echo ""
    echo "This installer will set up:"
    echo "  - podman (rootless containers)"
    echo "  - hecate-reconciler (GitOps watcher)"
    echo "  - hecate-daemon (Podman Quadlet)"
    [ "$ROLE_WORKSTATION" = true ] && echo "  - hecate-web (desktop app)"
    if [ "$ROLE_AI" = true ]; then
        echo "  - Ollama (local)"
    elif [ "$OLLAMA_HOST" != "http://localhost:11434" ]; then
        echo "  - Ollama (remote: ${OLLAMA_HOST})"
    fi
    echo "  - Firewall rules"
    echo ""

    if ! confirm "Continue with installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi

    configure_firewall
    ensure_podman
    create_directory_layout
    seed_gitops
    install_reconciler
    deploy_hecate
    setup_ollama
    install_web
    install_cli
    setup_path

    show_summary
}

# -----------------------------------------------------------------------------
# Inference Node Install (Ollama-only)
# -----------------------------------------------------------------------------

run_inference_install() {
    echo ""
    echo "This installer will set up:"
    echo "  - Ollama (LLM inference server)"
    echo "  - Firewall rules (port 11434)"
    echo ""

    if ! confirm "Continue with installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi

    configure_firewall
    install_ollama_server

    show_inference_summary
}

install_ollama_server() {
    section "Installing Ollama Server"

    local ollama_bin=""

    # Find or install Ollama
    if command_exists ollama; then
        ollama_bin=$(command -v ollama)
        ok "Ollama already installed: ${ollama_bin}"
    else
        info "Installing Ollama..."
        # Run Ollama installer (disable strict mode - their script has VERSION_ID bug on Arch)
        ( set +eu; curl -fsSL https://ollama.com/install.sh | sh ) || true
        ollama_bin=$(command -v ollama)
    fi

    # Configure Ollama to listen on all interfaces
    info "Configuring Ollama for network access..."

    if command_exists systemctl; then
        # Check if ollama.service exists
        if systemctl list-unit-files ollama.service &>/dev/null && \
           systemctl list-unit-files ollama.service | grep -q ollama; then
            sudo mkdir -p /etc/systemd/system/ollama.service.d
            cat << 'EOF' | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable ollama
            sudo systemctl restart ollama
            ok "Ollama configured for network access (0.0.0.0:11434)"
        else
            info "Creating systemd service for Ollama..."
            cat << EOF | sudo tee /etc/systemd/system/ollama.service > /dev/null
[Unit]
Description=Ollama LLM Server
After=network-online.target

[Service]
Type=simple
ExecStart=${ollama_bin} serve
Environment="OLLAMA_HOST=0.0.0.0"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable ollama
            sudo systemctl start ollama
            sleep 2
            if sudo systemctl is-active --quiet ollama; then
                ok "Ollama service created and started (0.0.0.0:11434)"
            else
                warn "Ollama service failed to start"
                echo ""
                echo "Check logs with: sudo journalctl -u ollama -n 20"
                echo ""
                sudo journalctl -u ollama -n 10 --no-pager 2>/dev/null || true
                return
            fi
        fi
    else
        warn "systemd not available"
        info "Starting Ollama manually..."
        OLLAMA_HOST=0.0.0.0 nohup "${ollama_bin}" serve > /tmp/ollama.log 2>&1 &
        sleep 3
    fi

    # Wait for Ollama API to be ready
    info "Waiting for Ollama API..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -s http://localhost:11434/api/tags &>/dev/null; then
            ok "Ollama is running"
            break
        fi
        retries=$((retries - 1))
        sleep 1
    done

    if [ $retries -eq 0 ]; then
        warn "Ollama API not responding after 30s"
        info "Check: sudo journalctl -u ollama"
        return
    fi

    select_ollama_models
}

show_inference_summary() {
    section "Installation Complete"

    local local_ip
    local_ip=$(get_local_ip)

    echo -e "${GREEN}${BOLD}Inference node is ready.${NC}"
    echo ""
    echo -e "${BOLD}Ollama Server:${NC}"
    echo -e "  Local:     http://localhost:11434"
    echo -e "  Network:   http://${local_ip}:11434"
    echo ""
    echo -e "${BOLD}Available Models:${NC}"
    ollama list 2>/dev/null || echo "  (none yet)"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ollama pull <model>   - Download a model"
    echo -e "  ollama list           - List models"
    echo -e "  ollama run <model>    - Chat with a model"
    echo ""
    echo -e "${CYAN}${BOLD}To use from cluster nodes:${NC}"
    echo -e "  OLLAMA_HOST=http://${local_ip}:11434"
    echo ""
}

main "$@"
