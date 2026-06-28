#!/usr/bin/env bash
# One-time host setup: install socat, xvfb, x11vnc, novnc, playwright chromium.
# Must be run with sudo.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo" >&2; exit 1
fi

PKGS=()
command -v socat       &>/dev/null || PKGS+=(socat)
command -v Xvfb        &>/dev/null || PKGS+=(xvfb)
command -v x11vnc      &>/dev/null || PKGS+=(x11vnc)
command -v websockify  &>/dev/null || PKGS+=(websockify novnc)

if [ "${#PKGS[@]}" -gt 0 ]; then
    echo "==> installing: ${PKGS[*]}"
    apt-get install -y "${PKGS[@]}"
else
    echo "    all packages already installed"
fi

echo ""
echo "Host setup complete."
echo "  socat:      $(command -v socat)"
echo "  Xvfb:       $(command -v Xvfb)"
echo "  x11vnc:     $(command -v x11vnc)"
echo "  websockify: $(command -v websockify)"
echo ""
echo "Next: run 'agent-sandbox/scripts/new-agent.sh' — it will download playwright chromium on first use."
