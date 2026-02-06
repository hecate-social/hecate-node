#!/usr/bin/env bash
#
# Hecate Node Uninstaller (k3s Edition)
# Usage: curl -fsSL https://hecate.io/uninstall.sh | bash
#
set -euo pipefail

INSTALL_DIR="${HECATE_INSTALL_DIR:-$HOME/.hecate}"
BIN_DIR="${HECATE_BIN_DIR:-$HOME/.local/bin}"
KUBECONFIG="${INSTALL_DIR}/kubeconfig"
GITOPS_DIR="${INSTALL_DIR}/gitops"

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo ""; echo -e "${MAGENTA}${BOLD}--- $* ---${NC}"; echo ""; }

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local yn_hint="[y/N]"
    [ "$default" = "y" ] && yn_hint="[Y/n]"
    echo -en "${CYAN}?${NC} ${prompt} ${yn_hint} " > /dev/tty
    read -r response < /dev/tty
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy] ]]
}

command_exists() { command -v "$1" &>/dev/null; }

echo ""
echo "    🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺"
echo ""
echo -e "    ${RED}${BOLD}🔥🗝️🔥  H E C A T E  🔥🗝️🔥${NC}"
echo -e "           ${DIM}U N I N S T A L L${NC}"
echo ""
echo "    🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺🇪🇺"
echo ""

# -----------------------------------------------------------------------------
# Detect Installation Type
# -----------------------------------------------------------------------------

section "Detecting Installation"

FOUND_K3S=false
FOUND_HECATE_NS=false
FOUND_FLUX=false
FOUND_KUBECONFIG=false
FOUND_CLI=false
FOUND_TUI=false
FOUND_GITOPS=false
FOUND_SOCKET=false

# Legacy Docker Compose detection
FOUND_LEGACY_COMPOSE=false
FOUND_LEGACY_CONTAINERS=false

# Check k3s
if command_exists k3s; then
    FOUND_K3S=true
    k3s_version=$(k3s --version 2>/dev/null | head -1 | awk '{print $3}' || echo "unknown")
    echo -e "  ${GREEN}+${NC} k3s installed: ${k3s_version}"
fi

# Check kubeconfig
if [ -f "$KUBECONFIG" ]; then
    FOUND_KUBECONFIG=true
    echo -e "  ${GREEN}+${NC} Kubeconfig: ${KUBECONFIG}"
    export KUBECONFIG
fi

# Check hecate namespace in k3s
if [ "$FOUND_K3S" = true ] && [ "$FOUND_KUBECONFIG" = true ]; then
    if kubectl get namespace hecate &>/dev/null; then
        FOUND_HECATE_NS=true
        echo -e "  ${GREEN}+${NC} Hecate namespace in cluster"
    fi

    if kubectl get namespace flux-system &>/dev/null; then
        FOUND_FLUX=true
        echo -e "  ${GREEN}+${NC} FluxCD installed"
    fi
fi

# Check GitOps directory
if [ -d "$GITOPS_DIR" ]; then
    FOUND_GITOPS=true
    echo -e "  ${GREEN}+${NC} GitOps directory: ${GITOPS_DIR}"
fi

# Check daemon socket
if [ -S "/run/hecate/daemon.sock" ]; then
    FOUND_SOCKET=true
    echo -e "  ${GREEN}+${NC} Daemon socket: /run/hecate/daemon.sock"
fi

# Check CLI wrapper
if [ -f "${BIN_DIR}/hecate" ]; then
    FOUND_CLI=true
    echo -e "  ${GREEN}+${NC} CLI wrapper: ${BIN_DIR}/hecate"
fi

# Check TUI binary
if [ -f "${BIN_DIR}/hecate-tui" ]; then
    FOUND_TUI=true
    echo -e "  ${GREEN}+${NC} TUI binary: ${BIN_DIR}/hecate-tui"
fi

# Check legacy Docker Compose installation
if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    FOUND_LEGACY_COMPOSE=true
    echo -e "  ${YELLOW}!${NC} Legacy Docker Compose: ${INSTALL_DIR}/docker-compose.yml"
fi

if command_exists docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "hecate"; then
    FOUND_LEGACY_CONTAINERS=true
    echo -e "  ${YELLOW}!${NC} Legacy Docker containers found"
fi

# Check if anything found
if [ "$FOUND_K3S" = false ] && [ "$FOUND_CLI" = false ] && [ "$FOUND_TUI" = false ] && \
   [ "$FOUND_LEGACY_COMPOSE" = false ] && [ "$FOUND_GITOPS" = false ]; then
    echo ""
    warn "No Hecate installation found"
    exit 0
