#!/usr/bin/env bash
#
# Hecate Node Installer
# Usage: curl -fsSL https://macula.io/hecate/install.sh | bash
#
# Installs:
#   - hecate-daemon via Docker Compose (+ Watchtower for auto-updates)
#   - hecate-tui native binary
#   - Claude Code skills
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

HECATE_VERSION="${HECATE_VERSION:-latest}"
INSTALL_DIR="${HECATE_INSTALL_DIR:-$HOME/.hecate}"
BIN_DIR="${HECATE_BIN_DIR:-$HOME/.local/bin}"
REPO_BASE="https://github.com/hecate-social"
RAW_BASE="https://macula.io/hecate"

# Docker image (GitHub Container Registry)
HECATE_IMAGE="ghcr.io/hecate-social/hecate-daemon:main"

# Flags
HEADLESS=false
PAIRING_SUCCESS=false

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

# Hecate avatar art (base64-encoded, generated from avatar.jpg using chafa)
HECATE_AVATAR_B64="G1swbRtbMzg7NTsxNjs0ODs1OzE2bSAbWzM4OzU7MjMybV8bWzQ4OzU7MjMybSAgIBtbMzg7NTsyMzNtXxtbNDg7NTsyMzNtICAgG1szODs1OzIzNzs0ODs1OzIzNG15G1szODs1OzhteRtbMzg7NTsyMzY7NDg7NTsyMzNtXyAgG1szODs1OzIzMzs0ODs1OzIzMm1fXyAgG1s0ODs1OzE2bSAgG1swbQobWzM4OzU7MjMyOzQ4OzU7MjMybSAgG1s0ODs1OzIzM21gG1szODs1OzE3Mjs0ODs1OzU4bV8bWzM4OzU7MjMzOzQ4OzU7MjM0bWAbWzQ4OzU7MjMzbSAgIBtbMzg7NTsyMzk7NDg7NTsyMzZtLxtbMzg7NTsyMzNteRtbNDg7NTsyMzVteRtbMzg7NTs4OzQ4OzU7MjM2bVIbWzM4OzU7MjMzOzQ4OzU7MjM0bWAbWzQ4OzU7MjMzbSAgIBtbMzg7NTsxMzA7NDg7NTsyMzVtZxtbMzg7NTsyMzM7NDg7NTsyMzJtXyAbWzM4OzU7MjMyOzQ4OzU7MTZtXxtbMG0KG1szODs1OzIzMjs0ODs1OzIzMm0gG1s0ODs1OzIzM20gG1szODs1OzIzMzs0ODs1OzIzNW0nG1szODs1OzEzNzs0ODs1OzE3OW1IG1szODs1OzIzMzs0ODs1OzIzNW1gG1s0ODs1OzIzNG0gIBtbMzg7NTsyMzdtLBtbMzg7NTsyMzY7NDg7NTsyMzNtfhtbMzg7NTsyMzltYBtbMzg7NTsyMzU7NDg7NTsyMzRtIhtbMzg7NTsyMzg7NDg7NTsyMzNtYBtbMzg7NTsyMzc7NDg7NTsyMzVtaRtbNDg7NTsyMzRtICAbWzM4OzU7MjMzOzQ4OzU7MjM2bWAbWzM4OzU7MTY2OzQ4OzU7MTc5bX4bWzM4OzU7MjMzOzQ4OzU7MjM0bWAbWzQ4OzU7MjMybUwgG1swbQobWzM4OzU7MjMyOzQ4OzU7MjMybSAbWzM4OzU7MjMzbX4bWzQ4OzU7MjM0bScbWzM4OzU7MTczOzQ4OzU7MjM3bX4bWzQ4OzU7MjM0bSAgG1szODs1OzIzNjs0ODs1OzIzNW14G1szODs1OzIzNTs0ODs1OzIzNG1+G1s0ODs1OzIzMm0gG1szODs1OzE2bWAbWzM4OzU7MjM5bV8bWzQ4OzU7MTZtIBtbMzg7NTsyMzI7NDg7NTsyMzVtOhtbMzg7NTsxNDQ7NDg7NTsyMzdtXxtbNDg7NTsyMzRtICAbWzM4OzU7MTczOzQ4OzU7NThtfhtbMzg7NTsyMzI7NDg7NTsyMzRtLhtbNDg7NTsyMzJtICAbWzBtChtbMzg7NTsyMzI7NDg7NTsyMzJtICAbWzM4OzU7MjMzbX4gG1s0ODs1OzIzM20gG1s0ODs1OzIzNG06G1s0ODs1OzIzNW06G1szODs1OzIzNDs0ODs1OzIzNm1fG1szODs1OzIzODs0ODs1OzIzM209G1szODs1OzhtYBtbMzg7NTsyNDBtYCAbWzM4OzU7MjM5OzQ4OzU7MjM3bTQbWzM4OzU7MTAxOzQ4OzU7MjM5bX4bWzM4OzU7MjM5OzQ4OzU7MjM2bUwbWzQ4OzU7MjMzbSAbWzM4OzU7MjMzOzQ4OzU7MjMybVtgICAbWzBtChtbMzg7NTsxNjs0ODs1OzIzMm1MIBtbMzg7NTsyMzNtNBtbMzg7NTsyMzI7NDg7NTsyMzNtWyAbWzQ4OzU7MjM0bSAbWzM4OzU7MjM0OzQ4OzU7MjMybX4bWzM4OzU7MjMzOzQ4OzU7MTZtYBtbMzg7NTsxNjs0ODs1OzIzMm1gG1s0ODs1OzIzM20gG1szODs1OzIzMm06G1szODs1OzIzMzs0ODs1OzIzMm1+G1s0ODs1OzIzM20gG1szODs1OzIzNW0iG1szODs1OzIzNjs0ODs1OzIzNG0iG1s0ODs1OzIzM20gG1szODs1OzIzMm1qeRtbNDg7NTsyMzJtIBtbNDg7NTsxNm1GG1swbQobWzM4OzU7MTY7NDg7NTsxNm0gG1s0ODs1OzIzMm0gIEkbWzQ4OzU7MjMzbSAbWzM4OzU7MjMzOzQ4OzU7MjMybT8bWzQ4OzU7MTZtICAgG1s0ODs1OzIzM20gG1szODs1OzE2bTobWzQ4OzU7MjMybSAgG1szODs1OzIzM21bIBtbMzg7NTsyMzI7NDg7NTsyMzNtdxtbNDg7NTsyMzJtICAgG1s0ODs1OzE2bSAbWzBtChtbMzg7NTsxNjs0ODs1OzE2bSAbWzQ4OzU7MjMybSAgSRtbMzg7NTsyMzNtYCAbWzQ4OzU7MTZtICAgG1szODs1OzIzNDs0ODs1OzIzM21gG1szODs1OzIzN20uG1s0ODs1OzIzMm0gICAbWzM4OzU7MjMzbWBgG1szODs1OzE2bV0gIBtbNDg7NTsxNm0gG1swbQobWzM4OzU7MTY7NDg7NTsxNm0gG1szODs1OzIzMm1gG1s0ODs1OzIzMm0gG1szODs1OzE2bTF5G1s0ODs1OzE2bSAgICAgG1szODs1OzIzNDs0ODs1OzIzMm0nG1s0ODs1OzE2bSAgG1szODs1OzIzMm0iIBtbMzg7NTsxNjs0ODs1OzIzMm1fJHkbWzQ4OzU7MTZtICAbWzBtChtbN20bWzM4OzU7MTZtIBtbMG0bWzM4OzU7MTs0ODs1OzE2bSAgICAgICAgIBtbMzg7NTsyMzM7NDg7NTsyMzJtYBtbMzg7NTsyMzI7NDg7NTsxNm1MICAgICAgICAbWzBtCg=="

