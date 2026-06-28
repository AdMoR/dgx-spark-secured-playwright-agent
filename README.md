# Agent Sandbox

Per-session AI agent environments: **Chromium runs on the host** (full sandbox, noVNC web UI),
**opencode + Playwright run in an LXD container** (network isolation).
They communicate via CDP bridged over lxdbr0.

| Access point | URL | Purpose |
|---|---|---|
| Browser (noVNC) | `http://HOST:608N/vnc.html` | View and interact with the agent's Chromium |
| opencode TUI | `http://CONTAINER-IP:7681` | Agent interface (ttyd) — primary UI |
| opencode API | `http://CONTAINER-IP:4096` | Headless opencode HTTP server |

`N` = slot number (printed when launching). Container IP is also printed.

---

## How the browser session is shared with the agent

A **Chromium** browser runs on the host in a virtual display (Xvfb), visible via noVNC.
Log into sites through the noVNC window; Chromium stores cookies in a persistent profile at
`~/.local/share/agent-sessions/<name>/browser-profile/`.
The agent's **Playwright MCP** attaches to that same browser over CDP
(bridged from the host to `10.95.99.1:<cdp-port>`) and inherits the authenticated session.

## Prerequisites (one time)

The following must already exist on the host (set up in a prior session):

- LXD image aliased `agent-sandbox` (Ubuntu 24.04, aarch64, ~1.2 GiB)
- LXD profile `agent` (4 CPU, 8 GiB RAM, `security.nesting=true`, cloud-init sets LLM URL)
- LXD network ACL `agent-egress` (allow DNS + port 8081 to host + web 80/443; block everything else)

Then install host dependencies once:

```bash
sudo agent-sandbox/scripts/setup-host.sh
```

Installs: `socat`, `xvfb`, `x11vnc`, `websockify`, `novnc`, and `chromium` (snap).

## Launch an agent

```bash
# Minimal — no host workspace mounted
agent-sandbox/scripts/new-agent.sh myagent

# With a host project directory mounted as /workspace inside the container
agent-sandbox/scripts/new-agent.sh myagent ~/myproject
```

The script prints the noVNC URL and container URLs when ready (~15 s for cloud-init).
Open the noVNC URL in your browser to see and interact with the agent's Chromium window.

## Tear down an agent

```bash
agent-sandbox/scripts/teardown-agent.sh myagent
```

Stops the container, kills Chromium and all host processes (Xvfb, x11vnc, noVNC, socat).
The host workspace directory (if any) is preserved.

---

## Security model

| Threat | Protection |
|---|---|
| Agent reads host SSH keys / browser passwords | Container filesystem isolation |
| Agent modifies system files | Container boundary (root inside = unprivileged on host) |
| Agent exfiltrates data via network | `agent-egress` ACL: only DNS, LLM endpoint, and 80/443 allowed |
| Agent accesses host user's personal browser | Separate `--user-data-dir` per session; agent only reaches the agent's CDP port |
| Browser renderer exploit | Chromium's own kernel namespace sandbox (full, not `--no-sandbox`) |

The hybrid design gives full Chromium sandbox (not possible inside LXD unprivileged containers)
while keeping the agent process isolated in the container.

## Files

| File | Role |
|---|---|
| `scripts/setup-host.sh` | One-time host setup (needs sudo) |
| `scripts/new-agent.sh` | Launch a new agent session |
| `scripts/teardown-agent.sh` | Stop and delete a session |
