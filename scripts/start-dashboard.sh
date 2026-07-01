#!/usr/bin/env bash
# start-dashboard.sh — generate a fresh snapshot and launch Mission Control.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Generating status snapshot..."
./scripts/status-snapshot.sh
echo "Starting Mission Control at http://localhost:3001"
echo "Access from LAN at http://$(hostname -I | awk '{print $1}'):3001"
cd server && exec python3 serve.py