show_banner() {
    # Show colored avatar if terminal supports it
    if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
        echo ""
        echo "$HECATE_AVATAR_B64" | base64 -d 2>/dev/null || true
        echo ""
        echo -e "${MAGENTA}${BOLD}    H E C A T E${NC}"
        echo -e "${DIM}    Goddess of crossroads. Keeper of keys.${NC}"
        echo ""
    else
        # Fallback for non-color terminals
        echo ""
        echo "    🗝️  H E C A T E  🗝️"
        echo ""
        echo "    Hecate Node Installer"
        echo "    Mesh networking for AI agents"
        echo ""
    fi
}

# -----------------------------------------------------------------------------
# Docker Installation
# -----------------------------------------------------------------------------

check_docker() {
    section "Checking Docker"

    if command_exists docker; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null | head -1)
        ok "Docker installed: ${docker_version}"

        # Check if docker compose v2 is available
        if docker compose version &>/dev/null; then
            local compose_version
            compose_version=$(docker compose version --short 2>/dev/null)
            ok "Docker Compose v2: ${compose_version}"
        else
            warn "Docker Compose v2 not found"
            return 1
        fi

        # Check if user can run docker without sudo
        if docker ps &>/dev/null; then
            ok "Docker accessible without sudo"
            return 0
        else
            warn "Docker requires sudo - need to add user to docker group"
            return 1
        fi
    else
        warn "Docker not installed"
        return 1
    fi
}

