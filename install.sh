#!/usr/bin/env bash
#
# Hecate Node Installer
# Usage: curl -fsSL https://hecate.social/install.sh | bash
#
# Options:
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

    # Display results
    echo -e "  ${BOLD}RAM:${NC}        ${DETECTED_RAM_GB} GB"
    echo -e "  ${BOLD}CPU Cores:${NC}  ${DETECTED_CPU_CORES}"
    echo -e "  ${BOLD}AVX2:${NC}       $([ "$DETECTED_HAS_AVX2" = true ] && echo "Yes" || echo "No")"
    if [ "$DETECTED_HAS_GPU" = true ]; then
        echo -e "  ${BOLD}GPU:${NC}        ${DETECTED_GPU_TYPE}"
    else
        echo -e "  ${BOLD}GPU:${NC}        None detected"
    fi
    echo ""
}

# -----------------------------------------------------------------------------
# AI Model Recommendation
# -----------------------------------------------------------------------------

RECOMMENDED_MODEL=""
RECOMMENDED_MODEL_SIZE=""
RECOMMENDED_MODEL_DESC=""

recommend_model() {
    # Recommend based on hardware
    if [ "$DETECTED_RAM_GB" -ge 32 ] && [ "$DETECTED_HAS_GPU" = true ]; then
        RECOMMENDED_MODEL="codellama:7b-code"
        RECOMMENDED_MODEL_SIZE="~4GB"
        RECOMMENDED_MODEL_DESC="Best code quality, GPU accelerated"
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
# Runtime Installation (Erlang + Elixir - optional, for development)
# -----------------------------------------------------------------------------

check_dev_runtime() {
    if command_exists erl && command_exists elixir; then
        ok "BEAM development runtime found (optional)"
    else
        info "BEAM runtime not found (Erlang/Elixir)"
        info "This is optional - the daemon includes bundled runtime."
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

    # Download self-extracting executable (includes bundled Erlang runtime)
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

setup_data_dir() {
    info "Setting up data directory..."

    mkdir -p "${INSTALL_DIR}"/{data,logs,config}

    # Create default config if not exists
    if [ ! -f "${INSTALL_DIR}/config/hecate.toml" ]; then
        cat > "${INSTALL_DIR}/config/hecate.toml" << 'CONF'
# Hecate Node Configuration
# See: https://github.com/hecate-social/hecate-node

[daemon]
api_port = 4444
api_host = "127.0.0.1"

[mesh]
bootstrap = ["boot.macula.io:4433"]
realm = "io.macula"

[logging]
level = "info"

# AI Model Configuration (optional)
# Uncomment and configure if using local or remote AI models
# [ai]
# provider = "ollama"
# endpoint = "http://localhost:11434"
# model = "deepseek-coder:1.3b"
CONF
    fi

    ok "Data directory ready at ${INSTALL_DIR}"
}

# -----------------------------------------------------------------------------
# Ollama Installation
# -----------------------------------------------------------------------------

OLLAMA_NEEDS_SUDO=false

check_ollama_sudo() {
    # Ollama's install script typically needs sudo for:
    # 1. Creating /usr/local/bin/ollama
    # 2. Creating systemd service
    # We'll check if we can write to /usr/local/bin

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
    section "Installing Ollama"

    if command_exists ollama; then
        ok "Ollama already installed"
        ollama --version 2>/dev/null || true
        return 0
    fi

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
# AI Model Setup
# -----------------------------------------------------------------------------

AI_CONFIG_PROVIDER=""
AI_CONFIG_ENDPOINT=""
AI_CONFIG_MODEL=""

setup_ai_model() {
    section "AI Model Setup"

    recommend_model

    echo "Hecate can integrate with AI models for code generation."
    echo "This is optional but enables AI-assisted agent development."
    echo ""

    if [ -z "$RECOMMENDED_MODEL" ]; then
        warn "Your system has limited RAM (${DETECTED_RAM_GB}GB)"
        warn "Local AI models may not perform well."
        echo ""
    else
        echo -e "Based on your hardware, we recommend:"
        echo -e "  ${BOLD}${RECOMMENDED_MODEL}${NC} (${RECOMMENDED_MODEL_SIZE})"
        echo -e "  ${DIM}${RECOMMENDED_MODEL_DESC}${NC}"
        echo ""
    fi

    local choice
    choice=$(select_option "How would you like to set up AI?" \
        "Install Ollama + recommended model (${RECOMMENDED_MODEL:-tinyllama})" \
        "Use a remote Ollama server (enter URL)" \
        "Skip AI setup for now")

    case "$choice" in
        1)
            setup_ai_local
            ;;
        2)
            setup_ai_remote
            ;;
        3)
            info "Skipping AI setup"
            info "You can configure AI later in ${INSTALL_DIR}/config/hecate.toml"
            ;;
        *)
            info "Skipping AI setup"
            ;;
    esac
}

