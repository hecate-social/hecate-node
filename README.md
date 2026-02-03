# Hecate Node

One-command installer for the complete Hecate stack with intelligent hardware detection and optional AI model setup.

## Quick Install

```bash
curl -fsSL https://hecate.social/install.sh | bash
```

## What Gets Installed

| Component | Description |
|-----------|-------------|
| **Hecate Daemon** | Erlang mesh network daemon (port 4444) |
| **Hecate TUI** | Terminal UI for monitoring and management |
| **Hecate Skills** | Claude Code integration for mesh operations |
| **AI Model** | Optional local code generation model (Ollama) |

## Features

### Intelligent Hardware Detection

The installer automatically detects:
- **RAM** - Recommends appropriate model size
- **CPU cores** - Configures concurrency
- **AVX2 support** - Optimizes inference performance
- **GPU** - Enables acceleration (NVIDIA, AMD, Apple Silicon)

### AI Model Options

The installer offers three choices:

1. **Local Ollama** - Install Ollama and a recommended code model
2. **Remote Server** - Connect to an existing Ollama server on your network
3. **Skip** - No AI setup (can configure later)

Recommended models based on hardware:

| RAM | Recommended Model | Size |
|-----|------------------|------|
| 32GB+ with GPU | codellama:7b-code | ~4GB |
| 16GB+ | deepseek-coder:6.7b | ~4GB |
| 8GB+ | deepseek-coder:1.3b | ~1GB |
| 4GB+ | tinyllama | ~700MB |

## Installation Paths

| Path | Contents |
|------|----------|
| `~/.local/bin/hecate` | Daemon binary |
| `~/.local/bin/hecate-tui` | TUI binary |
| `~/.hecate/` | Data directory (config, logs, state) |
| `~/.hecate/config/hecate.toml` | Configuration file |
| `~/.claude/HECATE_SKILLS.md` | Claude Code skills |

## Installation Options

```bash
# Standard interactive install
curl -fsSL https://hecate.social/install.sh | bash

# Skip AI model setup
curl -fsSL https://hecate.social/install.sh | bash -s -- --no-ai

# Non-interactive (use defaults)
curl -fsSL https://hecate.social/install.sh | bash -s -- --headless

# Show help
curl -fsSL https://hecate.social/install.sh | bash -s -- --help
```

## Post-Install: Pairing

After installation, pair your node with the mesh:

```bash
# Start the daemon
hecate start

# Open the TUI
hecate-tui

# Run pairing (first time)
hecate-tui pair
```

## Configuration

Edit `~/.hecate/config/hecate.toml`:

```toml
[daemon]
api_port = 4444
api_host = "127.0.0.1"

[mesh]
bootstrap = ["boot.macula.io:4433"]
realm = "io.macula"

[logging]
level = "info"

# AI model (if configured)
[ai]
provider = "ollama"
endpoint = "http://localhost:11434"
model = "deepseek-coder:1.3b"
```

### Remote AI Server

To use a remote Ollama server instead of local:

```toml
[ai]
provider = "ollama"
endpoint = "http://192.168.1.100:11434"
model = "codellama:7b-code"
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HECATE_VERSION` | Version to install | `latest` |
| `HECATE_INSTALL_DIR` | Data directory | `~/.hecate` |
| `HECATE_BIN_DIR` | Binary directory | `~/.local/bin` |

## Sudo Requirements

The installer only requires sudo for one optional component:

**Ollama installation** (if selected):
- Installs binary to `/usr/local/bin/ollama`
- Creates systemd service for background operation

The installer clearly explains what sudo access is needed for and prompts for confirmation. You can skip Ollama and use a remote server instead.

## Manual Installation

If you prefer manual installation:

```bash
# 1. Download daemon (self-contained, includes Erlang runtime)
curl -fsSL https://github.com/hecate-social/hecate-daemon/releases/latest/download/hecate-daemon-linux-amd64 -o ~/.local/bin/hecate
chmod +x ~/.local/bin/hecate

# 2. Download TUI
curl -fsSL https://github.com/hecate-social/hecate-tui/releases/latest/download/hecate-tui-linux-amd64.tar.gz | tar xz -C ~/.local/bin

# 3. Download skills
mkdir -p ~/.claude
curl -fsSL https://raw.githubusercontent.com/hecate-social/hecate-node/main/SKILLS.md -o ~/.claude/HECATE_SKILLS.md

# 4. Create config
mkdir -p ~/.hecate/config
cat > ~/.hecate/config/hecate.toml << 'EOF'
[daemon]
api_port = 4444

[mesh]
bootstrap = ["boot.macula.io:4433"]
EOF
```

## Uninstall

```bash
curl -fsSL https://hecate.social/uninstall.sh | bash
```

Or manually:

```bash
rm ~/.local/bin/hecate ~/.local/bin/hecate-tui
rm -rf ~/.hecate
rm ~/.claude/HECATE_SKILLS.md
```

## Requirements

- Linux (x86_64, arm64) or macOS (arm64, x86_64)
- curl, tar
- Terminal with 256 color support (for TUI)
- 4GB+ RAM (for AI models, optional)

## Components

- [hecate-daemon](https://github.com/hecate-social/hecate-daemon) - Erlang mesh daemon
- [hecate-tui](https://github.com/hecate-social/hecate-tui) - Go terminal UI

## License

Apache 2.0 - See [LICENSE](LICENSE)

## Support

- [Issues](https://github.com/hecate-social/hecate-node/issues)
- [Buy Me a Coffee](https://buymeacoffee.com/rlefever)