install_docker() {
    section "Installing Docker"

    echo "Docker is required to run hecate-daemon."
    echo ""
    echo "This will run Docker's official install script:"
    echo -e "  ${DIM}curl -fsSL https://get.docker.com | sh${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}Requires sudo access${NC} to:"
    echo "  • Install Docker Engine and Docker Compose"
    echo "  • Add your user to the 'docker' group"
    echo ""

    if ! confirm "Install Docker?"; then
        fatal "Docker is required. Install manually: https://docs.docker.com/get-docker/"
    fi

    info "Running Docker install script..."
    curl -fsSL https://get.docker.com | sh

    if ! command_exists docker; then
        fatal "Docker installation failed"
    fi

    ok "Docker installed"

    # Add user to docker group
    info "Adding ${USER} to docker group..."
    sudo usermod -aG docker "${USER}"
    ok "User added to docker group"

    echo ""
    echo -e "${YELLOW}${BOLD}Important:${NC} You need to log out and back in for group changes to take effect."
    echo ""
    echo "Or run this command to apply immediately (for this session):"
    echo -e "  ${CYAN}newgrp docker${NC}"
    echo ""

    # Try newgrp for current session
    if confirm "Apply docker group now (runs 'newgrp docker')?"; then
        echo ""
        echo "After the shell opens, re-run the installer:"
        echo -e "  ${CYAN}curl -fsSL https://macula.io/hecate/install.sh | bash${NC}"
        echo ""
        exec newgrp docker
    fi
}

