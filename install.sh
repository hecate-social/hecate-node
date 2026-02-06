#!/usr/bin/env bash
#
# Hecate Node Installer (k3s Edition)
# Usage: curl -fsSL https://hecate.io/install.sh | bash
#
# Installs:
#   - k3s (lightweight Kubernetes)
#   - FluxCD (GitOps)
#   - hecate-daemon (via DaemonSet)
#   - hecate-tui (native binary)
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
REPO_BASE="https://github.com/hecate-social"

# Docker image (GitHub Container Registry)
HECATE_IMAGE="ghcr.io/hecate-social/hecate-daemon:main"

# Flags
HEADLESS=false
DAEMON_ONLY=false

# k3s role
K3S_ROLE="standalone"  # standalone, server, agent
K3S_SERVER_URL=""
K3S_TOKEN=""

# Feature roles
ROLE_WORKSTATION=false
ROLE_SERVICES=false
ROLE_AI=false

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
    echo "    🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺"
    echo ""
    echo -e "    ${MAGENTA}${BOLD}🔥🗝️🔥  H E C A T E  🔥🗝️🔥${NC}"
    echo -e "         ${DIM}Powered by Macula${NC}"
    echo ""
    echo "    🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺"
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

    # Detect firewall tool
    local fw_tool=""
    if command_exists ufw; then
        fw_tool="ufw"
    elif command_exists firewall-cmd; then
        fw_tool="firewalld"
    else
        warn "No firewall detected (ufw/firewalld)"
        info "Ensure these ports are open manually:"
        show_required_ports
        return
    fi

    info "Detected firewall: ${fw_tool}"
    echo ""
    show_required_ports
    echo ""

    if ! confirm "Configure firewall rules?" "y"; then
        warn "Skipping firewall configuration"
        return
    fi

    case "$fw_tool" in
        ufw)
            configure_ufw
            ;;
        firewalld)
            configure_firewalld
            ;;
    esac
}

show_required_ports() {
    case "$K3S_ROLE" in
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
        server)
            echo "Required ports for Server node:"
            echo -e "  ${CYAN}6443/tcp${NC}   - k3s API (for agents)"
            echo -e "  ${CYAN}4433/udp${NC}   - Macula mesh (QUIC)"
            echo -e "  ${CYAN}4369/tcp${NC}   - EPMD (Erlang)"
            echo -e "  ${CYAN}9100/tcp${NC}   - Erlang distribution"
            echo -e "  ${CYAN}8472/udp${NC}   - Flannel VXLAN"
            echo -e "  ${CYAN}10250/tcp${NC}  - Kubelet"
            echo -e "  ${CYAN}22/tcp${NC}     - SSH"
            ;;
        agent)
            echo "Required ports for Agent node:"
            echo -e "  ${CYAN}4433/udp${NC}   - Macula mesh (QUIC)"
            echo -e "  ${CYAN}4369/tcp${NC}   - EPMD (Erlang)"
            echo -e "  ${CYAN}9100/tcp${NC}   - Erlang distribution"
            echo -e "  ${CYAN}8472/udp${NC}   - Flannel VXLAN"
            echo -e "  ${CYAN}10250/tcp${NC}  - Kubelet"
            echo -e "  ${CYAN}22/tcp${NC}     - SSH"
            ;;
    esac
}

configure_ufw() {
    info "Configuring ufw..."

    # Common: SSH
    sudo ufw allow ssh

    case "$K3S_ROLE" in
        inference)
            sudo ufw allow 11434/tcp comment 'Ollama API'
            ;;
        standalone)
            sudo ufw allow 4433/udp comment 'Macula mesh'
            ;;
        server)
            sudo ufw allow 6443/tcp comment 'k3s API'
            sudo ufw allow 4433/udp comment 'Macula mesh'
            sudo ufw allow 4369/tcp comment 'EPMD'
            sudo ufw allow 9100/tcp comment 'Erlang dist'
            sudo ufw allow 8472/udp comment 'Flannel VXLAN'
            sudo ufw allow 10250/tcp comment 'Kubelet'
            ;;
        agent)
            sudo ufw allow 4433/udp comment 'Macula mesh'
            sudo ufw allow 4369/tcp comment 'EPMD'
            sudo ufw allow 9100/tcp comment 'Erlang dist'
            sudo ufw allow 8472/udp comment 'Flannel VXLAN'
            sudo ufw allow 10250/tcp comment 'Kubelet'
            ;;
    esac

    # Enable if not already
    if ! sudo ufw status | grep -q "Status: active"; then
        sudo ufw --force enable
    fi

    sudo ufw reload
    ok "ufw configured"
}

