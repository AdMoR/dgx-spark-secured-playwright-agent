#!/usr/bin/env bash
# Launch a new hybrid agent: Chromium on host (Xvfb + noVNC) + opencode in LXD container.
# Usage: agent-sandbox/scripts/new-agent.sh <name> [/host/path/to/workspace]
set -euo pipefail

NAME="${1:?usage: new-agent.sh <name> [/host/path/to/workspace]}"
WORKSPACE="${2:-}"
CONTAINER="agent-$NAME"
SESSION_BASE="$HOME/.local/share/agent-sessions"

if ! [[ "$NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "ERROR: name must be alphanumeric (hyphens allowed)" >&2; exit 1
fi

if sg lxd -c "lxc info $CONTAINER" &>/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER' already exists." >&2
    echo "  Stop it with: agent-sandbox/scripts/teardown-agent.sh $NAME" >&2
    exit 1
fi

for cmd in socat Xvfb x11vnc websockify; do
    command -v "$cmd" &>/dev/null || {
        echo "ERROR: $cmd not found. Run: sudo agent-sandbox/scripts/setup-host.sh" >&2; exit 1
    }
done
CHROMIUM=$(find "$HOME/.cache/ms-playwright" -name "chrome" -path "*/chrome-linux/*" 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$CHROMIUM" ]; then
    echo "==> playwright chromium not found — downloading (~100 MB, one time)"
    npx --yes playwright@latest install chromium
    CHROMIUM=$(find "$HOME/.cache/ms-playwright" -name "chrome" -path "*/chrome-linux/*" 2>/dev/null | sort -V | tail -1 || true)
fi
if [ -z "$CHROMIUM" ]; then
    echo "ERROR: playwright chromium install failed" >&2; exit 1
fi
echo "    chromium: $CHROMIUM"

# --- slot allocation (atomic via noclobber) ---
SLOT=""
mkdir -p "$SESSION_BASE"
for n in $(seq 0 19); do
    LOCK="$SESSION_BASE/.slot-$n.lock"
    if (set -C; echo "$NAME" > "$LOCK") 2>/dev/null; then
        SLOT="$n"
        break
    fi
done
if [ -z "$SLOT" ]; then
    echo "ERROR: no free slots (max 20 concurrent agents)" >&2; exit 1
fi

DISPLAY_NUM="$((10 + SLOT))"
VNC_PORT="$((5910 + SLOT))"
NOVNC_PORT="$((6080 + SLOT))"
CDP_PORT="$((9220 + SLOT))"

SESSION_DIR="$SESSION_BASE/$NAME"
mkdir -p "$SESSION_DIR/browser-profile"
printf 'AGENT_NAME=%s\nSLOT=%s\nDISPLAY_NUM=%s\nVNC_PORT=%s\nNOVNC_PORT=%s\nCDP_PORT=%s\n' \
    "$NAME" "$SLOT" "$DISPLAY_NUM" "$VNC_PORT" "$NOVNC_PORT" "$CDP_PORT" \
    > "$SESSION_DIR/agent.env"

cleanup() {
    rm -f "$SESSION_BASE/.slot-$SLOT.lock"
    rm -rf "$SESSION_DIR"
}

# --- Xvfb ---
echo "==> starting Xvfb :$DISPLAY_NUM"
Xvfb ":$DISPLAY_NUM" -screen 0 1280x900x24 -nolisten tcp \
    &>/tmp/agent-xvfb-$NAME.log &
XVFB_PID=$!
sleep 0.5
if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "ERROR: Xvfb failed. Log:"; cat /tmp/agent-xvfb-$NAME.log >&2
    cleanup; exit 1
fi

# --- Chromium ---
echo "==> launching Chromium (CDP :$CDP_PORT, display :$DISPLAY_NUM)"
DISPLAY=":$DISPLAY_NUM" "$CHROMIUM" \
    --user-data-dir="$SESSION_DIR/browser-profile" \
    --remote-debugging-port="$CDP_PORT" \
    --no-first-run \
    --no-default-browser-check \
    &>/tmp/agent-chromium-$NAME.log &
CHROMIUM_PID=$!

# poll until CDP responds (up to 15 s)
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" &>/dev/null; then break; fi
    if ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
        echo "ERROR: Chromium exited early. Log:"; cat /tmp/agent-chromium-$NAME.log >&2
        kill "$XVFB_PID" 2>/dev/null || true
        cleanup; exit 1
    fi
    sleep 0.5
done
if ! curl -sf "http://127.0.0.1:$CDP_PORT/json/version" &>/dev/null; then
    echo "ERROR: CDP did not respond after 15 s on port $CDP_PORT" >&2
    kill "$CHROMIUM_PID" "$XVFB_PID" 2>/dev/null || true
    cleanup; exit 1
fi
echo "    Chromium ready (PID $CHROMIUM_PID)"

# --- x11vnc ---
echo "==> starting x11vnc (:$DISPLAY_NUM -> VNC :$VNC_PORT)"
x11vnc -display ":$DISPLAY_NUM" -rfbport "$VNC_PORT" -localhost -forever -nopw -quiet \
    &>/tmp/agent-x11vnc-$NAME.log &
X11VNC_PID=$!
sleep 0.5

# --- noVNC (websockify) ---
echo "==> starting noVNC (:$NOVNC_PORT -> VNC :$VNC_PORT)"
websockify --web /usr/share/novnc/ "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" \
    &>/tmp/agent-novnc-$NAME.log &
NOVNC_PID=$!
sleep 0.3

# --- socat CDP bridge ---
echo "==> starting CDP bridge (10.95.99.1:$CDP_PORT -> 127.0.0.1:$CDP_PORT)"
socat TCP-LISTEN:"$CDP_PORT",bind=10.95.99.1,fork,reuseaddr \
    TCP:127.0.0.1:"$CDP_PORT" \
    &>/tmp/agent-socat-$NAME.log &
SOCAT_PID=$!
sleep 0.3
if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
    echo "ERROR: socat failed. Log:"; cat /tmp/agent-socat-$NAME.log >&2
    kill "$CHROMIUM_PID" "$XVFB_PID" "$X11VNC_PID" "$NOVNC_PID" 2>/dev/null || true
    cleanup; exit 1
fi

echo "$XVFB_PID $CHROMIUM_PID $X11VNC_PID $NOVNC_PID $SOCAT_PID" > "$SESSION_DIR/pids"

# --- LXD container ---
echo "==> launching $CONTAINER"
sg lxd -c "lxc launch agent-sandbox $CONTAINER --profile default --profile agent"

if [ -n "$WORKSPACE" ]; then
    echo "==> mounting workspace: $WORKSPACE -> /workspace"
    sg lxd -c "lxc config device add $CONTAINER workspace disk source=$WORKSPACE path=/workspace shift=true"
fi

echo "==> applying egress ACL"
sg lxd -c "lxc config device override $CONTAINER eth0 security.acls=agent-egress security.acls.default.egress.action=reject" 2>/dev/null || true

echo "==> waiting for cloud-init"
sg lxd -c "lxc exec $CONTAINER -- cloud-init status --wait --long" 2>/dev/null | tail -3 || sleep 12

echo "==> disabling in-container browser services"
sg lxd -c "lxc exec $CONTAINER -- systemctl disable --now chromium xvfb openbox x11vnc novnc" 2>/dev/null || true

echo "==> patching opencode.json (CDP → host bridge)"
sg lxd -c "lxc exec $CONTAINER -- sed -i 's|127.0.0.1:9222|10.95.99.1:$CDP_PORT|g' /root/.config/opencode/opencode.json"

echo "==> fixing ttyd port conflict"
sg lxd -c "lxc exec $CONTAINER -- systemctl disable --now ttyd.service" 2>/dev/null || true
sg lxd -c "lxc exec $CONTAINER -- systemctl restart ttyd-opencode.service"

IP=$(sg lxd -c "lxc list $CONTAINER --format csv -c 4" | grep -oP '(\d+\.){3}\d+' || true)
HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1 || hostname -I | awk '{print $1}')

echo ""
echo "Agent '$NAME' is up — slot $SLOT"
echo "  Browser (noVNC) : http://$HOST_IP:$NOVNC_PORT/vnc.html"
echo "  opencode TUI    : http://$IP:7681"
echo "  opencode API    : http://$IP:4096"
echo ""
echo "Tear down with:  agent-sandbox/scripts/teardown-agent.sh $NAME"