ensure_docker() {
    if ! check_docker; then
        install_docker
        # Re-check after install
        if ! check_docker; then
            fatal "Docker setup incomplete. Please log out/in and run installer again."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Hecate Daemon Setup (Docker Compose)
# -----------------------------------------------------------------------------

setup_daemon() {
    section "Setting up Hecate Daemon"

    mkdir -p "${INSTALL_DIR}"/{data,config}

    local local_ip
    local_ip=$(get_local_ip)

    # Create docker-compose.yml
    cat > "${INSTALL_DIR}/docker-compose.yml" << EOF
# Hecate Daemon - Docker Compose Configuration
# Generated by hecate installer

services:
  hecate:
    image: ${HECATE_IMAGE}
    container_name: hecate-daemon
    restart: unless-stopped
    ports:
      - "4444:4444"      # REST API
      - "4433:4433/udp"  # QUIC mesh
    volumes:
      - ./data:/data
      - ./config:/app/config:ro
    environment:
      - HECATE_API_HOST=0.0.0.0
      - HECATE_API_PORT=4444
      - HECATE_BOOTSTRAP=boot.macula.io:443
      - HECATE_REALM=io.macula
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4444/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

  watchtower:
    image: containrrr/watchtower
    container_name: hecate-watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=3600  # Check every hour
      - WATCHTOWER_INCLUDE_STOPPED=true
    command: hecate-daemon  # Only watch hecate container
EOF

    # Create default config
    cat > "${INSTALL_DIR}/config/hecate.toml" << EOF
# Hecate Node Configuration
# See: https://github.com/hecate-social/hecate-node

[mesh]
bootstrap = ["boot.macula.io:443"]
realm = "io.macula"

[logging]
level = "info"
EOF

    ok "Docker Compose configuration created"
    info "Location: ${INSTALL_DIR}/docker-compose.yml"
}

# -----------------------------------------------------------------------------
# Hecate TUI Installation (Native Binary)
# -----------------------------------------------------------------------------

install_tui() {
    section "Installing Hecate TUI"

    local os arch version url
    os=$(detect_os)
    arch=$(detect_arch)

    version=$(get_latest_release "hecate-tui")
    if [ -z "$version" ]; then
        warn "Could not fetch latest version, using v0.1.0"
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

    ok "Hecate TUI ${version} installed to ${BIN_DIR}/hecate-tui"
}

# -----------------------------------------------------------------------------
# Hecate CLI Wrapper
# -----------------------------------------------------------------------------

install_cli_wrapper() {
    section "Installing CLI Wrapper"

    mkdir -p "$BIN_DIR"

    cat > "${BIN_DIR}/hecate" << 'WRAPPER'
#!/usr/bin/env bash
# Hecate CLI wrapper - manages hecate-daemon via Docker Compose
set -euo pipefail

HECATE_DIR="${HECATE_DIR:-$HOME/.hecate}"
COMPOSE_FILE="${HECATE_DIR}/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: Hecate not installed. Run the installer:"
    echo "  curl -fsSL https://macula.io/hecate/install.sh | bash"
    exit 1
fi

cd "$HECATE_DIR"

case "${1:-help}" in
    start)
        echo "Starting Hecate daemon..."
        docker compose up -d
        echo "Hecate is running. API: http://localhost:4444"
        ;;
    stop)
        echo "Stopping Hecate daemon..."
        docker compose down
        ;;
    restart)
        echo "Restarting Hecate daemon..."
        docker compose restart
        ;;
    status)
        docker compose ps
        ;;
    logs)
        docker compose logs -f "${@:2}"
        ;;
    update)
        echo "Updating Hecate..."
        docker compose pull
        docker compose up -d
        ;;
    config)
        echo "Configuration directory: ${HECATE_DIR}"
        echo "Docker Compose file: ${COMPOSE_FILE}"
        echo ""
        echo "Edit configuration:"
        echo "  ${HECATE_DIR}/config/hecate.toml"
        ;;
    health)
        curl -s http://localhost:4444/health | jq . 2>/dev/null || curl -s http://localhost:4444/health
        ;;
    identity)
        curl -s http://localhost:4444/api/identity | jq . 2>/dev/null || curl -s http://localhost:4444/api/identity
        ;;
    pair)
        echo "Starting pairing..."
        result=$(curl -s -X POST http://localhost:4444/api/pairing/start)
        
        if echo "$result" | grep -q '"ok":false'; then
            echo "Pairing failed:"
            echo "$result" | jq . 2>/dev/null || echo "$result"
            exit 1
        fi
        
        code=$(echo "$result" | jq -r '.confirm_code')
        url=$(echo "$result" | jq -r '.pairing_url')
        
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Confirmation code:  $code"
        echo ""
        echo "  Open this URL to confirm:"
        echo "  $url"
        echo ""
        
        # Generate QR code if qrencode is available
        if command -v qrencode &>/dev/null; then
            echo "  Or scan this QR code:"
            echo ""
            qrencode -t ANSIUTF8 -m 2 "$url"
        fi
        
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Waiting for confirmation..."
        
        while true; do
            status_result=$(curl -s http://localhost:4444/api/pairing/status)
            status=$(echo "$status_result" | jq -r '.status')
            
            case "$status" in
                paired)
                    echo ""
                    echo "✓ Paired successfully!"
                    echo ""
                    curl -s http://localhost:4444/api/identity | jq . 2>/dev/null
                    exit 0
                    ;;
                failed|expired)
                    echo ""
                    echo "✗ Pairing failed or expired"
                    exit 1
                    ;;
                *)
                    # Still waiting
                    printf "."
                    sleep 2
                    ;;
            esac
        done
        ;;
    *)
        echo "Hecate - Mesh networking for AI agents"
        echo ""
        echo "Usage: hecate <command>"
        echo ""
        echo "Commands:"
        echo "  start     Start the daemon"
        echo "  stop      Stop the daemon"
        echo "  restart   Restart the daemon"
        echo "  status    Show daemon status"
        echo "  logs      Show daemon logs (follows)"
        echo "  update    Pull latest image and restart"
        echo "  config    Show configuration paths"
        echo "  health    Check daemon health"
        echo "  identity  Show identity and pairing status"
        echo "  pair      Start pairing flow"
        echo ""
        echo "TUI:"
        echo "  hecate-tui    Launch terminal UI"
        ;;
