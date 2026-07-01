#!/usr/bin/env bash
# start-dashboard.sh — generate a fresh snapshot and launch Mission Control.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Generating status snapshot..."
./scripts/status-snapshot.sh
MCPORT="${MISSION_CONTROL_PORT:-4001}"
echo "Starting Mission Control at http://localhost:$MCPORT"
echo "Access from LAN at http://$(hostname -I | awk '{print $1}'):$MCPORT"
cd server && MISSION_CONTROL_PORT=$MCPORT exec python3 serve.py