fi

echo ""
if ! confirm "Uninstall Hecate?"; then
    echo "Cancelled."
    exit 0
fi

# -----------------------------------------------------------------------------
# Remove Legacy Docker Compose (if present)
# -----------------------------------------------------------------------------

if [ "$FOUND_LEGACY_CONTAINERS" = true ] || [ "$FOUND_LEGACY_COMPOSE" = true ]; then
    section "Removing Legacy Docker Installation"

    if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        info "Stopping Docker Compose services..."
        cd "${INSTALL_DIR}"
        docker compose down --remove-orphans 2>/dev/null || true
        ok "Legacy containers stopped"
    fi
fi

# -----------------------------------------------------------------------------
# Remove Hecate from Kubernetes
# -----------------------------------------------------------------------------

if [ "$FOUND_HECATE_NS" = true ]; then
    section "Removing Hecate from Cluster"

    info "Deleting hecate namespace and all resources..."
    kubectl delete namespace hecate --timeout=60s 2>/dev/null || true
    ok "Hecate namespace deleted"
fi

# -----------------------------------------------------------------------------
# Remove FluxCD (Optional)
# -----------------------------------------------------------------------------

if [ "$FOUND_FLUX" = true ]; then
    section "FluxCD"

    echo "FluxCD provides GitOps deployment for the cluster."
    echo ""

    if confirm "Remove FluxCD from cluster?"; then
        info "Uninstalling FluxCD..."
        if command_exists flux; then
            flux uninstall --namespace=flux-system --silent 2>/dev/null || true
        fi
        kubectl delete namespace flux-system --timeout=60s 2>/dev/null || true
        ok "FluxCD removed"
    else
        warn "Keeping FluxCD"
    fi
fi

# -----------------------------------------------------------------------------
# Remove k3s (Optional)
# -----------------------------------------------------------------------------

if [ "$FOUND_K3S" = true ]; then
    section "k3s Cluster"

    echo "k3s is the Kubernetes distribution powering Hecate."
    echo ""
    echo -e "${YELLOW}${BOLD}Warning:${NC} This will remove the ENTIRE k3s cluster,"
    echo "including any other workloads running on it."
    echo ""

    if confirm "Completely uninstall k3s?" "n"; then
        info "Uninstalling k3s..."

        # Use k3s uninstall scripts
        if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
            sudo /usr/local/bin/k3s-uninstall.sh
            ok "k3s server uninstalled"
        elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
            sudo /usr/local/bin/k3s-agent-uninstall.sh
            ok "k3s agent uninstalled"
        else
            warn "k3s uninstall script not found"
            echo "Try: sudo rm -rf /etc/rancher /var/lib/rancher"
        fi
    else
        warn "Keeping k3s"
        echo "The cluster remains available for other workloads."
    fi
fi

# -----------------------------------------------------------------------------
# Remove Binaries
# -----------------------------------------------------------------------------

section "Removing Binaries"

if [ "$FOUND_CLI" = true ]; then
    rm -f "${BIN_DIR}/hecate"
    ok "Removed ${BIN_DIR}/hecate"
fi

if [ "$FOUND_TUI" = true ]; then
    rm -f "${BIN_DIR}/hecate-tui"
    ok "Removed ${BIN_DIR}/hecate-tui"
fi

# Remove flux CLI if it was installed by us
if command_exists flux; then
    if confirm "Remove FluxCD CLI binary?"; then
        sudo rm -f /usr/local/bin/flux
        ok "Removed /usr/local/bin/flux"
    fi
fi

# -----------------------------------------------------------------------------
# Clean Socket Directory
# -----------------------------------------------------------------------------

if [ "$FOUND_SOCKET" = true ] || [ -d "/run/hecate" ]; then
    section "Socket Directory"

    if [ -d "/run/hecate" ]; then
        sudo rm -rf /run/hecate
        ok "Removed /run/hecate"
    fi
fi

# -----------------------------------------------------------------------------
# Clean Shell Profiles
# -----------------------------------------------------------------------------

section "Shell Profiles"

CLEANED_PROFILES=false
for profile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$profile" ]; then
        # Check for Hecate entries (both old and new style)
        if grep -qE "(# Hecate|KUBECONFIG.*hecate)" "$profile" 2>/dev/null; then
            info "Cleaning $profile..."

            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' '/# Hecate/d' "$profile" 2>/dev/null || true
                sed -i '' '/KUBECONFIG.*hecate/d' "$profile" 2>/dev/null || true
                sed -i '' '/\.local\/bin.*hecate/d' "$profile" 2>/dev/null || true
            else
                sed -i '/# Hecate/d' "$profile" 2>/dev/null || true
                sed -i '/KUBECONFIG.*hecate/d' "$profile" 2>/dev/null || true
                sed -i '/\.local\/bin.*hecate/d' "$profile" 2>/dev/null || true
            fi

            ok "Cleaned $profile"
            CLEANED_PROFILES=true
        fi
    fi
