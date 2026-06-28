# Agent Sandbox

## What this project does and why you would want it

AI coding assistants like **opencode** are powerful at writing and editing code, but they are blind to the web. They cannot log into a site, fill a form, click a button, or read a page that requires JavaScript to render. This project solves that by giving each agent its own real browser, controlled programmatically via **Playwright**.

The result: you can hand an agent a task like *"go to this dashboard, download the latest export, and process it"* and it will actually do it — navigating pages, clicking elements, handling login flows — just as a human would.

### What Playwright adds to an agentic workflow

**Playwright** is a browser automation library. It lets a program drive a real Chromium browser: navigate to URLs, click elements, fill forms, wait for content to load, take screenshots, and extract text. Normally Playwright is used for automated testing, but here it is exposed to the AI agent as a set of tools via the **MCP** protocol (see glossary below).

Without Playwright, the agent only has access to your filesystem and a terminal. With Playwright, it gains *eyes and hands in the browser*: it can see what a logged-in user would see and interact with it. This is particularly useful for tasks that involve web UIs with no public API, or workflows that mix code work with browser-based steps.

### Why a secure sandbox is necessary

Giving an AI agent a browser and a terminal on your machine is a significant trust extension. Several real risks exist:

- **Prompt injection**: a malicious web page could embed hidden instructions that hijack the agent's next actions.
- **Data exfiltration**: an agent that can browse can also POST your SSH keys or source code to a remote server.
- **Accidental destruction**: an agent executing shell commands can delete files, push bad commits, or consume cloud resources.
- **Cookie theft**: if the agent shares your personal browser profile, it inherits every authenticated session you have.

This project contains those risks by running the agent inside an **LXD container** (a lightweight OS-level sandbox) with strict network rules. The agent cannot see your host filesystem, cannot reach your personal browser, and can only make outbound network connections to a whitelist of destinations.

### Limitations and trade-offs (the honest version)

This design prioritises **simplicity and fast iteration** over maximum security. Understand the trade-offs before relying on it for high-stakes work:

| What is not fully locked down | Why we accept it |
|---|---|
| Network egress allows HTTP/HTTPS to any public host (ports 80/443) | Agents need to browse the web; blocking all public web access defeats the purpose. An agent could POST data to a public endpoint. |
| Chromium runs on the host, not inside the container | Full Chromium sandboxing requires kernel namespace features that are not available inside unprivileged LXD containers. Running on the host gives the browser its full security model. The trade-off: a browser exploit could reach the host user session. |
| LXD containers share the host kernel | LXD is not a virtual machine. A kernel exploit inside the container could potentially escape to the host. A full VM (QEMU/KVM) would be safer, but adds complexity and overhead. |
| The agent can read any file inside its container | If you mount a host workspace into the container, the agent can read and modify everything in it. Only mount what you are comfortable with the agent touching. |

The design is a pragmatic starting point: good enough to prevent the most likely accidents and casual misuse, while remaining simple enough to understand and run on a single machine.

---

## Technical concepts explained

### LXD and LXC containers

**LXC** (Linux Containers) is a kernel feature that creates isolated *OS-level* containers: each container has its own filesystem, process tree, network stack, and user namespace, but shares the host kernel. Think of it as a very lightweight virtual machine that skips the hardware emulation layer.

**LXD** is the daemon that manages LXC containers. It adds a REST API, image management, network bridges, and access control lists. When you run `lxc launch`, LXD provisions an isolated environment in seconds instead of the minutes a full VM would take.

**Unprivileged containers**: by default, LXD runs containers in *unprivileged* mode. The container's `root` user (UID 0 inside) is mapped to an unprivileged user on the host (e.g. UID 100000). This means even if an attacker gains root inside the container, they are just a regular unprivileged user on the host — drastically limiting what they can do outside.

### CDP — Chrome DevTools Protocol

**CDP** is the protocol that Chromium exposes for external control and debugging. When you launch Chromium with `--remote-debugging-port=9222`, it starts listening for CDP connections on that port. Any CDP client (like Playwright) can then send commands: *navigate to this URL*, *find this element*, *click it*, *take a screenshot*.

This project launches Chromium on the host with a CDP port open, then uses a **socat** relay to bridge that port into the container's network. The agent inside the container connects to the relay IP and controls the host browser as if it were local.

### Xvfb — virtual framebuffer

Chromium requires a display (a screen) to run. On a headless server there is no monitor. **Xvfb** (X virtual framebuffer) creates a fake display entirely in memory. Chromium renders into it normally; you just cannot see it directly. Xvfb gives every agent session its own isolated virtual screen identified by a display number (`:1`, `:2`, etc.).

### x11vnc and noVNC — sharing the virtual screen

**x11vnc** reads pixels from an Xvfb display and streams them using the **VNC** protocol (a standard for remote desktop sharing). By itself VNC requires a dedicated VNC client application.