setup_ai_local() {
    if ! install_ollama; then
        warn "Continuing without Ollama"
        return
    fi

    # Ensure Ollama is running
    if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
        info "Starting Ollama service..."
        if command_exists systemctl && systemctl is-active --quiet ollama 2>/dev/null; then
            : # Already running via systemd
        else
            # Start in background
            ollama serve &>/dev/null &
            sleep 2
        fi
    fi

    # Select model
    local model_choice
    echo ""
    model_choice=$(select_option "Which model would you like to install?" \
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
        5)
            echo -en "  Enter model name: "
            read -r model
            ;;
        *) model="deepseek-coder:1.3b" ;;
    esac

    info "Pulling model: ${model}"
    info "This may take a few minutes depending on your connection..."
    echo ""

    if ollama pull "$model"; then
        ok "Model ${model} ready"
        AI_CONFIG_PROVIDER="ollama"
        AI_CONFIG_ENDPOINT="http://localhost:11434"
        AI_CONFIG_MODEL="$model"
    else
        error "Failed to pull model"
    fi
}

setup_ai_remote() {
    echo ""
    echo "Enter the URL of your Ollama server."
    echo -e "${DIM}Example: http://192.168.1.100:11434 or http://ai-server.local:11434${NC}"
    echo ""
    echo -en "  Ollama URL: "
    read -r remote_url

    if [ -z "$remote_url" ]; then
        warn "No URL provided, skipping"
        return
    fi

    # Test connection
    info "Testing connection to ${remote_url}..."
    if curl -s "${remote_url}/api/tags" &>/dev/null; then
        ok "Connected to remote Ollama"

        # List available models
        echo ""
        info "Available models on remote server:"
        curl -s "${remote_url}/api/tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g; s/"//g' | while read -r m; do
            echo "    - $m"
        done
        echo ""

        echo -en "  Model to use (or press Enter to skip): "
        read -r model

        AI_CONFIG_PROVIDER="ollama"
        AI_CONFIG_ENDPOINT="$remote_url"
        AI_CONFIG_MODEL="${model:-}"
    else
        error "Could not connect to ${remote_url}"
        warn "Skipping remote AI setup"
    fi
}

save_ai_config() {
    if [ -n "$AI_CONFIG_PROVIDER" ]; then
        # Update config file with AI settings
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
# PATH Setup
# -----------------------------------------------------------------------------

setup_path() {
    section "Finalizing Installation"

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        warn "$BIN_DIR is not in PATH"
        echo ""
        echo "Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
        echo ""
        echo -e "  ${BOLD}export PATH=\"\$PATH:$BIN_DIR\"${NC}"
        echo ""
        echo "Then reload your shell or run:"
        echo ""
        echo -e "  ${BOLD}source ~/.bashrc${NC}  # or ~/.zshrc"
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

    echo -e "${GREEN}${BOLD}Hecate is ready!${NC}"
    echo ""
    echo "Installed components:"
    echo -e "  ${BOLD}hecate${NC}       - Mesh daemon       ${DIM}${BIN_DIR}/hecate${NC}"
    echo -e "  ${BOLD}hecate-tui${NC}   - Terminal UI       ${DIM}${BIN_DIR}/hecate-tui${NC}"
    echo -e "  ${BOLD}skills${NC}       - Claude Code       ${DIM}~/.claude/HECATE_SKILLS.md${NC}"

    if [ -n "$AI_CONFIG_MODEL" ]; then
        echo -e "  ${BOLD}ai model${NC}     - ${AI_CONFIG_MODEL}   ${DIM}${AI_CONFIG_ENDPOINT}${NC}"
    fi

    echo ""
    echo "Configuration: ${INSTALL_DIR}/config/hecate.toml"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo ""
    echo "  1. Start the daemon:"
    echo -e "     ${CYAN}hecate start${NC}"
    echo ""
    echo "  2. Open the TUI to monitor:"
    echo -e "     ${CYAN}hecate-tui${NC}"
    echo ""
    echo "  3. Pair with the mesh (first time):"
    echo -e "     ${CYAN}hecate-tui pair${NC}"
    echo ""

    if [ -n "$AI_CONFIG_MODEL" ]; then
        echo "  4. Test AI model:"
        echo -e "     ${CYAN}ollama run ${AI_CONFIG_MODEL} \"Write a Go hello world\"${NC}"
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
    echo "  --no-ai      Skip AI model setup"
    echo "  --headless   Non-interactive mode (use defaults)"
    echo "  --help       Show this help"
    echo ""
    echo "Environment variables:"
    echo "  HECATE_VERSION     Version to install (default: latest)"
    echo "  HECATE_INSTALL_DIR Data directory (default: ~/.hecate)"
    echo "  HECATE_BIN_DIR     Binary directory (default: ~/.local/bin)"
    echo ""
    echo "Examples:"
    echo "  curl -fsSL https://hecate.social/install.sh | bash"
    echo "  curl -fsSL https://hecate.social/install.sh | bash -s -- --no-ai"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
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

    echo -e "Installing to: ${BOLD}${INSTALL_DIR}${NC}"
    echo -e "Binaries to:   ${BOLD}${BIN_DIR}${NC}"
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

    if [ "$SKIP_AI" = false ]; then
        setup_ai_model
        save_ai_config
    fi

    setup_path
    show_summary
}

main "$@"
