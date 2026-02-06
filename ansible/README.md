# Hecate Ansible Deployment

Deploy Hecate across multiple nodes with a single command.

## Quick Start

```bash
# 1. Install Ansible
pip install ansible kubernetes

# 2. Copy and customize inventory
cp inventory.example.ini inventory.ini
vim inventory.ini

# 3. Deploy everything
ansible-playbook -i inventory.ini hecate.yml
```

## Inventory Structure

```ini
[server]
beam00.lab          # k3s control plane (exactly one)

[agents]
beam01.lab          # k3s workers (zero or more)
beam02.lab
beam03.lab

[inference]
host00.lab          # Ollama-only nodes (zero or more)
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `hecate_realm` | `io.macula` | Macula mesh realm |
| `hecate_bootstrap` | `https://boot.macula.io:443` | Bootstrap server |
| `ollama_host` | `http://localhost:11434` | Ollama URL for k3s nodes |
| `ollama_models` | `['llama3.2']` | Models to pull on inference nodes |
| `hecate_image` | `ghcr.io/hecate-social/hecate-daemon:main` | Daemon image |

## Usage Examples

### Deploy entire cluster
```bash
ansible-playbook -i inventory.ini hecate.yml
```

### Deploy only server
```bash
ansible-playbook -i inventory.ini hecate.yml --tags server
```

### Deploy only agents
```bash
ansible-playbook -i inventory.ini hecate.yml --tags agents
```

### Deploy only inference nodes
```bash
ansible-playbook -i inventory.ini hecate.yml --tags inference
```

### Skip firewall configuration
```bash
ansible-playbook -i inventory.ini hecate.yml --skip-tags firewall
```

### Check cluster status
```bash
ansible-playbook -i inventory.ini hecate.yml --tags status
```

### Dry run (check mode)
```bash
ansible-playbook -i inventory.ini hecate.yml --check
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Ansible Control Node                      │
│                  (your workstation)                          │
└───────────────────────┬─────────────────────────────────────┘
                        │ SSH
        ┌───────────────┼───────────────┬───────────────┐
        ▼               ▼               ▼               ▼
┌───────────┐   ┌───────────┐   ┌───────────┐   ┌───────────┐
│  Server   │   │   Agent   │   │   Agent   │   │ Inference │
│  beam00   │◄──│  beam01   │   │  beam02   │   │  host00   │
│           │   │           │   │           │   │           │
│ k3s ctrl  │   │ k3s work  │   │ k3s work  │   │  Ollama   │
│ FluxCD    │   │           │   │           │   │   only    │
│ Hecate    │   │           │   │           │   │           │
└───────────┘   └───────────┘   └───────────┘   └───────────┘
```

## Roles

| Role | Description |
|------|-------------|
| `common` | Dependencies, firewall, directories |
| `k3s-server` | k3s control plane, kubeconfig, join script |
| `k3s-agent` | Join existing cluster as worker |
| `flux` | FluxCD GitOps controller |
| `inference` | Ollama installation and configuration |
| `hecate` | Daemon deployment to k8s |

## Firewall Ports

### Server
- `6443/tcp` - k3s API
- `4433/udp` - Macula mesh
- `4369/tcp` - EPMD (Erlang)
- `9100/tcp` - Erlang distribution
- `8472/udp` - Flannel VXLAN
- `10250/tcp` - Kubelet

### Agent
- `4433/udp` - Macula mesh
- `4369/tcp` - EPMD (Erlang)
- `9100/tcp` - Erlang distribution
- `8472/udp` - Flannel VXLAN
- `10250/tcp` - Kubelet

### Inference
- `11434/tcp` - Ollama API

## Troubleshooting

### SSH connection issues
```bash
# Test connectivity
ansible -i inventory.ini all -m ping
```

### k3s agent won't join
```bash
# Check server firewall
ansible -i inventory.ini server -a "ufw status"

# Check agent logs
ansible -i inventory.ini agents -a "journalctl -u k3s-agent -n 20"
```

### View cluster status
```bash
ansible -i inventory.ini server -a "kubectl get nodes"
ansible -i inventory.ini server -a "kubectl get pods -A"
```