**noVNC** removes that requirement: it is a VNC client that runs entirely in the browser, translating VNC's binary protocol into WebSocket messages. The result is that you can watch and interact with the agent's browser by just opening a URL — no extra software needed.

**WebSocket** is a protocol that keeps a persistent two-way connection open between a browser and a server, unlike normal HTTP which is request-response only. noVNC uses it to stream the screen in real time.

**websockify** bridges VNC (TCP) to WebSocket so noVNC can connect.

### opencode and the TUI

**opencode** is an open-source AI coding agent. It has a terminal interface (TUI — text user interface) and an HTTP API. Inside the container, **ttyd** wraps the opencode TUI in a web server, so you can interact with it from any browser without SSH.

### MCP — Model Context Protocol

**MCP** is an open protocol that defines how tools are exposed to an LLM agent. An MCP server advertises a list of callable tools (functions with typed parameters). The agent runtime discovers them and can invoke them during its reasoning loop.

The **Playwright MCP server** running inside the container exposes browser actions as MCP tools: `navigate`, `click`, `fill`, `screenshot`, `get_page_content`, etc. opencode calls these tools when it needs to interact with the web, and Playwright executes them against the Chromium browser via CDP.

### Network ACL

**ACL** stands for *Access Control List*. LXD's network ACLs are firewall rules attached to the bridge that containers connect through. The `agent-egress` ACL used here:

- **Allows** DNS lookups (so domain names resolve)
- **Allows** port 8081 to the host IP (so the agent can reach the local LLM)
- **Allows** ports 80 and 443 to the internet (so the agent can browse)
- **Blocks** everything else (no access to the host's private services, other containers, or arbitrary ports)

### socat

**socat** (SOcket CAt) is a relay tool that forwards data between two addresses, which can be TCP ports, Unix sockets, files, or almost anything else. Here it is used to bridge the Chromium CDP port on the host into the `lxdbr0` bridge network so the container can reach it.

### lxdbr0

**lxdbr0** is the virtual network bridge that LXD creates for its containers. The host has an IP on this bridge (`10.95.99.1` by default), and each container gets an IP in the same subnet. When the agent needs to reach the LLM or the CDP relay, it connects to the host's `10.95.99.1` address over this bridge.

---

## Architecture overview

```
HOST MACHINE
├── Xvfb :10N          ← virtual display (fake screen)
├── Chromium           ← real browser, renders into Xvfb, CDP on port 92NN
├── x11vnc             ← reads Xvfb, streams via VNC protocol
├── websockify         ← wraps VNC in WebSocket
├── noVNC              ← serves browser-based VNC client at :608N
└── socat              ← relays CDP port from host into lxdbr0

LXD CONTAINER (network-isolated)
├── opencode           ← AI coding agent
├── ttyd               ← exposes opencode TUI as a web page at :7681
├── opencode API       ← HTTP server at :4096
└── Playwright MCP     ← browser automation tools, connects to CDP relay
```

Data flow for a browser action: opencode → Playwright MCP → CDP relay (socat on lxdbr0) → Chromium on host → page rendered in Xvfb → visible via noVNC in your browser.

---

## Access points at a glance

| What | URL | Notes |
|---|---|---|
| Agent's browser (view/interact) | `http://HOST:608N/vnc.html` | Log in through here; cookies are shared with the agent |
| opencode TUI | `http://CONTAINER-IP:7681` | Main way to chat with the agent |
| opencode API | `http://CONTAINER-IP:4096` | For programmatic use |

`N` = slot number printed on launch. Container IP is also printed.

---

## Setup

### Prerequisites (one time)

The following must already exist on the host:

- LXD image aliased `agent-sandbox` (Ubuntu 24.04, aarch64, ~1.2 GiB)
- LXD profile `agent` (4 CPU, 8 GiB RAM, `security.nesting=true`, cloud-init sets LLM URL)
- LXD network ACL `agent-egress` (as described above)

Then install host-side dependencies:

```bash
sudo agent-sandbox/scripts/setup-host.sh
```

Installs: `socat`, `xvfb`, `x11vnc`, `websockify`, `novnc`, and `chromium` (snap).

### Launch an agent

```bash
# No host workspace mounted
agent-sandbox/scripts/new-agent.sh myagent

# Mount a project directory as /workspace inside the container
agent-sandbox/scripts/new-agent.sh myagent ~/myproject
```

Prints access URLs when ready (~15 s for cloud-init). Open the noVNC URL to see the browser; open the ttyd URL to talk to the agent.

### Tear down an agent

```bash
agent-sandbox/scripts/teardown-agent.sh myagent
```

Stops the container, kills all host-side processes (Xvfb, x11vnc, noVNC, socat) for that session. The host workspace directory is preserved.

---

## Files

| File | Role |
|---|---|
| `scripts/setup-host.sh` | One-time host setup (needs sudo) |
| `scripts/new-agent.sh` | Launch a new agent session |
| `scripts/teardown-agent.sh` | Stop and delete a session |
| `scripts/restart-chrome.sh` | Restart the Chromium process for a session without tearing down |
