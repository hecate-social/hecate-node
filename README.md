# Hecate Node

One-command installer for the complete Hecate stack with intelligent hardware detection and role-based setup.

## Quick Install

```bash
curl -fsSL https://macula.io/hecate/install.sh | bash
```

## Node Roles

The installer lets you select one or more roles for your node:

| Role | What It Adds | Use Case |
|------|--------------|----------|
| **Workstation** | TUI + Claude Skills | Development and testing |
| **Services** | Network-exposed API | Hosting capabilities |
| **AI** | Ollama + models | Serving AI to network |

**Roles can be combined!** For example, a powerful machine could be both an AI server AND a development workstation.

### Interactive Selection

```
What will this node be used for?
You can select multiple roles by entering numbers separated by spaces

  1) Developer Workstation
     TUI + Claude Code skills for writing agents

  2) Services Host
     Host capabilities on the mesh (API exposed to network)

  3) AI Server
     Run Ollama and serve AI models to the network

  4) All of the above
     Full stack: development + services + AI

  Enter choices (e.g., 1 3 or 4):
```

### Example Configurations

**Developer Workstation** - For writing and testing agents:
```bash
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=workstation
```

**Services Node** - Headless server hosting capabilities:
```bash
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=services
```

**AI Server** - Dedicated AI model server:
```bash
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=ai
```

**AI + Workstation** - Dev machine that also serves AI:
```bash
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=ai,workstation
```

**Services + AI** - Server that hosts capabilities AND serves AI:
```bash
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=services,ai
```

**Full Stack** - Everything:
```bash
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=full
```

## Features

### Intelligent Hardware Detection

The installer automatically detects and displays:
- **RAM** - Recommends appropriate model size
- **CPU cores** - Suggests role based on capacity
- **AVX2 support** - Optimizes inference performance
- **GPU** - Enables acceleration (NVIDIA, AMD, Apple Silicon)
- **Local IP** - For network configuration

### AI Node Discovery

When setting up a workstation, the installer:
1. Scans your local network for existing AI nodes
2. Tests connectivity to discovered servers
3. Lists available models on the AI node
4. Configures automatic connection

### Clear Sudo Explanations

When sudo is needed (Ollama install, systemd service), the installer:
1. Explains exactly what needs sudo and why
2. Shows the exact commands/files that will be created
3. Asks for explicit confirmation before proceeding

## Installation Options

```bash
# Interactive (recommended)
curl -fsSL https://macula.io/hecate/install.sh | bash

# Single role
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=workstation

# Combined roles
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=ai,workstation
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --role=services,ai

# Skip AI setup
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --no-ai

# Non-interactive (CI/automation)
curl -fsSL https://macula.io/hecate/install.sh | bash -s -- --headless --role=services
```

## What Gets Installed

Components are installed based on which roles you select:

| Component | Workstation | Services | AI | All |
|-----------|:-----------:|:--------:|:--:|:---:|
| Hecate Daemon | ✅ | ✅ | ✅ | ✅ |
| Hecate TUI | ✅ | - | - | ✅ |
| Claude Skills | ✅ | - | - | ✅ |
| Network API | - | ✅ | ✅ | ✅ |
| Ollama | optional | - | ✅ | ✅ |
| Systemd Service | - | ✅ | ✅ | - |

**Combined roles add up.** For example, `--role=ai,workstation` gets: TUI + Skills + Ollama + Network API.

## Installation Paths

| Path | Contents |
|------|----------|
| `~/.local/bin/hecate` | Daemon binary |
| `~/.local/bin/hecate-tui` | TUI binary |
| `~/.hecate/` | Data directory |
| `~/.hecate/config/hecate.toml` | Configuration |
| `~/.claude/HECATE_SKILLS.md` | Claude Code skills |

## Configuration

The installer creates `~/.hecate/config/hecate.toml` with role-appropriate defaults:

```toml
# Role: workstation
[daemon]
api_port = 4444
api_host = "127.0.0.1"  # "0.0.0.0" for services/AI nodes

[mesh]
bootstrap = ["boot.macula.io:4433"]
realm = "io.macula"

[logging]
level = "info"

[ai]
provider = "ollama"
endpoint = "http://192.168.1.100:11434"  # Your AI node
model = "deepseek-coder:6.7b"
```

## Network Setup Example

A typical multi-node setup:

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Network                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐ │
│   │   AI Node    │    │   Services   │    │  Workstation │ │
│   │  (beam01)    │    │   (beam02)   │    │  (laptop)    │ │
│   │              │    │              │    │              │ │
│   │ Ollama:11434 │◄───│  daemon:4444 │    │ daemon:4444  │ │
│   │ codellama:7b │    │  capabilities│    │ TUI + skills │ │
│   │              │◄───│              │    │              │ │
│   └──────────────┘    └──────────────┘    └──────┬───────┘ │
│          ▲                                       │          │
│          │                                       │          │
│          └───────────────────────────────────────┘          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HECATE_VERSION` | Version to install | `latest` |
| `HECATE_INSTALL_DIR` | Data directory | `~/.hecate` |
| `HECATE_BIN_DIR` | Binary directory | `~/.local/bin` |

## Sudo Requirements

The installer only requires sudo for:

| Component | Requires Sudo | Reason |
|-----------|:-------------:|--------|
| Ollama install | ✅ | Binary in `/usr/local/bin`, systemd service |
| Systemd service | ✅ | Service file in `/etc/systemd/system/` |
| Network config | ✅ | Ollama systemd override for `0.0.0.0` |

The installer clearly explains each sudo requirement and asks for confirmation.

## Uninstall

```bash
curl -fsSL https://macula.io/hecate/uninstall.sh | bash
```

Or manually:

```bash
rm ~/.local/bin/hecate ~/.local/bin/hecate-tui
rm -rf ~/.hecate
rm ~/.claude/HECATE_SKILLS.md
sudo systemctl disable hecate 2>/dev/null
sudo rm /etc/systemd/system/hecate.service 2>/dev/null
```

## Requirements

- Linux (x86_64, arm64) or macOS (arm64, x86_64)
- curl, tar
- Terminal with 256 color support (for TUI)
- For AI: 4GB+ RAM (8GB+ recommended)

## Components

- [hecate-daemon](https://github.com/hecate-social/hecate-daemon) - Erlang mesh daemon
- [hecate-tui](https://github.com/hecate-social/hecate-tui) - Go terminal UI

## License

Apache 2.0 - See [LICENSE](LICENSE)

## Support

- [Issues](https://github.com/hecate-social/hecate-node/issues)
- [Buy Me a Coffee](https://buymeacoffee.com/rlefever)