configure_firewalld() {
    info "Configuring firewalld..."

    case "$K3S_ROLE" in
        inference)
            sudo firewall-cmd --permanent --add-port=11434/tcp
            ;;
        standalone)
            sudo firewall-cmd --permanent --add-port=4433/udp
            ;;
        server)
            sudo firewall-cmd --permanent --add-port=6443/tcp
            sudo firewall-cmd --permanent --add-port=4433/udp
            sudo firewall-cmd --permanent --add-port=4369/tcp
            sudo firewall-cmd --permanent --add-port=9100/tcp
            sudo firewall-cmd --permanent --add-port=8472/udp
            sudo firewall-cmd --permanent --add-port=10250/tcp
            ;;
        agent)
            sudo firewall-cmd --permanent --add-port=4433/udp
            sudo firewall-cmd --permanent --add-port=4369/tcp
            sudo firewall-cmd --permanent --add-port=9100/tcp
            sudo firewall-cmd --permanent --add-port=8472/udp
            sudo firewall-cmd --permanent --add-port=10250/tcp
            ;;
    esac

    sudo firewall-cmd --reload
    ok "firewalld configured"
}

# -----------------------------------------------------------------------------
# Node Role Selection
# -----------------------------------------------------------------------------

select_k3s_role() {
    section "Node Role Selection"

    echo "What type of node is this?"
    echo ""
    echo -e "  ${BOLD}1)${NC} Standalone     ${DIM}- Single-node cluster (default)${NC}"
    echo -e "  ${BOLD}2)${NC} Server         ${DIM}- Control plane (can add agents later)${NC}"
    echo -e "  ${BOLD}3)${NC} Agent          ${DIM}- Join existing cluster${NC}"
    echo -e "  ${BOLD}4)${NC} Inference      ${DIM}- Dedicated Ollama server (no k3s)${NC}"
    echo ""

    if [ "$HEADLESS" = true ]; then
        K3S_ROLE="standalone"
        info "Headless mode: defaulting to standalone"
        return
    fi

    echo -en "  Enter choice [1]: " > /dev/tty
    read -r choice < /dev/tty
    choice="${choice:-1}"

    case "$choice" in
        1) K3S_ROLE="standalone" ;;
        2) K3S_ROLE="server" ;;
        3)
            K3S_ROLE="agent"
            echo ""
            echo -en "  Server URL (e.g., https://192.168.1.10:6443): " > /dev/tty
            read -r K3S_SERVER_URL < /dev/tty
            echo -en "  Join token: " > /dev/tty
            read -r K3S_TOKEN < /dev/tty
            if [ -z "$K3S_SERVER_URL" ] || [ -z "$K3S_TOKEN" ]; then
                fatal "Server URL and token are required for agent mode"
            fi
            ;;
        4)
            K3S_ROLE="inference"
            # Inference mode: just Ollama, no k3s
            ROLE_AI=true
            ROLE_WORKSTATION=false
            ROLE_SERVICES=false
            ;;
        *) K3S_ROLE="standalone" ;;
    esac

    echo ""
    ok "Node role: ${K3S_ROLE}"
}

# -----------------------------------------------------------------------------
# Feature Role Selection
# -----------------------------------------------------------------------------

# Ollama host (for remote Ollama servers)
OLLAMA_HOST="http://localhost:11434"