done

if [ "$CLEANED_PROFILES" = false ]; then
    echo "No Hecate entries found in shell profiles"
fi

# -----------------------------------------------------------------------------
# Remove Data Directory
# -----------------------------------------------------------------------------

section "Data Directory"

if [ -d "${INSTALL_DIR}" ]; then
    echo "Contents of ${INSTALL_DIR}:"
    ls -la "${INSTALL_DIR}" 2>/dev/null || true
    echo ""

    if confirm "Delete ${INSTALL_DIR}? ${RED}(includes kubeconfig, gitops, and data)${NC}"; then
        if rm -rf "${INSTALL_DIR}" 2>/dev/null; then
            ok "Removed ${INSTALL_DIR}"
        else
            warn "Some files are owned by root"
            info "Attempting removal with sudo..."
            if sudo rm -rf "${INSTALL_DIR}"; then
                ok "Removed ${INSTALL_DIR}"
            else
                warn "Failed to remove ${INSTALL_DIR}"
                echo "Try manually: sudo rm -rf ${INSTALL_DIR}"
            fi
        fi
    else
        warn "Kept ${INSTALL_DIR}"
        echo "Contains: kubeconfig, gitops manifests, daemon data"
    fi
fi

# -----------------------------------------------------------------------------
# Ollama Cleanup
# -----------------------------------------------------------------------------

section "Ollama (LLM Backend)"

OLLAMA_MODELS_DIR="${HOME}/.ollama"
OLLAMA_MODELS_SIZE=""

if [ -d "$OLLAMA_MODELS_DIR" ]; then
    OLLAMA_MODELS_SIZE=$(du -sh "$OLLAMA_MODELS_DIR" 2>/dev/null | cut -f1 || echo "unknown")
fi

if command_exists ollama || [ -d "$OLLAMA_MODELS_DIR" ]; then
    echo "Ollama was installed for LLM features."
    if [ -n "$OLLAMA_MODELS_SIZE" ]; then
        echo -e "Downloaded models: ${YELLOW}${OLLAMA_MODELS_SIZE}${NC} in ${OLLAMA_MODELS_DIR}"
    fi
    echo ""

    if confirm "Remove Ollama and downloaded models?"; then
        # Stop Ollama service if running
        if command_exists systemctl && systemctl is-active --quiet ollama 2>/dev/null; then
            info "Stopping Ollama service..."
            sudo systemctl stop ollama 2>/dev/null || true
            sudo systemctl disable ollama 2>/dev/null || true
        fi

        # Kill any running ollama process
        pkill -f ollama 2>/dev/null || true

        # Remove Ollama binary
        if [ -f /usr/local/bin/ollama ]; then
            sudo rm -f /usr/local/bin/ollama
            ok "Removed /usr/local/bin/ollama"
        fi

        # Remove Ollama service file
        if [ -f /etc/systemd/system/ollama.service ]; then
            sudo rm -f /etc/systemd/system/ollama.service
            sudo systemctl daemon-reload 2>/dev/null || true
            ok "Removed Ollama systemd service"
        fi

        # Remove models directory
        if [ -d "$OLLAMA_MODELS_DIR" ]; then
            rm -rf "$OLLAMA_MODELS_DIR"
            ok "Removed ${OLLAMA_MODELS_DIR} (${OLLAMA_MODELS_SIZE} freed)"
        fi
    else
        warn "Kept Ollama installation"
        echo "To remove manually later:"
        echo -e "  ${CYAN}sudo rm /usr/local/bin/ollama${NC}"
        echo -e "  ${CYAN}rm -rf ~/.ollama${NC}"
    fi
else
    echo "Ollama not found (not installed or already removed)"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

section "Uninstall Complete"

echo -e "${DIM}The goddess has departed. The crossroads await her return.${NC}"
echo ""
echo "Removed:"
[ "$FOUND_HECATE_NS" = true ] && echo "  - Hecate Kubernetes namespace"
[ "$FOUND_CLI" = true ] && echo "  - CLI wrapper (hecate)"
[ "$FOUND_TUI" = true ] && echo "  - TUI binary (hecate-tui)"
echo ""
echo "To summon her again:"
echo -e "  ${CYAN}curl -fsSL https://hecate.io/install.sh | bash${NC}"
echo ""
