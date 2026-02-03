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
# Enhanced avatar - generated from avatar.jpg with gamma 2.2, unsharp, saturation boost
HECATE_AVATAR_B64="G1swbRtbMzg7NTsyMzg7NDg7NTsyMzZtXxtbNDg7NTsyMzhtIBtbNDg7NTsyNDBtfhtbMzg7NTsyNDA7NDg7NTs5NW1gG1szODs1OzEzN21fG1s0ODs1OzEwMW1fG1szODs1OzEzOG1nG1szODs1OzI0NDs0ODs1OzEzOG1+G1szODs1OzE0NDs0ODs1OzI0Nm15G1szODs1OzI0Njs0ODs1OzI0N21+fn4bWzM4OzU7MjU1OzQ4OzU7MjQ4bV9fG1szODs1OzI0Njs0ODs1OzI0N21gG1szODs1OzI0OG15XxtbMzg7NTsxNDQ7NDg7NTsyNDZtXxtbMzg7NTsyNDY7NDg7NTsyNDRteRtbMzg7NTsxMzhtXxtbMzg7NTsxMzc7NDg7NTsxMDFtXxtbMzg7NTsyNDFtYBtbMzg7NTszOzQ4OzU7MjQwbXkbWzQ4OzU7MjM4bV8bWzM4OzU7MjM4OzQ4OzU7MjM3bXkbWzM4OzU7MjM0OzQ4OzU7MjM1bX4bWzBtChtbMzg7NTs5NDs0ODs1OzU4bXkbWzM4OzU7Mzs0ODs1Ozk1bX4bWzM4OzU7MTczOzQ4OzU7MTMxbV8bWzM4OzU7MTgxOzQ4OzU7MTczbScbWzM4OzU7MjU1bS4bWzM4OzU7MTgwOzQ4OzU7MTc0bSwbWzM4OzU7MTM4bX4bWzM4OzU7MTQ0OzQ4OzU7MTgwbX4bWzM4OzU7MTgwOzQ4OzU7MTQ0bXkbWzM4OzU7MTQ1OzQ4OzU7MjQ5bUZgG1szODs1Ozc7NDg7NTsyNTRtfhtbNDg7NTsyNTVtXxtbMzg7NTsyNDdtXxtbMzg7NTsxODhtLBtbMzg7NTsxNDU7NDg7NTsyNTBtYBtbMzg7NTsyNDg7NDg7NTsyNDltfhtbMzg7NTsxODE7NDg7NTsxNDRteRtbMzg7NTsxNDQ7NDg7NTsxODBtfhtbNDg7NTsxNzRtIBtbMzg7NTsxMzdtYBtbMzg7NTsxODc7NDg7NTsxMzhteRtbNDg7NTsxMzFtIBtbMzg7NTsxMzE7NDg7NTs5NW1fG1szODs1OzU4bX4bWzQ4OzU7MjM4bV8bWzBtChtbMzg7NTs5NTs0ODs1OzEzMW1+G1szODs1OzE3M215G1s0ODs1OzE3M20gG1s0ODs1OzIwOW1gG1szODs1OzE4Nzs0ODs1OzIyNG1+G1szODs1OzIyMzs0ODs1OzIxNm1MG1szODs1OzIxNjs0ODs1OzIxN21MG1szODs1OzIxNzs0ODs1OzE4MW15IBtbMzg7NTsxODE7NDg7NTsxODdtfhtbMzg7NTsyNDk7NDg7NTsyNTJtLxtbMzg7NTsyNDI7NDg7NTsyNTBteRtbMzg7NTsxMzg7NDg7NTsyNDNteRtbNDg7NTsyNDRtbRtbMzg7NTsyNTQ7NDg7NTsyNDZtIhtbMzg7NTsyNDc7NDg7NTsyNTJtIhtbMzg7NTsyNTA7NDg7NTsxODdtfhtbNDg7NTsxODFtIBtbMzg7NTsyMTdteRtbMzg7NTsxNzQ7NDg7NTsyMTZtfhtbMzg7NTsyMjNtXxtbMzg7NTsxODA7NDg7NTsyMjNtfhtbNDg7NTsxNzNtIBtbMzg7NTsxMzFtfhtbNDg7NTsxMzFtIBtbNDg7NTs5NG0gG1swbQobWzM4OzU7MTMxOzQ4OzU7MTMxbSAbWzM4OzU7MTY3OzQ4OzU7MTczbUwbWzQ4OzU7MjA5bSAbWzM4OzU7MjE1OzQ4OzU7MjE2bWAbWzM4OzU7MjMxOzQ4OzU7MjI0bScbWzM4OzU7MjIzOzQ4OzU7MjE2bXIbWzQ4OzU7MjE3bSAgG1s0ODs1OzE4N20gG1szODs1OzE1MW0uG1szODs1OzY2OzQ4OzU7MTQ1bXkbWzM4OzU7MjQxOzQ4OzU7MjM2bX4bWzM4OzU7MjQwOzQ4OzU7MTM4bV8bWzM4OzU7MTM4OzQ4OzU7MTgxbWAbWzQ4OzU7MjM5bUYbWzM4OzU7NTk7NDg7NTsyNDdtTBtbMzg7NTsyNTU7NDg7NTsxODdtLCAbWzM4OzU7MjIzOzQ4OzU7MjE3bV8gG1szODs1OzI1NW1gG1szODs1OzIyNDs0ODs1OzI1NW1+G1szODs1OzE4MDs0ODs1OzIxNW0sG1s0ODs1OzE3M20gG1szODs1OzEzNzs0ODs1OzEzMW0uG1s0ODs1Ozk1bSAbWzBtChtbMzg7NTs5NTs0ODs1OzEzMW1fG1szODs1OzE2N200G1s0ODs1OzE3M20gG1szODs1OzIyM21yG1szODs1OzEzMTs0ODs1OzIxNm1fG1szODs1OzIxNjs0ODs1OzIxN21gG1szODs1OzE4MW1fG1szODs1OzIyMzs0ODs1OzE4N21gG1szODs1OzI1NTs0ODs1OzE4OG14G1szODs1OzE0Njs0ODs1OzI1Mm1fG1szODs1OzEwMzs0ODs1OzYwbV8bWzQ4OzU7OG1fG1szODs1OzIzOTs0ODs1OzIzNm15G1szODs1OzI0M21gG1szODs1OzIzNzs0ODs1OzIzNG15G1szODs1OzIzOTs0ODs1OzIzOG0iG1szODs1OzI0Njs0ODs1OzdtTBtbMzg7NTsyMzE7NDg7NTsxODdtXyAbWzQ4OzU7MjE3bSAbWzM4OzU7MjE2bWAbWzM4OzU7MTczOzQ4OzU7MjIzbXkbWzM4OzU7MjE2OzQ4OzU7MTczbVkgG1s0ODs1OzEzMW0gG1s0ODs1Ozk1bSAbWzBtChtbMzg7NTs1OTs0ODs1Ozk1bXcbWzM4OzU7MTMxbX4bWzQ4OzU7MTM3bSBKIBtbNDg7NTsxODFtICAbWzQ4OzU7MTg3bSAbWzM4OzU7MjQ5OzQ4OzU7MjUybT4bWzM4OzU7MTQ2OzQ4OzU7MTg5bXIbWzM4OzU7MjU1OzQ4OzU7MTAzbV8bWzM4OzU7MjUwbXkbWzM4OzU7MjQ3OzQ4OzU7MjQzbVIbWzM4OzU7MjQ4OzQ4OzU7MjQybX4bWzM4OzU7MTM5OzQ4OzU7MTAybWcbWzM4OzU7MjQ4OzQ4OzU7MjQ2bWcbWzM4OzU7MjMxOzQ4OzU7MjU0bWAbWzM4OzU7MjMwOzQ4OzU7MjMxbV8bWzM4OzU7MjU1OzQ4OzU7MTg4bUwbWzQ4OzU7MTg3bSAbWzQ4OzU7MTgxbSAbWzQ4OzU7MTczbSAbWzM4OzU7MTMxOzQ4OzU7MTM3bUYbWzM4OzU7MTAxbV8bWzQ4OzU7MTAxbSAbWzM4OzU7MjQwOzQ4OzU7M215G1swbQobWzM4OzU7MjM5OzQ4OzU7MjQwbUwbWzM4OzU7MTAxOzQ4OzU7MjQybWAbWzQ4OzU7MjQ0bWAbWzM4OzU7MTQ0OzQ4OzU7MjQ2bWAbWzM4OzU7OTU7NDg7NTsxMzhtTBtbMzg7NTsxNDU7NDg7NTsyNDltchtbNDg7NTsyNTBtIBtbMzg7NTsyNDk7NDg7NTsyNTFtLhtbMzg7NTsyNDM7NDg7NTsyNDdtXxtbMzg7NTsxNDU7NDg7NTsyNDJtNBtbNDg7NTsyNDBtIhtbMzg7NTsyNDc7NDg7NTsyNDNteRtbMzg7NTsyMzk7NDg7NTsxMDNtYBtbMzg7NTsyNDJtSRtbNDg7NTsxMDRtIBtbMzg7NTsxNDY7NDg7NTsxNDBtfhtbMzg7NTsxMzk7NDg7NTsxODJtXxtbMzg7NTsxNDU7NDg7NTsxODhtTBtbMzg7NTsyNTI7NDg7NTsyNTRtNBtbNDg7NTsyNTBtIBtbMzg7NTsyNDk7NDg7NTsxNDVtYBtbMzg7NTs5NTs0ODs1OzEzOG1KG1szODs1OzE0NDs0ODs1OzI0N20iG1szODs1OzEwMTs0ODs1OzEwMm1gG1szODs1Ozk1OzQ4OzU7MjQybSIbWzM4OzU7MjM5OzQ4OzU7MjQwbWcbWzBtChtbMzg7NTsyNDA7NDg7NTsyMzltShtbNDg7NTsyNDJtIBtbNDg7NTsyNDRtIBtbMzg7NTsyNDQ7NDg7NTsyNDZtTBtbMzg7NTsyNDA7NDg7NTsyNDRtWxtbNDg7NTsyNDhtIBtbNDg7NTsyNDltIBtbMzg7NTsyNDc7NDg7NTsxODFtShtbMzg7NTsyNDM7NDg7NTsyMzdtfhtbMzg7NTsyMzU7NDg7NTsyMzJtfhtbMzg7NTsxNjs0ODs1OzIzNG06G1szODs1OzI0MDs0ODs1OzEwM21MG1szODs1OzE0MG1cG1szODs1OzI0Nzs0ODs1OzI0M21MG1szODs1OzYwOzQ4OzU7NjdtXyAbWzM4OzU7MTM5OzQ4OzU7MTAzbUobWzM4OzU7NjFtLhtbMzg7NTsxNDU7NDg7NTsxMDJtNxtbMzg7NTs5NTs0ODs1OzE0NW0sG1s0ODs1OzI0OG0gG1szODs1OzI0MDs0ODs1OzEwMm1qG1s0ODs1OzI0Nm0gG1szODs1OzEwMjs0ODs1OzI0NG1GG1s0ODs1OzI0Mm0gG1szODs1OzI0MDs0ODs1OzIzOW1GG1swbQobWzM4OzU7MjM4OzQ4OzU7MjM5bS4bWzM4OzU7MjQyOzQ4OzU7MjQxbX4bWzQ4OzU7MjQzbSAbWzQ4OzU7MjQ0bSAbWzM4OzU7MjM5bUkbWzQ4OzU7MjQ3bSAbWzM4OzU7MTQ1OzQ4OzU7MjQ4bWAbWzM4OzU7MjQ4OzQ4OzU7MjQzbUYbWzM4OzU7MjM4OzQ4OzU7MjM1bVsbWzM4OzU7MjMzOzQ4OzU7MTZtLRtbNDg7NTsyMzZtRhtbNDg7NTsyMzhtOhtbMzg7NTsyNDk7NDg7NTsyNDRtVxtbMzg7NTs1OW0kG1szODs1OzY3OzQ4OzU7NjZtTBtbNDg7NTs2MG00G1szODs1OzEwMzs0ODs1OzY3bSIbWzM4OzU7MTM5OzQ4OzU7NjBtW1wbWzM4OzU7MTgxOzQ4OzU7MjQzbV4bWzM4OzU7MjQ4OzQ4OzU7MjQ3bUYbWzM4OzU7MjM5OzQ4OzU7MjQ0bV0bWzM4OzU7MTAybXkbWzM4OzU7MjQ0OzQ4OzU7MjQzbX4bWzM4OzU7MjQyOzQ4OzU7MjQxbU0bWzM4OzU7MjM4OzQ4OzU7MjM5bTobWzBtChtbMzg7NTs4OzQ4OzU7MjM4bSwbWzM4OzU7MjQxOzQ4OzU7NTltYBtbMzg7NTsyNDM7NDg7NTsyNDJtIhtbMzg7NTsxMDI7NDg7NTsyNDRtIhtbMzg7NTsyMzY7NDg7NTsyNDJtfBtbNDg7NTsyNDZtIBtbMzg7NTsyNDI7NDg7NTsxMDJtahtbMzg7NTsyMzk7NDg7NTsyNDBtOhtbMzg7NTsyMzY7NDg7NTsyMzRtUBtbMzg7NTsyMzM7NDg7NTsxNm0vG1szODs1OzIzNjs0ODs1OzIzN21MG1szODs1OzE2OzQ4OzU7MjMzbWAbWzM4OzU7MTgyOzQ4OzU7MTM5bTobWzM4OzU7MjQ0OzQ4OzU7MjQxbU0bWzQ4OzU7NjBtIBtbMzg7NTsyNG0uG1szODs1OzYwOzQ4OzU7NjZtXxtbMzg7NTsxMDM7NDg7NTs2MG1dG1szODs1OzI0MG06G1szODs1OzI0NDs0ODs1OzI0M215G1s0ODs1OzI0Nm1fG1szODs1OzIzODs0ODs1OzI0M21dG1szODs1OzI0NG1+G1szODs1OzI0MTs0ODs1OzI0Mm15G1szODs1OzU5OzQ4OzU7MjQwbUYbWzM4OzU7ODs0ODs1OzIzOG1xG1swbQobWzM4OzU7MjMzOzQ4OzU7MjM2bSwbWzM4OzU7MjQwOzQ4OzU7MjM5bWAbWzM4OzU7MjM5OzQ4OzU7NTltXxtbMzg7NTsyNDE7NDg7NTsyNDJtTBtbMzg7NTsyMzc7NDg7NTsyNDFtMRtbMzg7NTsyNDQ7NDg7NTsxMDJteRtbMzg7NTsyNDE7NDg7NTsyNDBtTRtbMzg7NTsyMzg7NDg7NTsyMzdtfhtbMzg7NTsyMzQ7NDg7NTsyMzJtRhtbNDg7NTsxNm1eG1szODs1OzIzODs0ODs1OzIzN21gG1s0ODs1OzE2bSAbWzM4OzU7MjM0OzQ4OzU7NTltTBtbMzg7NTsyNDA7NDg7NTsxMzhtYBtbMzg7NTsyNDQ7NDg7NTsyMzltWRtbMzg7NTsyMzk7NDg7NTsyMzhtfhtbNDg7NTs2bXkbWzM4OzU7NjY7NDg7NTs2MG0iG1s0ODs1OzIzOW0gG1szODs1OzEwMjs0ODs1OzU5bWAbWzQ4OzU7MjQ0bSAbWzM4OzU7MjM2OzQ4OzU7NTltaRtbMzg7NTsyNDM7NDg7NTsyNDFtfhtbMzg7NTsyMzk7NDg7NTsyNDBtXxtbNDg7NTsyMzhtfhtbMzg7NTsyMzU7NDg7NTsyMzdtXxtbMG0KG1szODs1OzIzNTs0ODs1OzIzMm1gG1szODs1OzIzODs0ODs1OzIzNm1gG1szODs1OzIzNzs0ODs1OzIzOG1MG1szODs1OzIzOTs0ODs1OzI0MG15G1szODs1OzIzNDs0ODs1OzIzOG0xG1szODs1OzI0Mzs0ODs1OzI0MW1gG1szODs1OzIzNzs0ODs1OzIzNW1+G1szODs1OzIzNjs0ODs1OzIzM21eG1s0ODs1OzE2bSAbWzM4OzU7MjMzbX4bWzQ4OzU7MjM1bUwbWzQ4OzU7MjMybX4bWzM4OzU7MTZtOhtbMzg7NTs1OTs0ODs1OzEwMm0sG1szODs1OzYwOzQ4OzU7MjM4bSwbWzM4OzU7MjM5OzQ4OzU7OG0uG1szODs1OzIzODs0ODs1OzIzN20iG1szODs1OzIzOTs0ODs1OzhtfhtbMzg7NTsyMzg7NDg7NTsyMzdtRhtbMzg7NTsyMzc7NDg7NTsyMzZtIhtbNDg7NTs1OW0sG1szODs1OzIzNTs0ODs1OzIzOG1sG1szODs1OzIzODs0ODs1OzI0MG1fG1szODs1OzIzOTs0ODs1OzIzN21+G1szODs1OzIzMzs0ODs1OzIzNm15G1szODs1OzIzNTs0ODs1OzIzMm1+G1swbQobWzdtG1szODs1OzE2bSAbWzBtG1szODs1OzIzNDs0ODs1OzIzMm1gG1szODs1OzIzNjs0ODs1OzIzM21+G1szODs1OzIzNDs0ODs1OzIzN21fG1szODs1OzIzMzs0ODs1OzIzNm1KG1szODs1OzIzNTs0ODs1OzIzN211G1szODs1OzIzMzs0ODs1OzE2bWAgICAbWzQ4OzU7MjMybSIbWzQ4OzU7MTZtICAbWzM4OzU7MjM5OzQ4OzU7MjM1bSIbWzQ4OzU7NjBtYBtbMzg7NTsyNDQ7NDg7NTsyMzVtYBtbMzg7NTsyNDI7NDg7NTsyMzZtLBtbMzg7NTsxNjs0ODs1OzIzNW1fG1szODs1OzIzMm1fG1szODs1OzIzNTs0ODs1OzIzMm1+G1szODs1OzIzNzs0ODs1OzIzNG0iG1szODs1OzIzNTs0ODs1OzIzNm1eeRtbMzg7NTsyMzY7NDg7NTsyMzJtfhtbNDg7NTsxNm0gIBtbMG0K"

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
        curl -s http://localhost:4444/health
        ;;
    identity)
        curl -s http://localhost:4444/identity
        ;;
    init)
        echo "Initializing identity..."
        result=$(curl -s -X POST http://localhost:4444/identity/init)
        if echo "$result" | grep -q '"ok":true'; then
            echo "Identity initialized successfully!"
            echo "$result"
        else
            echo "$result"
            exit 1
        fi
        ;;
    pair)
        echo "Starting pairing..."
        result=$(curl -s -X POST http://localhost:4444/api/pairing/start)

        if echo "$result" | grep -q '"ok":false'; then
            echo "Pairing failed:"
            echo "$result"
            exit 1
        fi

        code=$(echo "$result" | grep -o '"confirm_code":"[^"]*"' | sed 's/"confirm_code":"//;s/"//')
        url=$(echo "$result" | grep -o '"pairing_url":"[^"]*"' | sed 's/"pairing_url":"//;s/"//')

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
            status=$(echo "$status_result" | grep -o '"status":"[^"]*"' | sed 's/"status":"//;s/"//')

            case "$status" in
                paired)
                    echo ""
                    echo "✓ Paired successfully!"
                    echo ""
                    curl -s http://localhost:4444/identity
                    exit 0
                    ;;
                failed|expired|idle)
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
        echo "  init      Initialize identity (required before pairing)"
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
# Identity Initialization
# -----------------------------------------------------------------------------

