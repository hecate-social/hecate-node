#!/usr/bin/env bash
#
# Hecate Node Uninstaller
# Usage: curl -fsSL https://macula.io/hecate/uninstall.sh | bash
#
set -euo pipefail

INSTALL_DIR="${HECATE_INSTALL_DIR:-$HOME/.hecate}"
BIN_DIR="${HECATE_BIN_DIR:-$HOME/.local/bin}"

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo ""; echo -e "${CYAN}${BOLD}━━━ $* ━━━${NC}"; echo ""; }

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

echo ""
echo -e "${RED}${BOLD}    🗝️  H E C A T E  🗝️${NC}"
echo ""
echo -e "${BOLD}Hecate Node Uninstaller${NC}"
echo -e "${DIM}The goddess prepares to depart...${NC}"
echo ""

section "Detecting Installation"

FOUND_COMPOSE=false
FOUND_CONTAINERS=false
FOUND_CLI=false
FOUND_TUI=false

if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    FOUND_COMPOSE=true
    echo -e "  ${GREEN}✓${NC} Docker Compose: ${INSTALL_DIR}/docker-compose.yml"
fi

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "hecate"; then
    FOUND_CONTAINERS=true
    echo -e "  ${GREEN}✓${NC} Docker containers: hecate-daemon, hecate-watchtower"
fi

if [ -f "${BIN_DIR}/hecate" ]; then
    FOUND_CLI=true
    echo -e "  ${GREEN}✓${NC} CLI wrapper: ${BIN_DIR}/hecate"
fi

if [ -f "${BIN_DIR}/hecate-tui" ]; then
    FOUND_TUI=true
    echo -e "  ${GREEN}✓${NC} TUI binary: ${BIN_DIR}/hecate-tui"
fi

if [ "$FOUND_COMPOSE" = false ] && [ "$FOUND_CLI" = false ] && [ "$FOUND_TUI" = false ]; then
    echo ""
    warn "No Hecate installation found"
    exit 0
fi

echo ""
if ! confirm "Uninstall Hecate?"; then
    echo "Cancelled."
    exit 0
fi

# Stop and remove containers
if [ "$FOUND_CONTAINERS" = true ] || [ "$FOUND_COMPOSE" = true ]; then
    section "Stopping Docker Containers"

    if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        cd "${INSTALL_DIR}"
        docker compose down --remove-orphans 2>/dev/null || true
        ok "Containers stopped and removed"
    fi
fi

# Remove binaries
section "Removing Binaries"

if [ "$FOUND_CLI" = true ]; then
    rm -f "${BIN_DIR}/hecate"
    ok "Removed ${BIN_DIR}/hecate"
fi

if [ "$FOUND_TUI" = true ]; then
    rm -f "${BIN_DIR}/hecate-tui"
    ok "Removed ${BIN_DIR}/hecate-tui"
fi

# Clean shell profiles (PATH entries added by installer)
section "Shell Profiles"

CLEANED_PROFILES=false
for profile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$profile" ] && grep -q "# Hecate CLI" "$profile"; then
        # Use different sed syntax for macOS vs Linux
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' '/# Hecate CLI/d' "$profile" 2>/dev/null || true
            sed -i '' '/\.local\/bin.*hecate/d' "$profile" 2>/dev/null || true
        else
            sed -i '/# Hecate CLI/d' "$profile" 2>/dev/null || true
            sed -i '/\.local\/bin.*hecate/d' "$profile" 2>/dev/null || true
        fi
        ok "Cleaned PATH entries from $profile"
        CLEANED_PROFILES=true
    fi
done

if [ "$CLEANED_PROFILES" = false ]; then
    echo "No Hecate PATH entries found in shell profiles"
fi

# Remove data directory
section "Data Directory"

if [ -d "${INSTALL_DIR}" ]; then
    echo "Contents:"
    ls -la "${INSTALL_DIR}" 2>/dev/null || true
    echo ""

    if confirm "Delete ${INSTALL_DIR}? ${RED}(includes config and data)${NC}"; then
        # Try regular rm first, fall back to sudo if permission denied
        if rm -rf "${INSTALL_DIR}" 2>/dev/null; then
            ok "Removed ${INSTALL_DIR}"
        else
            warn "Some files are owned by root (daemon ran with elevated privileges)"
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
    fi
fi

# Docker images
section "Docker Images"

echo "Hecate Docker images can be removed with:"
echo -e "  ${CYAN}docker rmi ghcr.io/hecate-social/hecate-daemon${NC}"
echo -e "  ${CYAN}docker rmi containrrr/watchtower${NC}"
echo ""
echo "Docker itself was NOT removed."

# Ollama cleanup
section "Ollama (LLM Backend)"

OLLAMA_MODELS_DIR="${HOME}/.ollama"
OLLAMA_MODELS_SIZE=""

if [ -d "$OLLAMA_MODELS_DIR" ]; then
    OLLAMA_MODELS_SIZE=$(du -sh "$OLLAMA_MODELS_DIR" 2>/dev/null | cut -f1 || echo "unknown")
fi

if command -v ollama &>/dev/null || [ -d "$OLLAMA_MODELS_DIR" ]; then
    echo "Ollama was installed for LLM features."
    if [ -n "$OLLAMA_MODELS_SIZE" ]; then
        echo -e "Downloaded models: ${YELLOW}${OLLAMA_MODELS_SIZE}${NC} in ${OLLAMA_MODELS_DIR}"
    fi
    echo ""
    
    if confirm "Remove Ollama and downloaded models?"; then
        # Stop Ollama service if running
        if command -v systemctl &>/dev/null && systemctl is-active --quiet ollama 2>/dev/null; then
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

section "🔥🗝️🔥 Uninstall Complete"

echo -e "${DIM}The goddess has departed. The crossroads await her return.${NC}"
echo ""
echo "To summon her again:"
echo -e "  ${CYAN}curl -fsSL https://macula.io/hecate/install.sh | bash${NC}"
echo ""