select_feature_roles() {
    section "Feature Selection"

    # Agent nodes: no TUI, no feature selection - they just run workloads
    if [ "$K3S_ROLE" = "agent" ]; then
        ROLE_SERVICES=true
        info "Agent mode: workloads only (no TUI)"
        echo ""
        ok "Agent node configured"
        return
    fi

    # Server/standalone: TUI by default, ask about AI
    if [ "$K3S_ROLE" = "server" ] || [ "$K3S_ROLE" = "standalone" ]; then
        ROLE_WORKSTATION=true  # Always install TUI on server
        ROLE_SERVICES=true
    fi

    if [ "$DAEMON_ONLY" = true ]; then
        ROLE_WORKSTATION=false
        ROLE_SERVICES=true
        info "Daemon-only mode: services role only"
        return
    fi

    if [ "$HEADLESS" = true ]; then
        info "Headless mode: TUI + services"
        return
    fi

    echo "This node will have: TUI + Services (default for ${K3S_ROLE})"
    echo ""

    # Ask about AI/Ollama
    if confirm "Enable AI features (LLM inference)?" "y"; then
        ROLE_AI=true

        # Ask about Ollama location
        echo ""
        echo "Where is Ollama running?"
        echo ""
        echo -e "  ${BOLD}1)${NC} Local          ${DIM}- Install Ollama on this machine${NC}"
        echo -e "  ${BOLD}2)${NC} Remote         ${DIM}- Ollama runs on another server${NC}"
        echo ""
        echo -en "  Enter choice [1]: " > /dev/tty
        read -r ollama_choice < /dev/tty
        ollama_choice="${ollama_choice:-1}"

        if [ "$ollama_choice" = "2" ]; then
            echo ""
            echo -en "  Ollama host (e.g., host00.lab:11434): " > /dev/tty
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
                ROLE_AI=false  # Don't install Ollama locally
                ok "Using remote Ollama: ${OLLAMA_HOST}"
            fi
        fi
    fi

    echo ""
    local roles=("workstation" "services")
    [ "$ROLE_AI" = true ] && roles+=("ai-provider (local)")
    [ "$OLLAMA_HOST" != "http://localhost:11434" ] && roles+=("ai-client (${OLLAMA_HOST})")
    ok "Selected features: ${roles[*]}"
}

# -----------------------------------------------------------------------------
# k3s Installation
# -----------------------------------------------------------------------------

check_k3s() {
    if command_exists k3s; then
        local version
        version=$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')
        ok "k3s installed: ${version}"
        return 0
    fi
    return 1
}

install_k3s() {
    section "Installing k3s"

    local os
    os=$(detect_os)

    if [ "$os" = "darwin" ]; then
        fatal "k3s is not supported on macOS. Use Docker Desktop with Kubernetes instead."
    fi

    echo "k3s is a lightweight Kubernetes distribution."
    echo ""
    echo -e "${YELLOW}${BOLD}Requires sudo access${NC}"
    echo ""

    if ! confirm "Install k3s?" "y"; then
        fatal "k3s is required for Hecate"
    fi

    local install_opts=""

    case "$K3S_ROLE" in
        standalone)
            # Single-node, disable traefik (we don't need ingress)
            install_opts="--disable=traefik"
            ;;
        server)
            install_opts="--disable=traefik"
            ;;
        agent)
            # Agent mode - join existing cluster
            export K3S_URL="$K3S_SERVER_URL"
            export K3S_TOKEN="$K3S_TOKEN"
            ;;
    esac

    info "Installing k3s (${K3S_ROLE} mode)..."

    if [ "$K3S_ROLE" = "agent" ]; then
        curl -sfL https://get.k3s.io | sh -s - agent $install_opts
    else
        curl -sfL https://get.k3s.io | sh -s - $install_opts
    fi

    if ! command_exists k3s; then
        fatal "k3s installation failed"
    fi

    ok "k3s installed"

    # Wait for k3s to be ready
    info "Waiting for k3s to be ready..."
    local retries=60
    while [ $retries -gt 0 ]; do
        if sudo k3s kubectl get nodes &>/dev/null; then
            ok "k3s is ready"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [ $retries -eq 0 ]; then
        fatal "k3s failed to start"
    fi

    # Setup kubeconfig for non-root user
    setup_kubeconfig
}

setup_kubeconfig() {
    section "Setting up kubeconfig"

    mkdir -p "${INSTALL_DIR}"

    # Copy kubeconfig and fix permissions
    sudo cp /etc/rancher/k3s/k3s.yaml "${INSTALL_DIR}/kubeconfig"
    sudo chown "$(id -u):$(id -g)" "${INSTALL_DIR}/kubeconfig"
    chmod 600 "${INSTALL_DIR}/kubeconfig"

    # Update server address if needed (for remote access)
    local local_ip
    local_ip=$(get_local_ip)
    sed -i "s/127.0.0.1/${local_ip}/g" "${INSTALL_DIR}/kubeconfig"

    # Set KUBECONFIG for current session
    export KUBECONFIG="${INSTALL_DIR}/kubeconfig"

    ok "Kubeconfig saved to ${INSTALL_DIR}/kubeconfig"

    # Show join command for server mode
    if [ "$K3S_ROLE" = "server" ]; then
        echo ""
        echo -e "${CYAN}${BOLD}To add agent nodes, run on the agent:${NC}"
        echo ""
        local token
        token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
        echo "  curl -sfL https://get.k3s.io | K3S_URL=https://${local_ip}:6443 K3S_TOKEN=${token} sh -s - agent"
        echo ""
    fi
}

