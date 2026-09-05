#!/usr/bin/env bash
# Install the ollama-meter proxy on the box that runs Ollama, from here.
#
#   ./nano/install.sh [ssh-host]      (default: nano)
#
# Needs passwordless sudo on the target. Idempotent; re-run to update.
# Rollback on the target:
#   sudo systemctl disable --now ollama-meter
#   sudo rm /etc/systemd/system/ollama-meter.service /etc/systemd/system/ollama.service.d/zz-burnbar.conf \
#           /etc/sysctl.d/90-burnbar-ollama.conf
#   sudo sysctl -w vm.min_free_kbytes=45056; sudo systemctl daemon-reload && sudo systemctl restart ollama

set -euo pipefail
host="${1:-nano}"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

scp -q "$here/ollama-meter.py" "$here/ollama-meter.service" "$here/ollama.service.d-burnbar.conf" \
       "$here/sysctl-burnbar-ollama.conf" "$host:/tmp/"
ssh "$host" 'set -e
  sudo -n install -d -m 755 /usr/local/lib/burnbar /etc/systemd/system/ollama.service.d
  sudo -n install -m 644 /tmp/ollama-meter.py /usr/local/lib/burnbar/ollama-meter.py
  sudo -n install -m 644 /tmp/ollama-meter.service /etc/systemd/system/ollama-meter.service
  sudo -n install -m 644 /tmp/ollama.service.d-burnbar.conf /etc/systemd/system/ollama.service.d/zz-burnbar.conf
  sudo -n install -m 644 /tmp/sysctl-burnbar-ollama.conf /etc/sysctl.d/90-burnbar-ollama.conf
  rm -f /tmp/ollama-meter.py /tmp/ollama-meter.service /tmp/ollama.service.d-burnbar.conf /tmp/sysctl-burnbar-ollama.conf
  sudo -n sysctl -q -p /etc/sysctl.d/90-burnbar-ollama.conf
  sudo -n systemctl daemon-reload
  sudo -n systemctl restart ollama
  sudo -n systemctl enable --now ollama-meter
  sudo -n systemctl restart ollama-meter
  sleep 2
  systemctl is-active ollama ollama-meter
  ss -tln | grep -E ":1143[45] " || true'
echo "meter journal: ssh $host journalctl -u ollama-meter -f"
