#!/bin/bash
# Join host00.lab (this machine) to the k3s cluster as an agent
#
# This script will prompt for sudo password since we're running locally.
#
# Usage:
#   ./join-host00.sh
#

set -euo pipefail

cd "$(dirname "$0")"

echo "Joining host00.lab to k3s cluster as an agent..."
echo "You will be prompted for the sudo password."
echo ""

# Run the full playbook targeting server (for facts) and host00 (for agent install)
# - server role gathers k3s_server_url and k3s_token from beam00
# - agents role uses those facts to join host00.lab
# - skip flux (not needed for just joining)
# - skip hecate deployment (can do that separately)
ansible-playbook -i inventory.ini hecate.yml \
    --limit 'beam00.lab,host00.lab' \
    --tags 'common,server,agents' \
    --skip-tags 'flux,hecate' \
    -K \
    -v

echo ""
echo "==> Verifying node joined..."
ssh rl@beam00.lab 'kubectl get nodes'