ensure_k3s() {
    if ! check_k3s; then
        install_k3s
    else
        # k3s exists, just setup kubeconfig
        if [ ! -f "${INSTALL_DIR}/kubeconfig" ]; then
            setup_kubeconfig
        fi
        export KUBECONFIG="${INSTALL_DIR}/kubeconfig"
    fi
}

# -----------------------------------------------------------------------------
# FluxCD Installation
# -----------------------------------------------------------------------------

check_flux() {
    if command_exists flux; then
        ok "FluxCD CLI installed"
        return 0
    fi
    return 1
}

install_flux() {
    section "Installing FluxCD"

    echo "FluxCD provides GitOps-based deployment."
    echo ""

    # Install flux CLI
    if ! check_flux; then
        info "Installing FluxCD CLI..."
        curl -s https://fluxcd.io/install.sh | sudo bash
        ok "FluxCD CLI installed"
    fi

    # Bootstrap flux to cluster
    info "Bootstrapping FluxCD to cluster..."

    # Create flux-system namespace
    kubectl create namespace flux-system 2>/dev/null || true

    # Install flux components
    flux install --namespace=flux-system

    ok "FluxCD installed in cluster"
}

# -----------------------------------------------------------------------------
# GitOps Repository Setup
# -----------------------------------------------------------------------------

HECATE_GITOPS_REPO="https://github.com/hecate-social/hecate-gitops.git"

setup_gitops_repo() {
    section "Setting up GitOps Repository"

    # Clone or update hecate-gitops
    if [ -d "${GITOPS_DIR}/.git" ]; then
        info "GitOps repo exists, pulling latest..."
        cd "${GITOPS_DIR}"
        git pull --ff-only origin main 2>/dev/null || true
    else
        info "Cloning hecate-gitops..."
        rm -rf "${GITOPS_DIR}"
        git clone "${HECATE_GITOPS_REPO}" "${GITOPS_DIR}"
        cd "${GITOPS_DIR}"
    fi

    ok "GitOps repository ready at ${GITOPS_DIR}"

    # Update FluxCD source to point to local path
    update_flux_source

    # Update hardware configuration with detected values
    update_hardware_config

    # Commit local changes
    git add -A
    git commit -m "Configure for local cluster" 2>/dev/null || true

    ok "GitOps configuration complete"
}

update_flux_source() {
    info "Configuring FluxCD source..."

    cat > flux-system/gotk-sync.yaml << EOF
# FluxCD GitRepository and Kustomization
# Points to this local repository
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: hecate-gitops
  namespace: flux-system
spec:
  interval: 1m
  url: file://${GITOPS_DIR}
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hecate-cluster
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: hecate-gitops
  path: ./clusters/local
  prune: true
EOF

    ok "FluxCD configured for local repository"
}

update_hardware_config() {
    info "Updating hardware configuration..."

    # Determine GPU type string
    local gpu_type="none"
    if [ "$DETECTED_HAS_GPU" = true ]; then
        gpu_type="${DETECTED_GPU_TYPE}"
    fi

    # Update the hardware patch with detected values
    cat > clusters/local/hardware-patch.yaml << EOF
# Hardware configuration for this cluster
# Generated by install script based on detected hardware
apiVersion: v1
kind: ConfigMap
metadata:
  name: hecate-config
  namespace: hecate
data:
  HECATE_RAM_GB: "${DETECTED_RAM_GB}"
  HECATE_CPU_CORES: "${DETECTED_CPU_CORES}"
  HECATE_GPU: "${gpu_type}"
  HECATE_GPU_VRAM_GB: "0"
  OLLAMA_HOST: "${OLLAMA_HOST}"
EOF

    ok "Hardware config: ${DETECTED_RAM_GB}GB RAM, ${DETECTED_CPU_CORES} cores, GPU: ${gpu_type}"
    if [ "$OLLAMA_HOST" != "http://localhost:11434" ]; then
        ok "Remote Ollama: ${OLLAMA_HOST}"
    fi
}

# -----------------------------------------------------------------------------
# Deploy to Cluster
# -----------------------------------------------------------------------------