init_identity() {
    section "Initializing Identity"

    info "Creating agent identity..."
    local result
    result=$(curl -s -X POST http://localhost:4444/identity/init)

    if echo "$result" | grep -q '"ok":true'; then
        local mri
        mri=$(echo "$result" | grep -o '"mri":"[^"]*"' | cut -d'"' -f4)
        ok "Identity created: ${mri:-unknown}"
    elif echo "$result" | grep -q 'already_initialized'; then
        ok "Identity already exists"
    else
        error "Failed to initialize identity:"
        echo "$result"
        warn "Continuing anyway..."
    fi
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
        echo "$result"
        echo ""
        warn "You can pair later with: hecate pair"
        return 1
    fi

    # Extract values without jq (grep + sed)
    local code url
    code=$(echo "$result" | grep -o '"confirm_code":"[^"]*"' | sed 's/"confirm_code":"//;s/"//')
    url=$(echo "$result" | grep -o '"pairing_url":"[^"]*"' | sed 's/"pairing_url":"//;s/"//')
    
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
        status=$(echo "$status_result" | grep -o '"status":"[^"]*"' | sed 's/"status":"//;s/"//')
        
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
        section "Configuring PATH"

        # Determine shell profile
        local shell_profile=""
        if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
            shell_profile="$HOME/.zshrc"
        elif [ -f "$HOME/.bashrc" ]; then
            shell_profile="$HOME/.bashrc"
        elif [ -f "$HOME/.profile" ]; then
            shell_profile="$HOME/.profile"
        fi

        local path_line="export PATH=\"\$PATH:$BIN_DIR\""

        if [ -n "$shell_profile" ]; then
            # Check if already in profile (not just current PATH)
            if ! grep -q "$BIN_DIR" "$shell_profile" 2>/dev/null; then
                echo "" >> "$shell_profile"
                echo "# Hecate CLI" >> "$shell_profile"
                echo "$path_line" >> "$shell_profile"
                ok "Added $BIN_DIR to $shell_profile"

                # Source it for current session
                export PATH="$PATH:$BIN_DIR"
                ok "PATH updated for current session"
            else
                ok "$BIN_DIR already in $shell_profile"
                # Just export for current session
                export PATH="$PATH:$BIN_DIR"
            fi
        else
            warn "Could not detect shell profile"
            echo ""
            echo "Add this to your shell profile manually:"
            echo -e "  ${BOLD}${path_line}${NC}"
            echo ""
            # Still export for current session
            export PATH="$PATH:$BIN_DIR"
        fi
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
        identity=$(curl -s http://localhost:4444/identity 2>/dev/null)
        if [ -n "$identity" ]; then
            local mri org_identity
            mri=$(echo "$identity" | grep -o '"mri":"[^"]*"' | sed 's/"mri":"//;s/"//')
            org_identity=$(echo "$identity" | grep -o '"org_identity":"[^"]*"' | sed 's/"org_identity":"//;s/"//')
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
    init_identity

    # Run pairing (optional - don't fail install if pairing fails)
    if run_pairing; then
        PAIRING_SUCCESS=true
    else
        PAIRING_SUCCESS=false
    fi
    
    show_summary
}

main "$@"
