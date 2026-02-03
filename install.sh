#!/usr/bin/env bash
#
# Hecate Node Installer
# Usage: curl -fsSL https://hecate.social/install.sh | bash
#
# Options:
#   --role=ROLE    Set node role (workstation|services|ai|full)
#   --no-ai        Skip AI model setup
#   --headless     Non-interactive mode (use defaults)
#   --help         Show help
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

HECATE_VERSION="${HECATE_VERSION:-latest}"
INSTALL_DIR="${HECATE_INSTALL_DIR:-$HOME/.hecate}"
BIN_DIR="${HECATE_BIN_DIR:-$HOME/.local/bin}"
REPO_BASE="https://github.com/hecate-social"
RAW_BASE="https://raw.githubusercontent.com/hecate-social/hecate-node/main"

# Flags
SKIP_AI=false
HEADLESS=false
PRESET_ROLE=""

# Node roles (can combine multiple)
ROLE_WORKSTATION=false
ROLE_SERVICES=false
ROLE_AI=false

# Colors (disabled if not a terminal)
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

# Get local IP address for LAN
get_local_ip() {
    local os
    os=$(detect_os)
    if [ "$os" = "linux" ]; then
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown"
    elif [ "$os" = "darwin" ]; then
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Prompt for yes/no
confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [ "$HEADLESS" = true ]; then
        [ "$default" = "y" ]
        return
    fi

    local yn_hint="[y/N]"
    [ "$default" = "y" ] && yn_hint="[Y/n]"

    echo -en "${CYAN}?${NC} ${prompt} ${yn_hint} "
    read -r response
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy] ]]
}

# Prompt for text input
prompt_input() {
    local prompt="$1"
    local default="${2:-}"

    if [ "$HEADLESS" = true ]; then
        echo "$default"
        return
    fi

    if [ -n "$default" ]; then
        echo -en "${CYAN}?${NC} ${prompt} [${default}]: "
    else
        echo -en "${CYAN}?${NC} ${prompt}: "
    fi
    read -r response
    echo "${response:-$default}"
}