deploy_hecate() {
    section "Deploying Hecate to Cluster"

    cd "${GITOPS_DIR}"

    # Apply flux sync
    kubectl apply -f flux-system/gotk-sync.yaml 2>/dev/null || true

    # Direct apply for immediate deployment (using clusters/local which includes infra)
    kubectl apply -k clusters/local/

    # Wait for daemon to be ready
    info "Waiting for daemon pods..."
    local retries=60
    while [ $retries -gt 0 ]; do
        local ready
        ready=$(kubectl get pods -n hecate -l app=hecate-daemon -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$ready" == *"True"* ]]; then
            ok "Daemon is running"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [ $retries -eq 0 ]; then
        warn "Daemon pods not ready yet. Check with: kubectl get pods -n hecate"
    fi

    # Wait for socket to appear
    info "Waiting for daemon socket..."
    retries=30
    while [ $retries -gt 0 ]; do
        if [ -S "/run/hecate/daemon.sock" ]; then
            ok "Daemon socket ready at /run/hecate/daemon.sock"
            break
        fi
        retries=$((retries - 1))
        sleep 1
    done
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
    curl -fsSL https://ollama.com/install.sh | sh

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

setup_ollama() {
    if [ "$ROLE_AI" = false ]; then
        return
    fi

    if ! check_ollama; then
        install_ollama
    fi

    # Pull a default model
    if command_exists ollama && confirm "Pull llama3.2 model (2GB)?" "y"; then
        info "Pulling llama3.2..."
        ollama pull llama3.2
        ok "Model ready"
    fi
}

# -----------------------------------------------------------------------------
# Terminal Configuration
# -----------------------------------------------------------------------------

check_terminal_capabilities() {
    section "Checking Terminal Capabilities"

    local term_ok=true
    local colors=0

    # Check TERM variable
    if [ -z "${TERM:-}" ] || [ "$TERM" = "dumb" ]; then
        warn "TERM is not set or is 'dumb'"
        term_ok=false
    else
        ok "TERM: $TERM"
    fi

    # Check color support
    if command_exists tput; then
        colors=$(tput colors 2>/dev/null || echo "0")
        if [ "$colors" -ge 256 ]; then
            ok "Colors: $colors (excellent)"
        elif [ "$colors" -ge 8 ]; then
            warn "Colors: $colors (limited, recommend 256)"
            term_ok=false
        else
            warn "Colors: $colors (poor)"
            term_ok=false
        fi
    else
        warn "tput not available, cannot detect colors"
    fi

    # Check if we're over SSH
    if [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
        info "Running over SSH"
    fi

    # If terminal is not optimal, configure it
    if [ "$term_ok" = false ]; then
        configure_terminal
    fi
}

configure_terminal() {
    info "Configuring terminal for TUI..."

    # Create a wrapper script that ensures proper terminal settings
    mkdir -p "$BIN_DIR"
    cat > "${BIN_DIR}/hecate-tui-wrapped" << 'TUIWRAPPER'
#!/usr/bin/env bash
# Wrapper to ensure proper terminal settings for Hecate TUI

# Ensure TERM is set for 256 colors
if [ -z "$TERM" ] || [ "$TERM" = "dumb" ] || [ "$TERM" = "vt100" ]; then
    export TERM="xterm-256color"
fi

# Check if TERM supports 256 colors, upgrade if not
case "$TERM" in
    xterm|screen|tmux|rxvt)
        export TERM="${TERM}-256color"
        ;;
esac

# Run the actual TUI
exec "$(dirname "$0")/hecate-tui" "$@"
TUIWRAPPER
    chmod +x "${BIN_DIR}/hecate-tui-wrapped"

    # Add terminal config to shell profile
    local shell_profile=""
    if [ -f "$HOME/.zshrc" ]; then
        shell_profile="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        shell_profile="$HOME/.bashrc"
    fi

    if [ -n "$shell_profile" ]; then
        if ! grep -q "# Hecate terminal config" "$shell_profile" 2>/dev/null; then
            cat >> "$shell_profile" << 'TERMCONFIG'

# Hecate terminal config
# Ensure 256 color support for TUI
if [ "$TERM" = "xterm" ] || [ "$TERM" = "screen" ]; then
    export TERM="${TERM}-256color"
fi
TERMCONFIG
            ok "Added terminal config to $shell_profile"
        fi
    fi

    ok "Terminal configured for 256-color support"
    info "Use 'hecate-tui-wrapped' if colors are still broken"
}

# -----------------------------------------------------------------------------
# TUI Installation
# -----------------------------------------------------------------------------

install_tui() {
    if [ "$ROLE_WORKSTATION" = false ]; then
        return
    fi

    # Check terminal capabilities first
    check_terminal_capabilities

    section "Installing Hecate TUI"

    local os arch version url
    os=$(detect_os)
    arch=$(detect_arch)

    version=$(get_latest_release "hecate-tui")
    if [ -z "$version" ]; then
        version="v0.1.0"
    fi

    url="${REPO_BASE}/hecate-tui/releases/download/${version}/hecate-tui-${os}-${arch}.tar.gz"

    mkdir -p "$BIN_DIR"
    local tmpfile
    tmpfile=$(mktemp)

    download_file "$url" "$tmpfile"
    tar -xzf "$tmpfile" -C "$BIN_DIR" 2>/dev/null || tar -xzf "$tmpfile" -C "$BIN_DIR"
    rm -f "$tmpfile"

    chmod +x "${BIN_DIR}/hecate-tui"

    ok "Hecate TUI ${version} installed"
}

# -----------------------------------------------------------------------------
# CLI Wrapper
# -----------------------------------------------------------------------------

install_cli_wrapper() {
    section "Installing CLI Wrapper"

    mkdir -p "$BIN_DIR"

    cat > "${BIN_DIR}/hecate" << 'WRAPPER'
#!/usr/bin/env bash
# Hecate CLI wrapper - manages hecate via k3s
set -euo pipefail

HECATE_DIR="${HECATE_DIR:-$HOME/.hecate}"
KUBECONFIG="${HECATE_DIR}/kubeconfig"
SOCKET="/run/hecate/daemon.sock"

export KUBECONFIG

kubectl_hecate() {
    kubectl -n hecate "$@"
}

case "${1:-help}" in
    start)
        echo "Starting Hecate daemon..."
        kubectl_hecate rollout restart daemonset/hecate-daemon
        kubectl_hecate rollout status daemonset/hecate-daemon
        ;;
    stop)
        echo "Scaling down Hecate daemon..."
        kubectl_hecate patch daemonset hecate-daemon -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}'
        ;;
    restart)
        echo "Restarting Hecate daemon..."
        kubectl_hecate rollout restart daemonset/hecate-daemon
        ;;
    status)
        kubectl_hecate get pods -o wide
        echo ""
        kubectl_hecate get daemonset
        ;;
    logs)
        kubectl_hecate logs -l app=hecate-daemon -f "${@:2}"
        ;;
    update)
        echo "Updating Hecate..."
        kubectl_hecate set image daemonset/hecate-daemon daemon=ghcr.io/hecate-social/hecate-daemon:main
        kubectl_hecate rollout status daemonset/hecate-daemon
        ;;
    health)
        if [ -S "$SOCKET" ]; then
            curl -s --unix-socket "$SOCKET" http://localhost/health
        else
            curl -s http://localhost:4444/health
        fi
        ;;
    identity)
        if [ -S "$SOCKET" ]; then
            curl -s --unix-socket "$SOCKET" http://localhost/identity
        else
            curl -s http://localhost:4444/identity
        fi
        ;;
    nodes)
        kubectl get nodes -o wide
        ;;
    gitops)
        echo "GitOps directory: ${HECATE_DIR}/gitops"
        echo ""
        echo "Edit manifests and commit to apply changes:"
        echo "  cd ${HECATE_DIR}/gitops"
        echo "  # edit files..."
        echo "  git add -A && git commit -m 'Update'"
        echo "  kubectl apply -k hecate/"
        ;;
    *)
        echo "Hecate - Powered by Macula"
        echo ""
        echo "Usage: hecate <command>"
        echo ""
        echo "Commands:"
        echo "  start      Restart daemon pods"
        echo "  stop       Scale down daemon"
        echo "  restart    Rolling restart"
        echo "  status     Show pod status"
        echo "  logs       View daemon logs"
        echo "  update     Pull latest image"
        echo "  health     Check daemon health"
        echo "  identity   Show identity"
        echo "  nodes      List cluster nodes"
        echo "  gitops     Show GitOps directory"
        echo ""
        echo "TUI:"
        echo "  hecate-tui    Launch terminal UI"
        ;;