esac
WRAPPER

    chmod +x "${BIN_DIR}/hecate"

    ok "CLI wrapper installed to ${BIN_DIR}/hecate"
}

# -----------------------------------------------------------------------------
# Claude Skills Installation
# -----------------------------------------------------------------------------

install_skills() {
    section "Installing Claude Code Skills"

    local claude_dir="$HOME/.claude"
    mkdir -p "$claude_dir"

    download_file "${RAW_BASE}/SKILLS.md" "${claude_dir}/HECATE_SKILLS.md"

    if [ -f "${claude_dir}/CLAUDE.md" ]; then
        if ! grep -q "HECATE_SKILLS.md" "${claude_dir}/CLAUDE.md"; then
            echo "" >> "${claude_dir}/CLAUDE.md"
            echo "## Hecate Skills" >> "${claude_dir}/CLAUDE.md"
            echo "" >> "${claude_dir}/CLAUDE.md"
            echo "See [HECATE_SKILLS.md](HECATE_SKILLS.md) for Hecate mesh integration skills." >> "${claude_dir}/CLAUDE.md"
        fi
    fi

    ok "Hecate Skills installed to ~/.claude/"
}

# -----------------------------------------------------------------------------
# Start Daemon
# -----------------------------------------------------------------------------

start_daemon() {
    section "Starting Hecate Daemon"

    cd "${INSTALL_DIR}"
    
    info "Pulling latest image..."
    docker compose pull --quiet
    
    info "Starting containers..."
    docker compose up -d
    
    # Wait for health check
    info "Waiting for daemon to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -s http://localhost:4444/health &>/dev/null; then
            ok "Daemon is running and healthy"
            return 0
        fi
        retries=$((retries - 1))
        sleep 1
    done
    
    fatal "Daemon failed to start. Check logs with: hecate logs"
}

# -----------------------------------------------------------------------------
# Pairing Flow
# -----------------------------------------------------------------------------

run_pairing() {
    section "Pairing with Realm"

    info "Starting pairing session..."
    local result
    result=$(curl -s -X POST http://localhost:4444/api/pairing/start)
    
    if echo "$result" | grep -q '"ok":false'; then
        error "Failed to start pairing:"
        echo "$result" | jq . 2>/dev/null || echo "$result"
        echo ""
        warn "You can pair later with: hecate pair"
        return 1
    fi
    
    local code url
    code=$(echo "$result" | jq -r '.confirm_code')
    url=$(echo "$result" | jq -r '.pairing_url')
    
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Confirmation code:  ${BOLD}${code}${NC}"
    echo ""
    echo -e "  Open this URL to confirm:"
    echo -e "  ${CYAN}${url}${NC}"
    echo ""
    
    # Generate QR code if qrencode is available
    if command -v qrencode &>/dev/null; then
        echo "  Or scan this QR code:"
        echo ""
        qrencode -t ANSIUTF8 -m 2 "$url"
        echo ""
    fi
    
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${DIM}Waiting for confirmation (timeout: 10 minutes)...${NC}"
    
    local timeout=600
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        local status_result status
        status_result=$(curl -s http://localhost:4444/api/pairing/status)
        status=$(echo "$status_result" | jq -r '.status')
        
        case "$status" in
            paired)
                echo ""
                ok "Paired successfully!"
                return 0
                ;;
            failed)
                echo ""
                error "Pairing failed"
                warn "You can try again with: hecate pair"
                return 1
                ;;
            idle)
                echo ""
                warn "Pairing session expired"
                warn "You can try again with: hecate pair"
                return 1
                ;;
            *)
                # Still waiting
                printf "."
                sleep 2
                elapsed=$((elapsed + 2))
                ;;
        esac
    done
    
    echo ""
    warn "Pairing timed out"
    warn "You can try again with: hecate pair"
    return 1
}

# -----------------------------------------------------------------------------
# PATH Setup
# -----------------------------------------------------------------------------

