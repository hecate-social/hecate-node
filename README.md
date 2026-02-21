<div align="center">
  <img src="assets/avatar-terminal.jpg" alt="Hecate" width="200"/>
  <h1>Hecate Node</h1>
  <p><em>One-command installer for the complete Hecate stack with intelligent hardware detection and role-based setup.</em></p>

  [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/rgfaber)
  [![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
</div>

---

## Two Ways to Deploy

| Method | Use Case | How |
|--------|----------|-----|
| **NixOS Flake** | Bootable USB/ISO/SD card | `nix build .#iso` |
| **install.sh** | Existing Linux machine | `curl -fsSL https://hecate.io/install.sh \| bash` |

Both produce the same result: podman + reconciler + gitops + hecate-daemon.

## Quick Install (Existing Machine)

```bash
curl -fsSL https://hecate.io/install.sh | bash
```

## NixOS Flake (Bootable Media)

Build a single bootable USB/ISO image. The firstboot wizard handles role selection on first boot.

```bash
# Build the ISO
nix build .#iso
sudo dd if=result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress

# Or download a pre-built ISO from GitHub releases

# Run VM integration tests
nix flake check
```

### NixOS Configuration

For permanent installations, reference the flake in your NixOS config:

```nix
# /etc/nixos/flake.nix
{
  inputs.hecate-node.url = "github:hecate-social/hecate-node";
  outputs = { self, nixpkgs, hecate-node }: {
    nixosConfigurations.mynode = nixpkgs.lib.nixosSystem {
      modules = [
        hecate-node.nixosConfigurations.standalone.config
        ./hardware-configuration.nix
        {
          networking.hostName = "my-hecate-node";
          services.hecate.daemon.version = "0.8.1";
          services.hecate.ollama.models = [ "llama3.2" "deepseek-r1" ];
        }
      ];
    };
  };
}
```

### Flake Structure

```
flake.nix                       # Entry point + build targets
configurations/
  base.nix                      # Common: podman, mDNS, firewall, user
  standalone.nix                # Base + daemon + Ollama
  cluster.nix                   # Base + daemon + BEAM clustering
  inference.nix                 # Ollama only (no daemon)
  workstation.nix               # Standalone + desktop app
modules/                        # Composable NixOS modules
  hecate-{directories,reconciler,gitops,firewall,...}.nix
hardware/                       # Hardware-specific profiles
  beam-node.nix                 # Celeron J4105 (beam00-03)
  generic-x86.nix               # Any x86_64
  generic-arm64.nix             # RPi4 / ARM64
packages/                       # Nix derivations
  hecate-reconciler.nix         # Reconciler bash script
  hecate-cli.nix                # CLI binary
tests/                          # NixOS VM integration tests
  boot-test.nix                 # Boot + reconciler starts
  plugin-test.nix               # Drop .container -> service starts
  firstboot-test.nix            # Firstboot wizard flow
firstboot/                      # Firstboot wizard assets
  firstboot.sh                  # Pairing flow script
  index.html                    # Responsive pairing web UI
```

## Architecture

Hecate runs as **rootless Podman containers** managed by **systemd user services**:

```
~/.hecate/gitops/           ← Source of truth (Quadlet .container files)
    ↓ reconciler watches
~/.config/containers/systemd/  ← Podman Quadlet picks up symlinks
    ↓ systemctl --user daemon-reload
systemd user services          ← Containers run as user services
```

No Kubernetes. No root. No cluster overhead.

## Node Roles

| Role | What It Does | Use Case |
|------|-------------|----------|
| **Standalone** | Full stack on one machine | Laptop, desktop, single server |
| **Cluster** | Joins BEAM cluster with peers | Multi-node home lab |
| **Inference** | Ollama-only, no daemon | Dedicated GPU server |

### Example Configurations

**Standalone workstation** (default):
```bash
curl -fsSL https://hecate.io/install.sh | bash
```

**Headless server** (no desktop app):
```bash
curl -fsSL https://hecate.io/install.sh | bash -s -- --daemon-only
```

**Cluster node** (joins BEAM cluster):
```bash
curl -fsSL https://hecate.io/install.sh | bash
# Select "Cluster" role, provide cookie and peer addresses
```

**Inference node** (GPU server):
```bash
curl -fsSL https://hecate.io/install.sh | bash
# Select "Inference" role
```

## What Gets Installed

| Component | Standalone | Cluster | Inference |
|-----------|:---------:|:-------:|:---------:|
| Podman | yes | yes | - |
| Hecate Daemon | yes | yes | - |
| Reconciler | yes | yes | - |
| Hecate Web | optional | optional | - |
| Ollama | optional | optional | yes |

## Installation Flow

1. Detect hardware (RAM, CPU, GPU, storage)
2. Select node role (standalone / cluster / inference)
3. Select features (desktop app, Ollama)
4. Install podman + enable user lingering
5. Create `~/.hecate/` directory layout
6. Seed gitops with Quadlet files from hecate-gitops
7. Install reconciler (watches gitops, manages systemd units)
8. Deploy hecate-daemon via Podman Quadlet
9. Optionally install Hecate Web + Ollama
10. Install CLI wrapper

## Installation Paths

| Path | Contents |
|------|----------|
| `~/.hecate/` | Data root |
| `~/.hecate/hecate-daemon/` | Daemon data (sqlite, sockets, etc.) |
| `~/.hecate/gitops/system/` | Core Quadlet files (always present) |
| `~/.hecate/gitops/apps/` | Plugin Quadlet files (installed on demand) |
| `~/.hecate/config/` | Node-specific configuration |
| `~/.hecate/secrets/` | LLM API keys, age keypair |
| `~/.local/bin/hecate` | CLI wrapper |
| `~/.local/bin/hecate-reconciler` | GitOps reconciler |
| `~/.local/bin/hecate-web` | Desktop app (if installed) |
| `~/.config/containers/systemd/` | Podman Quadlet units (symlinks) |
| `~/.config/systemd/user/` | Reconciler systemd service |

## Managing Services

```bash
# CLI wrapper
hecate status                    # Show all hecate services
hecate logs                      # View daemon logs
hecate health                    # Check daemon health
hecate start                     # Start daemon
hecate stop                      # Stop daemon
hecate restart                   # Restart daemon
hecate update                    # Pull latest container images
hecate reconcile                 # Manual reconciliation

# Direct systemd
systemctl --user list-units 'hecate-*'
systemctl --user status hecate-daemon
journalctl --user -u hecate-daemon -f

# Reconciler
hecate-reconciler --status       # Show desired vs actual state
hecate-reconciler --once         # One-shot reconciliation
```

## Installing Plugins

Plugins are Podman Quadlet `.container` files. To install a plugin:

```bash
# Copy plugin container files to gitops/apps/
cp hecate-traderd.container ~/.hecate/gitops/apps/
cp hecate-traderw.container ~/.hecate/gitops/apps/

# The reconciler picks them up automatically
# Or trigger manually:
hecate reconcile
```

### Available Plugins

| Plugin | Daemon | Frontend | Description |
|--------|--------|----------|-------------|
| Trader | `hecate-traderd` | `hecate-traderw` (:5174) | Trading agent |
| Martha | `hecate-marthad` | `hecate-marthaw` (:5175) | AI agent |

## Network Setup Example

```
┌─────────────────────────────────────────────────────────┐
│                     Your Network                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│   ┌──────────────┐    ┌──────────────┐                  │
│   │  Inference    │    │  Workstation │                  │
│   │  (beam01)     │    │  (laptop)    │                  │
│   │              │    │              │                  │
│   │ Ollama:11434 │◄───│ daemon       │                  │
│   │ llama3.2     │    │ hecate-web   │                  │
│   │              │    │ ollama       │                  │
│   └──────────────┘    └──────────────┘                  │
│          ▲                                               │
│          │          ┌──────────────┐                     │
│          │          │  Cluster     │                     │
│          └──────────│  (beam02)    │                     │
│                     │ daemon       │                     │
│                     │ plugins      │                     │
│                     └──────────────┘                     │
│                                                          │
└─────────────────────────────────────────────────────────┘
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
| Podman install | yes | Package manager |
| Ollama install | yes | Binary in `/usr/local/bin`, systemd service |
| Firewall rules | yes | System firewall configuration |
| User lingering | yes | `loginctl enable-linger` |

All hecate services run as **user-level systemd services** — no root needed at runtime.

## Uninstall

```bash
curl -fsSL https://hecate.io/uninstall.sh | bash
```

Or manually:

```bash
# Stop services
systemctl --user stop hecate-reconciler hecate-daemon

# Remove Quadlet links
rm ~/.config/containers/systemd/hecate-*.container
systemctl --user daemon-reload

# Remove binaries
rm ~/.local/bin/hecate ~/.local/bin/hecate-reconciler ~/.local/bin/hecate-web

# Remove data
rm -rf ~/.hecate
```

## Requirements

- Linux (x86_64, arm64) or macOS (arm64, x86_64)
- curl, git
- systemd (for service management)
- For desktop app: webkit2gtk-4.1
- For AI: 4GB+ RAM (8GB+ recommended)

## Components

- [hecate-daemon](https://github.com/hecate-social/hecate-daemon) - Erlang mesh daemon
- [hecate-web](https://github.com/hecate-social/hecate-web) - Tauri desktop app
- [hecate-gitops](https://github.com/hecate-social/hecate-gitops) - Quadlet templates + reconciler

## License

MIT - See [LICENSE](LICENSE)

## Support

- [Issues](https://github.com/hecate-social/hecate-node/issues)
- [Buy Me a Coffee](https://buymeacoffee.com/rgfaber)