# Prompt for selection from list
select_option() {
    local prompt="$1"
    shift
    local options=("$@")

    if [ "$HEADLESS" = true ]; then
        echo "1"
        return
    fi

    echo -e "${CYAN}?${NC} ${prompt}"
    echo ""
    local i=1
    for opt in "${options[@]}"; do
        echo -e "  ${BOLD}${i})${NC} ${opt}"
        ((i++))
    done
    echo ""
    echo -en "  Enter choice [1-${#options[@]}]: "
    read -r choice
    choice="${choice:-1}"
    echo "$choice"
}

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
    __  __              __
   / / / /__  _______ _/ /____
  / /_/ / _ \/ __/ _ `/ __/ -_)
 /_//_/\___/\__/\_,_/\__/\__/

EOF
    echo -e "${NC}"
    echo -e "${BOLD}Hecate Node Installer${NC}"
    echo -e "${DIM}Mesh networking for AI agents${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Hardware Detection
# -----------------------------------------------------------------------------

DETECTED_RAM_GB=0
DETECTED_CPU_CORES=0
DETECTED_HAS_AVX2=false
DETECTED_HAS_GPU=false
DETECTED_GPU_TYPE=""
DETECTED_LOCAL_IP=""

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

    # Detect AVX2 support (important for llama.cpp performance)
    if [ "$os" = "linux" ]; then
        if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
            DETECTED_HAS_AVX2=true
        fi
    elif [ "$os" = "darwin" ]; then
        if sysctl -n machdep.cpu.features 2>/dev/null | grep -qi avx2; then
            DETECTED_HAS_AVX2=true
        fi
    fi

    # Detect GPU (NVIDIA or Apple Silicon)
    if [ "$os" = "linux" ]; then
        if command_exists nvidia-smi && nvidia-smi &>/dev/null; then
            DETECTED_HAS_GPU=true
            DETECTED_GPU_TYPE="nvidia"
        elif [ -d /sys/class/drm ] && ls /sys/class/drm/card*/device/vendor 2>/dev/null | xargs grep -l 0x1002 &>/dev/null; then
            DETECTED_HAS_GPU=true
            DETECTED_GPU_TYPE="amd"
        fi
    elif [ "$os" = "darwin" ]; then
        # Apple Silicon has integrated GPU
        if [ "$(detect_arch)" = "arm64" ]; then
            DETECTED_HAS_GPU=true
            DETECTED_GPU_TYPE="apple"
        fi
    fi

    # Get local IP
    DETECTED_LOCAL_IP=$(get_local_ip)

    # Display results
    echo -e "  ${BOLD}RAM:${NC}        ${DETECTED_RAM_GB} GB"
    echo -e "  ${BOLD}CPU Cores:${NC}  ${DETECTED_CPU_CORES}"
    echo -e "  ${BOLD}AVX2:${NC}       $([ "$DETECTED_HAS_AVX2" = true ] && echo "Yes" || echo "No")"
    if [ "$DETECTED_HAS_GPU" = true ]; then
        echo -e "  ${BOLD}GPU:${NC}        ${DETECTED_GPU_TYPE}"
    else
        echo -e "  ${BOLD}GPU:${NC}        None detected"
    fi
    echo -e "  ${BOLD}Local IP:${NC}   ${DETECTED_LOCAL_IP}"
    echo ""

    # Suggest best role based on hardware
    suggest_role
}

suggest_role() {
    local suggestion=""
    local reason=""

    if [ "$DETECTED_RAM_GB" -ge 32 ] && [ "$DETECTED_HAS_GPU" = true ]; then
        suggestion="ai"
        reason="High RAM + GPU detected - ideal for serving AI models"
    elif [ "$DETECTED_RAM_GB" -ge 16 ]; then
        suggestion="full"
        reason="Good specs - can run everything locally"
    elif [ "$DETECTED_RAM_GB" -ge 8 ]; then
        suggestion="workstation"
        reason="Suitable for development with remote AI"
    else
        suggestion="services"
        reason="Limited RAM - best as lightweight services node"
    fi

    echo -e "  ${BOLD}Suggested role:${NC} ${suggestion}"
    echo -e "  ${DIM}${reason}${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Node Role Selection (Multi-Select)
# -----------------------------------------------------------------------------

select_node_roles() {
    section "Node Role Selection"

    echo "What will this node be used for?"
    echo -e "${DIM}You can select multiple roles by entering numbers separated by spaces${NC}"
    echo ""
    echo -e "  ${BOLD}1) Developer Workstation${NC}"
    echo -e "     ${DIM}TUI + Claude Code skills for writing agents${NC}"
    echo ""
    echo -e "  ${BOLD}2) Services Host${NC}"
    echo -e "     ${DIM}Host capabilities on the mesh (API exposed to network)${NC}"
    echo ""
    echo -e "  ${BOLD}3) AI Server${NC}"
    echo -e "     ${DIM}Run Ollama and serve AI models to the network${NC}"
    echo ""
    echo -e "  ${BOLD}4) All of the above${NC}"
    echo -e "     ${DIM}Full stack: development + services + AI${NC}"
    echo ""

    # Handle preset roles
    if [ -n "$PRESET_ROLE" ]; then
        parse_preset_roles "$PRESET_ROLE"
        show_selected_roles
        return
    fi

    # Handle headless mode
    if [ "$HEADLESS" = true ]; then
        ROLE_WORKSTATION=true
        info "Headless mode: defaulting to workstation"
        return
    fi

    echo -en "  Enter choices (e.g., 1 3 or 4): "
    read -r choices

    # Parse choices
    for choice in $choices; do
        case "$choice" in
            1) ROLE_WORKSTATION=true ;;
            2) ROLE_SERVICES=true ;;
            3) ROLE_AI=true ;;
            4)
                ROLE_WORKSTATION=true
                ROLE_SERVICES=true
                ROLE_AI=true
                ;;
        esac
    done

    # Default to workstation if nothing selected
    if [ "$ROLE_WORKSTATION" = false ] && [ "$ROLE_SERVICES" = false ] && [ "$ROLE_AI" = false ]; then
        ROLE_WORKSTATION=true
    fi

    echo ""
    show_selected_roles
}

parse_preset_roles() {
    local roles="$1"
    # Support comma or plus separated: "workstation,ai" or "workstation+ai"
    local IFS=',+'
    for role in $roles; do
        case "$role" in
            workstation|dev) ROLE_WORKSTATION=true ;;
            services|server) ROLE_SERVICES=true ;;
            ai|model) ROLE_AI=true ;;
            full|all)
                ROLE_WORKSTATION=true
                ROLE_SERVICES=true
                ROLE_AI=true
                ;;
        esac
    done
}

show_selected_roles() {
    local roles=()
    [ "$ROLE_WORKSTATION" = true ] && roles+=("workstation")
    [ "$ROLE_SERVICES" = true ] && roles+=("services")
    [ "$ROLE_AI" = true ] && roles+=("ai")

    ok "Selected roles: ${roles[*]}"
}

get_roles_string() {
    local roles=()
    [ "$ROLE_WORKSTATION" = true ] && roles+=("workstation")
    [ "$ROLE_SERVICES" = true ] && roles+=("services")
    [ "$ROLE_AI" = true ] && roles+=("ai")
    echo "${roles[*]}"
}

# -----------------------------------------------------------------------------
# AI Model Recommendation
# -----------------------------------------------------------------------------

RECOMMENDED_MODEL=""
RECOMMENDED_MODEL_SIZE=""
RECOMMENDED_MODEL_DESC=""

recommend_model() {
    # Recommend based on hardware and role
    local for_serving=false
    [ "$ROLE_AI" = true ] && for_serving=true

    if [ "$DETECTED_RAM_GB" -ge 32 ] && [ "$DETECTED_HAS_GPU" = true ]; then
        if [ "$for_serving" = true ]; then
            RECOMMENDED_MODEL="codellama:13b-code"
            RECOMMENDED_MODEL_SIZE="~7GB"
            RECOMMENDED_MODEL_DESC="Large model for network serving"
        else
            RECOMMENDED_MODEL="codellama:7b-code"
            RECOMMENDED_MODEL_SIZE="~4GB"
            RECOMMENDED_MODEL_DESC="Best code quality, GPU accelerated"
        fi
    elif [ "$DETECTED_RAM_GB" -ge 16 ] && [ "$DETECTED_HAS_AVX2" = true ]; then
        RECOMMENDED_MODEL="deepseek-coder:6.7b"
        RECOMMENDED_MODEL_SIZE="~4GB"
        RECOMMENDED_MODEL_DESC="Excellent for code, optimized inference"
    elif [ "$DETECTED_RAM_GB" -ge 8 ]; then
        RECOMMENDED_MODEL="deepseek-coder:1.3b"
        RECOMMENDED_MODEL_SIZE="~1GB"
        RECOMMENDED_MODEL_DESC="Good balance of speed and quality"
    elif [ "$DETECTED_RAM_GB" -ge 4 ]; then
        RECOMMENDED_MODEL="tinyllama"
        RECOMMENDED_MODEL_SIZE="~700MB"
        RECOMMENDED_MODEL_DESC="Lightweight, fast responses"
    else
        RECOMMENDED_MODEL=""
        RECOMMENDED_MODEL_DESC="Insufficient RAM for local models"
    fi
}

# -----------------------------------------------------------------------------
# Dependency Checks
# -----------------------------------------------------------------------------

check_dependencies() {
    section "Checking Dependencies"

    local missing=()

    command_exists curl || missing+=("curl")
    command_exists tar  || missing+=("tar")

    if [ ${#missing[@]} -ne 0 ]; then
        fatal "Missing required tools: ${missing[*]}\n  Please install them and try again."
    fi

    ok "All required tools present"
}

# -----------------------------------------------------------------------------
# Runtime Check
# -----------------------------------------------------------------------------

check_dev_runtime() {
    if [ "$ROLE_WORKSTATION" = true ]; then
        if command_exists erl && command_exists elixir; then
            ok "BEAM development runtime found"
        else
            info "BEAM runtime not found (Erlang/Elixir)"
            info "Optional for agent development. Install with:"
            echo -e "  ${DIM}curl https://mise.jdx.dev/install.sh | sh && mise install erlang@27 elixir@1.18${NC}"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Hecate Daemon Installation
# -----------------------------------------------------------------------------

install_daemon() {
    section "Installing Hecate Daemon"

    local os arch version url
    os=$(detect_os)
    arch=$(detect_arch)

    if [ "$HECATE_VERSION" = "latest" ]; then
        version=$(get_latest_release "hecate-daemon")
        if [ -z "$version" ]; then
            warn "Could not fetch latest version, using v0.1.1"
            version="v0.1.1"
        fi
    else
        version="$HECATE_VERSION"
    fi

    url="${REPO_BASE}/hecate-daemon/releases/download/${version}/hecate-daemon-${os}-${arch}"

    mkdir -p "$BIN_DIR"

    download_file "$url" "${BIN_DIR}/hecate"
    chmod +x "${BIN_DIR}/hecate"

    ok "Hecate Daemon ${version} installed"
}

# -----------------------------------------------------------------------------
# Hecate TUI Installation
# -----------------------------------------------------------------------------

install_tui() {
    # Install TUI for workstation role
    if [ "$ROLE_WORKSTATION" = false ]; then
        info "Skipping TUI (not a workstation)"
        return
    fi

    section "Installing Hecate TUI"

    local os arch version url
    os=$(detect_os)
    arch=$(detect_arch)

    if [ "$HECATE_VERSION" = "latest" ]; then
        version=$(get_latest_release "hecate-tui")
        if [ -z "$version" ]; then
            warn "Could not fetch latest version, using v0.1.0"
            version="v0.1.0"
        fi
    else
        version="$HECATE_VERSION"
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
# Claude Skills Installation
# -----------------------------------------------------------------------------

install_skills() {
    # Install skills for workstation role
    if [ "$ROLE_WORKSTATION" = false ]; then
        info "Skipping Claude skills (not a workstation)"
        return
    fi

    section "Installing Claude Code Skills"

    local claude_dir="$HOME/.claude"
    mkdir -p "$claude_dir"

    download_file "${RAW_BASE}/SKILLS.md" "${claude_dir}/HECATE_SKILLS.md"

    # Add include to CLAUDE.md if not already present
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
# Data Directory Setup
# -----------------------------------------------------------------------------

CONFIG_API_HOST="127.0.0.1"
CONFIG_OLLAMA_HOST=""

setup_data_dir() {
    info "Setting up data directory..."

    mkdir -p "${INSTALL_DIR}"/{data,logs,config}

    # Set config based on roles - expose to network if services or AI
    if [ "$ROLE_SERVICES" = true ] || [ "$ROLE_AI" = true ]; then
        CONFIG_API_HOST="0.0.0.0"  # Accept connections from network
    else
        CONFIG_API_HOST="127.0.0.1"  # Local only
    fi

    local roles_string
    roles_string=$(get_roles_string)

    # Create default config if not exists
    if [ ! -f "${INSTALL_DIR}/config/hecate.toml" ]; then
        cat > "${INSTALL_DIR}/config/hecate.toml" << CONF
# Hecate Node Configuration
# Roles: ${roles_string}
# See: https://github.com/hecate-social/hecate-node

[daemon]
api_port = 4444
api_host = "${CONFIG_API_HOST}"

[mesh]
bootstrap = ["boot.macula.io:4433"]
realm = "io.macula"

[logging]
level = "info"
CONF
    fi

    ok "Data directory ready at ${INSTALL_DIR}"
}

# -----------------------------------------------------------------------------
# Ollama Installation
# -----------------------------------------------------------------------------

OLLAMA_NEEDS_SUDO=false

check_ollama_sudo() {
    if [ -w "/usr/local/bin" ]; then
        OLLAMA_NEEDS_SUDO=false
    else
        OLLAMA_NEEDS_SUDO=true
    fi
}

explain_ollama_sudo() {
    echo ""
    echo -e "${YELLOW}${BOLD}Sudo Access Required${NC}"
    echo ""
    echo "Ollama needs sudo access to:"
    echo ""
    echo "  1. ${BOLD}Install binary${NC} to /usr/local/bin/ollama"
    echo "     (system-wide command availability)"
    echo ""
    echo "  2. ${BOLD}Create systemd service${NC} (Linux only)"
    echo "     (auto-start on boot, background operation)"
    echo ""
    echo "The official install script will be run:"
    echo -e "  ${DIM}curl -fsSL https://ollama.com/install.sh | sh${NC}"
    echo ""
    echo "You can review it first at: https://ollama.com/install.sh"
    echo ""
}

install_ollama() {
    if command_exists ollama; then
        ok "Ollama already installed"
        ollama --version 2>/dev/null || true
        return 0
    fi

    section "Installing Ollama"

    check_ollama_sudo

    if [ "$OLLAMA_NEEDS_SUDO" = true ]; then
        explain_ollama_sudo

        if ! confirm "Proceed with Ollama installation?"; then
            warn "Skipping Ollama installation"
            return 1
        fi
    fi

    info "Running Ollama installer..."
    curl -fsSL https://ollama.com/install.sh | sh

    if command_exists ollama; then
        ok "Ollama installed successfully"
        return 0
    else
        error "Ollama installation failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# AI Model Setup (Role-Specific)
# -----------------------------------------------------------------------------

AI_CONFIG_PROVIDER=""
AI_CONFIG_ENDPOINT=""
AI_CONFIG_MODEL=""

setup_ai_for_workstation() {
    section "AI Model Setup"

    recommend_model

    echo "Your workstation can use AI for code assistance."
    echo ""

    local choice
    choice=$(select_option "How would you like to set up AI?" \
        "Connect to an AI node on my network (recommended)" \
        "Install a local model (uses ${DETECTED_RAM_GB}GB RAM)" \
        "Skip AI setup for now")

    case "$choice" in
        1) setup_ai_remote_for_workstation ;;
        2) setup_ai_local ;;
        3) info "Skipping AI setup" ;;
    esac
}

setup_ai_remote_for_workstation() {
    echo ""
    echo "Enter the URL of your AI node (Ollama server)."
    echo ""

    # Try to discover AI nodes on local network
    info "Scanning local network for AI nodes..."
    local found_ai=""

    # Check common IPs on same subnet
    local base_ip
    base_ip=$(echo "$DETECTED_LOCAL_IP" | sed 's/\.[0-9]*$//')

    for last_octet in 1 10 11 12 13 100 200; do
        local test_ip="${base_ip}.${last_octet}"
        if [ "$test_ip" != "$DETECTED_LOCAL_IP" ]; then
            if curl -s --connect-timeout 1 "http://${test_ip}:11434/api/tags" &>/dev/null; then
                found_ai="${test_ip}"
                ok "Found AI node at ${test_ip}"
                break
            fi
        fi
    done

    local default_url=""
    if [ -n "$found_ai" ]; then
        default_url="http://${found_ai}:11434"
    fi

    echo ""
    echo -e "${DIM}Example: http://192.168.1.100:11434 or http://ai-server.local:11434${NC}"
    local remote_url
    remote_url=$(prompt_input "Ollama URL" "$default_url")

    if [ -z "$remote_url" ]; then
        warn "No URL provided, skipping"
        return
    fi

    # Test connection
    info "Testing connection to ${remote_url}..."
    if curl -s "${remote_url}/api/tags" &>/dev/null; then
        ok "Connected to AI node"

        # List available models
        echo ""
        info "Available models:"
        local models
        models=$(curl -s "${remote_url}/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g; s/"//g')
        echo "$models" | while read -r m; do
            [ -n "$m" ] && echo "    - $m"
        done
        echo ""

        local model
        model=$(prompt_input "Model to use" "$(echo "$models" | head -1)")

        AI_CONFIG_PROVIDER="ollama"
        AI_CONFIG_ENDPOINT="$remote_url"
        AI_CONFIG_MODEL="$model"

        ok "AI configured: ${model} @ ${remote_url}"
    else
        error "Could not connect to ${remote_url}"
        warn "Skipping AI setup"
    fi
}

setup_ai_for_services() {
    section "AI Configuration"

    echo "Services nodes typically connect to an AI node on the network."
    echo ""

    local choice
    choice=$(select_option "AI model setup:" \
        "Connect to an AI node on my network" \
        "Skip AI (this node won't use AI directly)")

    case "$choice" in
        1) setup_ai_remote_for_workstation ;;
        2) info "Skipping AI setup" ;;
    esac
}

setup_ai_for_ai_node() {
    section "AI Node Setup"

    echo "This node will serve AI models to other nodes on your network."
    echo ""
    echo -e "Your IP: ${BOLD}${DETECTED_LOCAL_IP}${NC}"
    echo -e "Other nodes will connect to: ${BOLD}http://${DETECTED_LOCAL_IP}:11434${NC}"
    echo ""

    if ! install_ollama; then
        warn "Continuing without Ollama"
        return
    fi

    # Configure Ollama to listen on all interfaces
    configure_ollama_network

    # Start Ollama
    start_ollama_service

    # Select and pull model
    recommend_model
    echo ""
    echo -e "Recommended model for serving: ${BOLD}${RECOMMENDED_MODEL}${NC}"
    echo ""

    local model_choice
    model_choice=$(select_option "Which model to serve?" \
        "${RECOMMENDED_MODEL} - ${RECOMMENDED_MODEL_DESC}" \
        "deepseek-coder:6.7b - Good for code (~4GB)" \
        "codellama:13b-code - Large, best quality (~7GB)" \
        "Custom model (enter name)")

    local model
    case "$model_choice" in
        1) model="$RECOMMENDED_MODEL" ;;
        2) model="deepseek-coder:6.7b" ;;
        3) model="codellama:13b-code" ;;
        4) model=$(prompt_input "Model name" "") ;;
        *) model="$RECOMMENDED_MODEL" ;;
    esac

    if [ -n "$model" ]; then
        info "Pulling model: ${model}"
        info "This may take several minutes..."
        echo ""

        if ollama pull "$model"; then
            ok "Model ${model} ready to serve"
            AI_CONFIG_PROVIDER="ollama"
            AI_CONFIG_ENDPOINT="http://0.0.0.0:11434"
            AI_CONFIG_MODEL="$model"
        else
            error "Failed to pull model"
        fi
    fi

    # Show connection info for other nodes
    echo ""
    echo -e "${GREEN}${BOLD}AI Node Ready${NC}"
    echo ""
    echo "Other nodes on your network can connect using:"
    echo -e "  ${CYAN}http://${DETECTED_LOCAL_IP}:11434${NC}"
    echo ""
    echo "To test from another machine:"
    echo -e "  ${DIM}curl http://${DETECTED_LOCAL_IP}:11434/api/tags${NC}"
    echo ""
}

setup_ai_local() {
    if ! install_ollama; then
        warn "Continuing without Ollama"
        return
    fi

    # Ensure Ollama is running
    start_ollama_service

    recommend_model

    echo ""
    echo -e "Recommended: ${BOLD}${RECOMMENDED_MODEL}${NC} (${RECOMMENDED_MODEL_SIZE})"
    echo ""

    local model_choice
    model_choice=$(select_option "Which model to install?" \
        "deepseek-coder:1.3b - Fast, good for code (~1GB)" \
        "deepseek-coder:6.7b - Better quality (~4GB)" \
        "codellama:7b-code - Best code quality (~4GB)" \
        "tinyllama - Minimal, very fast (~700MB)" \
        "Custom model (enter name)")

    local model
    case "$model_choice" in
        1) model="deepseek-coder:1.3b" ;;
        2) model="deepseek-coder:6.7b" ;;
        3) model="codellama:7b-code" ;;
        4) model="tinyllama" ;;
        5) model=$(prompt_input "Model name" "") ;;
        *) model="deepseek-coder:1.3b" ;;
    esac

    if [ -n "$model" ]; then
        info "Pulling model: ${model}"
        info "This may take a few minutes..."
        echo ""

        if ollama pull "$model"; then
            ok "Model ${model} ready"
            AI_CONFIG_PROVIDER="ollama"
            AI_CONFIG_ENDPOINT="http://localhost:11434"
            AI_CONFIG_MODEL="$model"
        else
            error "Failed to pull model"
        fi
    fi
}

configure_ollama_network() {
    local os
    os=$(detect_os)

    if [ "$os" = "linux" ] && command_exists systemctl; then
        # Configure systemd service to listen on all interfaces
        local override_dir="/etc/systemd/system/ollama.service.d"

        echo ""
        echo -e "${YELLOW}${BOLD}Network Configuration Required${NC}"
        echo ""
        echo "To allow other nodes to connect, Ollama needs to listen on all interfaces."
        echo ""
        echo "This requires sudo to create:"
        echo -e "  ${DIM}${override_dir}/network.conf${NC}"
        echo ""
        echo "Contents:"
        echo -e "  ${DIM}[Service]${NC}"
        echo -e "  ${DIM}Environment=\"OLLAMA_HOST=0.0.0.0\"${NC}"
        echo ""

        if confirm "Configure Ollama for network access?"; then
            sudo mkdir -p "$override_dir"
            echo '[Service]
Environment="OLLAMA_HOST=0.0.0.0"' | sudo tee "${override_dir}/network.conf" > /dev/null
            sudo systemctl daemon-reload
            ok "Ollama configured for network access"
        else
            warn "Ollama will only be accessible locally"
        fi
    else
        # macOS or no systemd - provide manual instructions
        echo ""
        info "To expose Ollama to the network, set before starting:"
        echo -e "  ${CYAN}export OLLAMA_HOST=0.0.0.0${NC}"
        echo ""
    fi
}

start_ollama_service() {
    if curl -s http://localhost:11434/api/tags &>/dev/null; then
        ok "Ollama is running"
        return
    fi

    info "Starting Ollama..."

    local os
    os=$(detect_os)

    if [ "$os" = "linux" ] && command_exists systemctl; then
        if systemctl is-enabled ollama &>/dev/null; then
            sudo systemctl restart ollama
            sleep 2
        else
            ollama serve &>/dev/null &
            sleep 2
        fi
    else
        ollama serve &>/dev/null &
        sleep 2
    fi

    if curl -s http://localhost:11434/api/tags &>/dev/null; then
        ok "Ollama started"
    else
        warn "Ollama may not be running"
    fi
}

setup_ai_model() {
    if [ "$SKIP_AI" = true ]; then
        info "Skipping AI setup (--no-ai)"
        return
    fi

    # AI role takes precedence - set up as AI server
    if [ "$ROLE_AI" = true ]; then
        setup_ai_for_ai_node
    # Workstation can use local or remote AI
    elif [ "$ROLE_WORKSTATION" = true ]; then
        setup_ai_for_workstation
    # Services-only connects to remote AI
    elif [ "$ROLE_SERVICES" = true ]; then
        setup_ai_for_services
    fi
}

save_ai_config() {
    if [ -n "$AI_CONFIG_PROVIDER" ]; then
        cat >> "${INSTALL_DIR}/config/hecate.toml" << EOF

[ai]
provider = "${AI_CONFIG_PROVIDER}"
endpoint = "${AI_CONFIG_ENDPOINT}"
EOF
        if [ -n "$AI_CONFIG_MODEL" ]; then
            echo "model = \"${AI_CONFIG_MODEL}\"" >> "${INSTALL_DIR}/config/hecate.toml"
        fi

        ok "AI configuration saved"
    fi
}

# -----------------------------------------------------------------------------
# Systemd Service (for services and AI nodes)
# -----------------------------------------------------------------------------

setup_systemd_service() {
    # Only for Linux
    if [ "$(detect_os)" != "linux" ]; then
        return
    fi

    # Only offer for services or AI roles (server-like)
    if [ "$ROLE_SERVICES" = false ] && [ "$ROLE_AI" = false ]; then
        return
    fi

    if ! command_exists systemctl; then
        return
    fi

    section "System Service Setup"

    echo "For server nodes, it's recommended to run Hecate as a system service."
    echo "This enables:"
    echo "  - Auto-start on boot"
    echo "  - Automatic restart on failure"
    echo "  - Background operation"
    echo ""

    if ! confirm "Create systemd service for Hecate?"; then
        info "Skipping systemd service"
        return
    fi

    echo ""
    echo -e "${YELLOW}${BOLD}Sudo Required${NC}"
    echo ""
    echo "Creating systemd service requires sudo to write:"
    echo -e "  ${DIM}/etc/systemd/system/hecate.service${NC}"
    echo ""

    local service_file="/etc/systemd/system/hecate.service"

    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=Hecate Mesh Daemon
After=network.target

[Service]
Type=simple
User=${USER}
ExecStart=${BIN_DIR}/hecate start --foreground
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable hecate

    ok "Systemd service created and enabled"
    echo ""
    echo "To start now:"
    echo -e "  ${CYAN}sudo systemctl start hecate${NC}"
    echo ""
    echo "To view logs:"
    echo -e "  ${CYAN}journalctl -u hecate -f${NC}"
}

# -----------------------------------------------------------------------------
# PATH Setup
# -----------------------------------------------------------------------------

setup_path() {
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
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
    section "Installation Complete"

    local roles_string
    roles_string=$(get_roles_string)

    echo -e "${GREEN}${BOLD}Hecate node is ready!${NC}"
    echo -e "Roles: ${BOLD}${roles_string}${NC}"
    echo ""

    echo "Installed components:"
    echo -e "  ${BOLD}hecate${NC}       - Mesh daemon       ${DIM}${BIN_DIR}/hecate${NC}"

    if [ "$ROLE_WORKSTATION" = true ]; then
        echo -e "  ${BOLD}hecate-tui${NC}   - Terminal UI       ${DIM}${BIN_DIR}/hecate-tui${NC}"
        echo -e "  ${BOLD}skills${NC}       - Claude Code       ${DIM}~/.claude/HECATE_SKILLS.md${NC}"
    fi

    if [ -n "$AI_CONFIG_MODEL" ]; then
        echo -e "  ${BOLD}ai model${NC}     - ${AI_CONFIG_MODEL}"
        echo -e "                   ${DIM}${AI_CONFIG_ENDPOINT}${NC}"
    fi

    echo ""
    echo "Configuration: ${INSTALL_DIR}/config/hecate.toml"
    echo ""

    echo -e "${BOLD}Next steps:${NC}"
    echo ""

    local step=1

    # Start command depends on whether systemd service was created
    if [ "$ROLE_SERVICES" = true ] || [ "$ROLE_AI" = true ]; then
        echo "  ${step}. Start the service:"
        echo -e "     ${CYAN}sudo systemctl start hecate${NC}"
        echo -e "     ${DIM}or: hecate start${NC}"
        ((step++))
        echo ""
    else
        echo "  ${step}. Start the daemon:"
        echo -e "     ${CYAN}hecate start${NC}"
        ((step++))
        echo ""
    fi

    # TUI for workstation
    if [ "$ROLE_WORKSTATION" = true ]; then
        echo "  ${step}. Open the TUI:"
        echo -e "     ${CYAN}hecate-tui${NC}"
        ((step++))
        echo ""

        echo "  ${step}. Pair with the mesh (first time):"
        echo -e "     ${CYAN}hecate-tui pair${NC}"
        ((step++))
        echo ""
    fi

    # AI node info
    if [ "$ROLE_AI" = true ]; then
        echo "  ${step}. Verify Ollama is accessible from network:"
        echo -e "     ${CYAN}curl http://${DETECTED_LOCAL_IP}:11434/api/tags${NC}"
        ((step++))
        echo ""

        echo "  ${step}. Share this URL with other nodes:"
        echo -e "     ${CYAN}http://${DETECTED_LOCAL_IP}:11434${NC}"
        ((step++))
        echo ""
    fi

    # Test AI if configured
    if [ -n "$AI_CONFIG_MODEL" ] && [ "$ROLE_AI" = false ]; then
        echo "  ${step}. Test AI model:"
        echo -e "     ${CYAN}curl ${AI_CONFIG_ENDPOINT}/api/generate -d '{\"model\":\"${AI_CONFIG_MODEL}\",\"prompt\":\"Hello\"}'${NC}"
        ((step++))
        echo ""
    fi

    echo -e "${DIM}Documentation: https://github.com/hecate-social/hecate-node${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

show_help() {
    echo "Hecate Node Installer"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --role=ROLES  Set node roles (can combine: workstation,services,ai)"
    echo "  --no-ai       Skip AI model setup"
    echo "  --headless    Non-interactive mode (use defaults)"
    echo "  --help        Show this help"
    echo ""
    echo "Node roles (can be combined with comma or plus):"
    echo "  workstation   Developer workstation (TUI + Claude skills)"
    echo "  services      Services host (API exposed to network)"
    echo "  ai            AI model server (Ollama exposed to network)"
    echo "  full          All roles combined"
    echo ""
    echo "Environment variables:"
    echo "  HECATE_VERSION     Version to install (default: latest)"
    echo "  HECATE_INSTALL_DIR Data directory (default: ~/.hecate)"
    echo "  HECATE_BIN_DIR     Binary directory (default: ~/.local/bin)"
    echo ""
    echo "Examples:"
    echo "  # Interactive (recommended)"
    echo "  curl -fsSL https://hecate.social/install.sh | bash"
    echo ""
    echo "  # Single role"
    echo "  curl -fsSL https://hecate.social/install.sh | bash -s -- --role=workstation"
    echo ""
    echo "  # Combined roles (AI server + dev workstation)"
    echo "  curl -fsSL https://hecate.social/install.sh | bash -s -- --role=ai,workstation"
    echo ""
    echo "  # Headless services node"
    echo "  curl -fsSL https://hecate.social/install.sh | bash -s -- --role=services --no-ai"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role=*)
                PRESET_ROLE="${1#*=}"
                shift
                ;;
            --no-ai)
                SKIP_AI=true
                shift
                ;;
            --headless)
                HEADLESS=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    show_banner
    check_dependencies
    detect_hardware
    select_node_roles

    local roles_string
    roles_string=$(get_roles_string)

    echo ""
    echo -e "Roles:       ${BOLD}${roles_string}${NC}"
    echo -e "Install to:  ${BOLD}${INSTALL_DIR}${NC}"
    echo -e "Binaries:    ${BOLD}${BIN_DIR}${NC}"
    echo ""

    if ! confirm "Continue with installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi

    setup_data_dir
    install_daemon
    install_tui
    install_skills
    check_dev_runtime
    setup_ai_model
    save_ai_config
    setup_systemd_service
    setup_path
    show_summary
}

main "$@"