setup_path() {
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        echo ""
        warn "$BIN_DIR is not in PATH"
        echo ""
        echo "Add this to your shell profile (~/.bashrc, ~/.zshrc):"
        echo ""
        echo -e "  ${BOLD}export PATH=\"\$PATH:$BIN_DIR\"${NC}"
        echo ""
    else
        ok "$BIN_DIR is in PATH"
    fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

show_summary() {
    section "🔥🗝️🔥 Installation Complete"

    local local_ip
    local_ip=$(get_local_ip)

    echo -e "${GREEN}${BOLD}The goddess has arrived.${NC}"
    echo ""
    
    # Show pairing status
    if [ "${PAIRING_SUCCESS:-false}" = true ]; then
        echo -e "${GREEN}✓${NC} Daemon running and ${GREEN}paired${NC}"
        echo ""
        # Show identity
        local identity
        identity=$(curl -s http://localhost:4444/api/identity 2>/dev/null)
        if [ -n "$identity" ]; then
            local mri org_identity
            mri=$(echo "$identity" | jq -r '.mri // empty')
            org_identity=$(echo "$identity" | jq -r '.org_identity // empty')
            if [ -n "$mri" ]; then
                echo -e "  Identity: ${BOLD}${mri}${NC}"
            fi
            if [ -n "$org_identity" ]; then
                echo -e "  Org:      ${BOLD}${org_identity}${NC}"
            fi
            echo ""
        fi
    else
        echo -e "${YELLOW}!${NC} Daemon running but ${YELLOW}not paired${NC}"
        echo ""
        echo "  Pair with the mesh:"
        echo -e "     ${CYAN}hecate pair${NC}"
        echo ""
    fi
    
    echo "Installed:"
    echo -e "  ${BOLD}hecate${NC}       - CLI wrapper    ${DIM}${BIN_DIR}/hecate${NC}"
    echo -e "  ${BOLD}hecate-tui${NC}   - Terminal UI    ${DIM}${BIN_DIR}/hecate-tui${NC}"
    echo -e "  ${BOLD}daemon${NC}       - Docker Compose ${DIM}${INSTALL_DIR}/docker-compose.yml${NC}"
    echo -e "  ${BOLD}skills${NC}       - Claude Code    ${DIM}~/.claude/HECATE_SKILLS.md${NC}"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo ""
    echo -e "  ${CYAN}hecate status${NC}    - Check daemon status"
    echo -e "  ${CYAN}hecate logs${NC}      - View daemon logs"
    echo -e "  ${CYAN}hecate identity${NC}  - Show identity"
    echo -e "  ${CYAN}hecate-tui${NC}       - Launch terminal UI"
    echo ""
    echo "API endpoint: http://localhost:4444"
    echo "Network endpoint: http://${local_ip}:4444"
    echo ""
    echo -e "${DIM}Auto-updates enabled via Watchtower (checks hourly)${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

show_help() {
    echo "Hecate Node Installer"
    echo ""
    echo "Usage: curl -fsSL https://macula.io/hecate/install.sh | bash"
    echo ""
    echo "Options:"
    echo "  --headless   Non-interactive mode"
    echo "  --help       Show this help"
    echo ""
    echo "Prerequisites:"
    echo "  - Docker (will be installed if missing)"
    echo ""
    echo "What gets installed:"
    echo "  - hecate-daemon via Docker Compose"
    echo "  - hecate-tui native binary (Go, static)"
    echo "  - Watchtower for auto-updates"
    echo "  - Claude Code skills"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --headless) HEADLESS=true ;;
            --help|-h) show_help; exit 0 ;;
        esac
    done

    show_banner

    echo "This installer will set up:"
    echo "  • Docker (if not installed)"
    echo "  • Hecate daemon (via Docker Compose)"
    echo "  • Hecate TUI (native binary)"
    echo "  • Watchtower (auto-updates)"
    echo "  • Claude Code skills"
    echo ""

    if ! confirm "Continue with installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi

    ensure_docker
    setup_daemon
    install_tui
    install_cli_wrapper
    install_skills
    setup_path
    start_daemon
    
    # Run pairing (optional - don't fail install if pairing fails)
    if run_pairing; then
        PAIRING_SUCCESS=true
    else
        PAIRING_SUCCESS=false
    fi
    
    show_summary
}

main "$@"
