#!/usr/bin/env bash
# Restart a dead Chromium for an existing agent session without touching other host processes.
# Usage: agent-sandbox/scripts/restart-chrome.sh <name>
set -euo pipefail

NAME="${1:?usage: restart-chrome.sh <name>}"
SESSION_DIR="$HOME/.local/share/agent-sessions/$NAME"
ENV_FILE="$SESSION_DIR/agent.env"
PIDS_FILE="$SESSION_DIR/pids"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: no session found for '$NAME' (missing $ENV_FILE)" >&2; exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

CHROMIUM=$(find "$HOME/.cache/ms-playwright" -name "chrome" -path "*/chrome-linux/*" 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$CHROMIUM" ]; then
    echo "ERROR: playwright chromium not found; run new-agent.sh once to install it" >&2; exit 1
fi

# Kill only the old Chromium PID — do NOT fuser-kill the port (socat is also on it)
XVFB_PID="" X11VNC_PID="" NOVNC_PID="" SOCAT_PID=""
if [ -f "$PIDS_FILE" ]; then
    read -r XVFB_PID OLD_CHROMIUM X11VNC_PID NOVNC_PID SOCAT_PID < "$PIDS_FILE"
    kill "$OLD_CHROMIUM" 2>/dev/null || true
fi

echo "==> relaunching Chromium (CDP :${CDP_PORT}, display :${DISPLAY_NUM})"
DISPLAY=":${DISPLAY_NUM}" "$CHROMIUM" \
    --user-data-dir="$SESSION_DIR/browser-profile" \
    --remote-debugging-port="${CDP_PORT}" \
    --no-first-run \
    --no-default-browser-check \
    &>/tmp/agent-chromium-"$NAME".log &
CHROMIUM_PID=$!

# Poll until CDP responds (up to 15 s)
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${CDP_PORT}/json/version" &>/dev/null; then break; fi
    if ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
        echo "ERROR: Chromium exited immediately. Log:" >&2
        cat /tmp/agent-chromium-"$NAME".log >&2
        exit 1
    fi
    sleep 0.5
done
if ! curl -sf "http://127.0.0.1:${CDP_PORT}/json/version" &>/dev/null; then
    echo "ERROR: CDP did not respond after 15 s on port ${CDP_PORT}" >&2; exit 1
fi

echo "    Chromium ready (PID $CHROMIUM_PID)"

# Restart socat bridge if it died
if [ -n "$SOCAT_PID" ] && ! kill -0 "$SOCAT_PID" 2>/dev/null; then
    echo "==> socat bridge was dead, restarting (10.95.99.1:${CDP_PORT} -> 127.0.0.1:${CDP_PORT})"
    socat TCP-LISTEN:"${CDP_PORT}",bind=10.95.99.1,fork,reuseaddr \
        TCP:127.0.0.1:"${CDP_PORT}" \
        &>/tmp/agent-socat-"$NAME".log &
    SOCAT_PID=$!
    sleep 0.3
    kill -0 "$SOCAT_PID" 2>/dev/null || { echo "ERROR: socat failed"; cat /tmp/agent-socat-"$NAME".log >&2; exit 1; }
fi

# Update pids file
echo "${XVFB_PID} $CHROMIUM_PID ${X11VNC_PID} ${NOVNC_PID} ${SOCAT_PID}" > "$PIDS_FILE"

HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1 || hostname -I | awk '{print $1}')
echo "Browser (noVNC): http://${HOST_IP}:${NOVNC_PORT}/vnc.html"
