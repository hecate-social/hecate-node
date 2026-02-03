#!/usr/bin/env bash
#
# Hecate Node Uninstaller
# Usage: curl -fsSL https://hecate.social/uninstall.sh | bash
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

INSTALL_DIR="${HECATE_INSTALL_DIR:-$HOME/.hecate}"
BIN_DIR="${HECATE_BIN_DIR:-$HOME/.local/bin}"

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo ""; echo -e "${CYAN}${BOLD}━━━ $* ━━━${NC}"; echo ""; }

command_exists() { command -v "$1" &>/dev/null; }

confirm() {
    local prompt="$1"
    local default="${2:-n}"

    local yn_hint="[y/N]"
    [ "$default" = "y" ] && yn_hint="[Y/n]"

    echo -en "${CYAN}?${NC} ${prompt} ${yn_hint} "
    read -r response
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy] ]]
}

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------

show_banner() {
    echo -e "${RED}${BOLD}"
    cat << 'EOF'
    __  __              __
   / / / /__  _______ _/ /____
  / /_/ / _ \/ __/ _ `/ __/ -_)
 /_//_/\___/\__/\_,_/\__/\__/

EOF
    echo -e "${NC}"
    echo -e "${BOLD}Hecate Node Uninstaller${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------

FOUND_DAEMON=false
FOUND_TUI=false
FOUND_DATA=false
FOUND_SKILLS=false
FOUND_SYSTEMD=false
FOUND_OLLAMA=false
FOUND_OLLAMA_OVERRIDE=false

detect_installation() {
    section "Detecting Installation"

    # Check binaries
    if [ -f "${BIN_DIR}/hecate" ]; then
        FOUND_DAEMON=true
        echo -e "  ${GREEN}✓${NC} Daemon:    ${BIN_DIR}/hecate"
    else
        echo -e "  ${DIM}✗ Daemon:    not found${NC}"
    fi

    if [ -f "${BIN_DIR}/hecate-tui" ]; then
        FOUND_TUI=true
        echo -e "  ${GREEN}✓${NC} TUI:       ${BIN_DIR}/hecate-tui"
    else
        echo -e "  ${DIM}✗ TUI:       not found${NC}"
    fi

    # Check data directory
    if [ -d "${INSTALL_DIR}" ]; then
        FOUND_DATA=true
        local size
        size=$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1 || echo "unknown")
        echo -e "  ${GREEN}✓${NC} Data:      ${INSTALL_DIR} (${size})"
    else
        echo -e "  ${DIM}✗ Data:      not found${NC}"
    fi

    # Check Claude skills
    if [ -f "$HOME/.claude/HECATE_SKILLS.md" ]; then
        FOUND_SKILLS=true
        echo -e "  ${GREEN}✓${NC} Skills:    ~/.claude/HECATE_SKILLS.md"
    else
        echo -e "  ${DIM}✗ Skills:    not found${NC}"
    fi

    # Check systemd service
    if [ -f "/etc/systemd/system/hecate.service" ]; then
        FOUND_SYSTEMD=true
        local status="inactive"
        if command_exists systemctl && systemctl is-active --quiet hecate 2>/dev/null; then
            status="running"
        fi
        echo -e "  ${GREEN}✓${NC} Service:   hecate.service (${status})"
    else
        echo -e "  ${DIM}✗ Service:   not found${NC}"
    fi

    # Check Ollama network override (created by installer)
    if [ -f "/etc/systemd/system/ollama.service.d/network.conf" ]; then
        FOUND_OLLAMA_OVERRIDE=true
        echo -e "  ${GREEN}✓${NC} Ollama:    network config override"
    fi

    # Check Ollama
    if command_exists ollama; then
        FOUND_OLLAMA=true
        echo -e "  ${YELLOW}?${NC} Ollama:    installed (separate application)"
    fi

    echo ""

    # Nothing found?
    if [ "$FOUND_DAEMON" = false ] && [ "$FOUND_TUI" = false ] && \
       [ "$FOUND_DATA" = false ] && [ "$FOUND_SKILLS" = false ] && \
       [ "$FOUND_SYSTEMD" = false ]; then
        warn "No Hecate installation found"
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# Uninstall Components
# -----------------------------------------------------------------------------

stop_services() {
    # Stop systemd service
    if [ "$FOUND_SYSTEMD" = true ]; then
        if command_exists systemctl && systemctl is-active --quiet hecate 2>/dev/null; then
            info "Stopping Hecate service..."
            sudo systemctl stop hecate
            ok "Service stopped"
        fi
    fi

    # Stop daemon process if running
    if pgrep -x "hecate" > /dev/null 2>&1; then
        info "Stopping Hecate daemon..."
        if [ -f "${BIN_DIR}/hecate" ]; then
            "${BIN_DIR}/hecate" stop 2>/dev/null || true
        fi
        sleep 1
        # Force kill if still running
        if pgrep -x "hecate" > /dev/null 2>&1; then
            pkill -x "hecate" 2>/dev/null || true
        fi
        ok "Daemon stopped"
    fi
}

remove_systemd() {
    if [ "$FOUND_SYSTEMD" = true ]; then
        section "Removing Systemd Service"

        echo "The following will be removed:"
        echo -e "  ${DIM}/etc/systemd/system/hecate.service${NC}"
        echo ""
        echo -e "${YELLOW}Requires sudo${NC}"
        echo ""

        if confirm "Remove systemd service?"; then
            sudo systemctl disable hecate 2>/dev/null || true
            sudo rm -f /etc/systemd/system/hecate.service
            sudo systemctl daemon-reload
            ok "Systemd service removed"
        else
            warn "Keeping systemd service"
        fi
    fi

    # Remove Ollama network override if we created it
    if [ "$FOUND_OLLAMA_OVERRIDE" = true ]; then
        echo ""
        echo "Found Ollama network configuration (created by Hecate installer):"
        echo -e "  ${DIM}/etc/systemd/system/ollama.service.d/network.conf${NC}"
        echo ""

        if confirm "Remove Ollama network override?"; then
            sudo rm -f /etc/systemd/system/ollama.service.d/network.conf
            sudo rmdir /etc/systemd/system/ollama.service.d 2>/dev/null || true
            sudo systemctl daemon-reload
            if command_exists systemctl && systemctl is-active --quiet ollama 2>/dev/null; then
                info "Restarting Ollama to apply changes..."
                sudo systemctl restart ollama
            fi
            ok "Ollama network override removed"
        else
            warn "Keeping Ollama network override"
        fi
    fi
}

remove_binaries() {
    if [ "$FOUND_DAEMON" = true ] || [ "$FOUND_TUI" = true ]; then
        section "Removing Binaries"

        if [ "$FOUND_DAEMON" = true ]; then
            rm -f "${BIN_DIR}/hecate"
            ok "Removed ${BIN_DIR}/hecate"
        fi

        if [ "$FOUND_TUI" = true ]; then
            rm -f "${BIN_DIR}/hecate-tui"
            ok "Removed ${BIN_DIR}/hecate-tui"
        fi
    fi
}

remove_skills() {
    if [ "$FOUND_SKILLS" = true ]; then
        section "Removing Claude Skills"

        rm -f "$HOME/.claude/HECATE_SKILLS.md"
        ok "Removed ~/.claude/HECATE_SKILLS.md"

        # Remove reference from CLAUDE.md if present
        if [ -f "$HOME/.claude/CLAUDE.md" ]; then
            if grep -q "HECATE_SKILLS.md" "$HOME/.claude/CLAUDE.md"; then
                info "Cleaning up ~/.claude/CLAUDE.md..."
                # Create temp file without Hecate section
                grep -v "HECATE_SKILLS.md" "$HOME/.claude/CLAUDE.md" | \
                    grep -v "## Hecate Skills" > "$HOME/.claude/CLAUDE.md.tmp" || true
                mv "$HOME/.claude/CLAUDE.md.tmp" "$HOME/.claude/CLAUDE.md"
                ok "Removed Hecate reference from CLAUDE.md"
            fi
        fi
    fi
}

remove_data() {
    if [ "$FOUND_DATA" = true ]; then
        section "Data Directory"

        echo "Contents of ${INSTALL_DIR}:"
        ls -la "${INSTALL_DIR}" 2>/dev/null | head -10 || true
        echo ""

        echo -e "${YELLOW}Warning:${NC} This will permanently delete:"
        echo -e "  • Configuration files"
        echo -e "  • Logs"
        echo -e "  • Local data and state"
        echo ""

        if confirm "Delete data directory? ${RED}(cannot be undone)${NC}"; then
            rm -rf "${INSTALL_DIR}"
            ok "Removed ${INSTALL_DIR}"
        else
            warn "Keeping data directory"
            echo ""
            echo "To remove later:"
            echo -e "  ${CYAN}rm -rf ${INSTALL_DIR}${NC}"
        fi
    fi
}

offer_ollama_info() {
    if [ "$FOUND_OLLAMA" = true ]; then
        section "About Ollama"

        echo "Ollama is installed but is a ${BOLD}separate application${NC}."
        echo "It may be used by other tools on this system."
        echo ""
        echo "Hecate does not uninstall Ollama automatically."
        echo ""

        if confirm "Show Ollama uninstall instructions?"; then
            echo ""
            echo -e "${BOLD}To uninstall Ollama:${NC}"
            echo ""
            echo "  1. Stop the service:"
            echo -e "     ${CYAN}sudo systemctl stop ollama${NC}"
            echo ""
            echo "  2. Disable auto-start:"
            echo -e "     ${CYAN}sudo systemctl disable ollama${NC}"
            echo ""
            echo "  3. Remove the binary:"
            echo -e "     ${CYAN}sudo rm /usr/local/bin/ollama${NC}"
            echo ""
            echo "  4. Remove the service file:"
            echo -e "     ${CYAN}sudo rm /etc/systemd/system/ollama.service${NC}"
            echo -e "     ${CYAN}sudo systemctl daemon-reload${NC}"
            echo ""
            echo "  5. Remove models and data (~/.ollama):"
            echo -e "     ${CYAN}rm -rf ~/.ollama${NC}"
            echo ""
            echo "  6. (Optional) Remove the ollama user:"
            echo -e "     ${CYAN}sudo userdel ollama${NC}"
            echo -e "     ${CYAN}sudo groupdel ollama${NC}"
            echo ""
        fi
    fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

show_summary() {
    section "Uninstall Complete"

    echo -e "${GREEN}${BOLD}Hecate has been uninstalled.${NC}"
    echo ""

    # Check what was kept
    local kept=()
    [ -d "${INSTALL_DIR}" ] && kept+=("Data directory: ${INSTALL_DIR}")
    [ -f "/etc/systemd/system/hecate.service" ] && kept+=("Systemd service")
    [ "$FOUND_OLLAMA" = true ] && kept+=("Ollama (separate application)")

    if [ ${#kept[@]} -gt 0 ]; then
        echo "Components kept:"
        for item in "${kept[@]}"; do
            echo -e "  ${DIM}• ${item}${NC}"
        done
        echo ""
    fi

    echo "To reinstall Hecate:"
    echo -e "  ${CYAN}curl -fsSL https://macula.io/hecate/install.sh | bash${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    show_banner
    detect_installation

    echo "This will uninstall Hecate from your system."
    echo ""

    if ! confirm "Continue with uninstall?"; then
        echo "Uninstall cancelled."
        exit 0
    fi

    stop_services
    remove_systemd
    remove_binaries
    remove_skills
    remove_data
    offer_ollama_info
    show_summary
}

main "$@"