esac
WRAPPER

    chmod +x "${BIN_DIR}/hecate"

    ok "CLI wrapper installed"
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
                echo "export KUBECONFIG=\"${INSTALL_DIR}/kubeconfig\"" >> "$shell_profile"
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
    echo -e "${BOLD}Cluster:${NC}"
    echo -e "  Role:     ${K3S_ROLE}"
    echo -e "  Nodes:    $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
    echo ""
    echo -e "${BOLD}Components:${NC}"
    echo -e "  ${CYAN}hecate${NC}       - CLI wrapper"
    [ "$ROLE_WORKSTATION" = true ] && echo -e "  ${CYAN}hecate-tui${NC}   - Terminal UI"
    if [ "$ROLE_AI" = true ] && command_exists ollama; then
        echo -e "  ${CYAN}ollama${NC}       - LLM backend (local)"
    elif [ "$OLLAMA_HOST" != "http://localhost:11434" ]; then
        echo -e "  ${CYAN}ollama${NC}       - LLM backend (${OLLAMA_HOST})"
    fi
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  hecate status     - Pod status"
    echo -e "  hecate logs       - View logs"
    [ "$ROLE_WORKSTATION" = true ] && echo -e "  hecate-tui        - Launch TUI"
    echo ""
    echo -e "Socket:    /run/hecate/daemon.sock"
    echo -e "API:       http://localhost:4444"
    echo -e "Ollama:    ${OLLAMA_HOST}"
    echo -e "GitOps:    ${GITOPS_DIR}"
    echo ""

    if [ "$K3S_ROLE" = "server" ]; then
        echo -e "${CYAN}${BOLD}Join token for agents:${NC}"
        echo ""
        local token
        token=$(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo "N/A")
        echo "  K3S_URL=https://${local_ip}:6443"
        echo "  K3S_TOKEN=${token}"
        echo ""
    fi
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

