#!/usr/bin/env bash
# Stop and delete a named agent session (container + host processes).
# Usage: agent-sandbox/scripts/teardown-agent.sh <name>
set -euo pipefail

NAME="${1:?usage: teardown-agent.sh <name>}"
CONTAINER="agent-$NAME"
SESSION_DIR="$HOME/.local/share/agent-sessions/$NAME"

echo "==> deleting $CONTAINER"
sg lxd -c "lxc delete --force $CONTAINER" 2>/dev/null || echo "    (container not found, continuing)"

if [ -f "$SESSION_DIR/pids" ]; then
    read -r XVFB_PID CHROMIUM_PID X11VNC_PID NOVNC_PID SOCAT_PID < "$SESSION_DIR/pids"
    echo "==> stopping host processes (Xvfb, Chromium, x11vnc, noVNC, socat)"
    for pid in "$XVFB_PID" "$CHROMIUM_PID" "$X11VNC_PID" "$NOVNC_PID" "$SOCAT_PID"; do
        kill "$pid" 2>/dev/null || true
    done
fi

if [ -f "$SESSION_DIR/agent.env" ]; then
    SLOT=$(grep '^SLOT=' "$SESSION_DIR/agent.env" | cut -d= -f2)
    rm -f "$HOME/.local/share/agent-sessions/.slot-$SLOT.lock"
fi

rm -rf "$SESSION_DIR"
echo "Done. Host workspace (if any) is preserved."