show_help() {
    echo "Hecate Node Installer (k3s Edition)"
    echo ""
    echo "Usage: curl -fsSL https://hecate.io/install.sh | bash"
    echo ""
    echo "Options:"
    echo "  --daemon-only     Install daemon without TUI"
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
    select_k3s_role

    # Inference mode has a different flow
    if [ "$K3S_ROLE" = "inference" ]; then
        run_inference_install
        return
    fi

    select_feature_roles

    echo ""
    echo "This installer will set up:"
    echo "  • k3s (${K3S_ROLE} mode)"
    echo "  • FluxCD (GitOps)"
    echo "  • Hecate daemon (DaemonSet)"
    [ "$ROLE_WORKSTATION" = true ] && echo "  • Hecate TUI"
    if [ "$ROLE_AI" = true ]; then
        echo "  • Ollama (local)"
    elif [ "$OLLAMA_HOST" != "http://localhost:11434" ]; then
        echo "  • Ollama (remote: ${OLLAMA_HOST})"
    fi
    echo "  • Firewall rules"
    echo ""

    if ! confirm "Continue with installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi

    configure_firewall
    ensure_k3s
    install_flux
    setup_gitops_repo
    deploy_hecate
    setup_ollama
    install_tui
    install_cli_wrapper
    setup_path

    show_summary
}

# -----------------------------------------------------------------------------
# Inference Node Install (Ollama-only)
# -----------------------------------------------------------------------------

run_inference_install() {
    echo ""
    echo "This installer will set up:"
    echo "  • Ollama (LLM inference server)"
    echo "  • Firewall rules (port 11434)"
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
        curl -fsSL https://ollama.com/install.sh | sh
        ollama_bin=$(command -v ollama)
    fi

    # Configure Ollama to listen on all interfaces
    info "Configuring Ollama for network access..."

    if command_exists systemctl; then
        # Check if ollama.service exists
        if systemctl list-unit-files ollama.service &>/dev/null && \
           systemctl list-unit-files ollama.service | grep -q ollama; then
            # Service exists, add override
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
            # No service file - create one
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
            ok "Ollama service created and started (0.0.0.0:11434)"
        fi
    else
        warn "systemd not available"
        info "Set OLLAMA_HOST=0.0.0.0 manually before starting Ollama"
    fi

    # Wait for Ollama to be ready
    info "Waiting for Ollama..."
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
        warn "Ollama did not start in time, check: sudo journalctl -u ollama"
    fi

    # Pull a default model
    if confirm "Pull llama3.2 model (2GB)?" "y"; then
        info "Pulling llama3.2..."
        ollama pull llama3.2
        ok "Model ready"
    fi
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
