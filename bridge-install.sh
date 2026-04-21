#!/bin/bash

# ================================================================

# 🌉 WORKER BEE — BRIDGE INSTALLER (Ubuntu VM)

# 

# This script runs on your Ubuntu VM.

# It installs the Worker Bee agent server that connects BACK

# to Ollama running on your Mac via Tailscale or local network.

# 

# Paste into your Ubuntu terminal and press Enter.

# ================================================================

set -e

# ── Colors ───────────────────────────────────────────────────────

AMB=’\033[0;33m’; GRN=’\033[0;32m’; RED=’\033[0;31m’
BLU=’\033[0;34m’; BLD=’\033[1m’; DIM=’\033[2m’; NC=’\033[0m’
log()  { echo -e “${AMB}[🌉]${NC} $1”; }
ok()   { echo -e “${GRN}[✓]${NC}  $1”; }
warn() { echo -e “${AMB}[⚠]${NC}  $1”; }
err()  { echo -e “${RED}[✗]${NC}  $1”; exit 1; }
hdr()  { echo -e “\n${BLD}${BLU}══ $1 ══${NC}\n”; }

# ── Banner ───────────────────────────────────────────────────────

clear
echo -e “${BLU}${BLD}”
echo “  🌉  WORKER BEE — BRIDGE INSTALLER”
echo “  ===================================”
echo -e “${NC}${DIM}  Ubuntu VM → connects to Ollama on your Mac${NC}”
echo -e “${DIM}  FastAPI · Playwright · Chromium · Tailscale${NC}”
echo “”

# ── Verify this is Ubuntu ────────────────────────────────────────

if ! command -v apt &>/dev/null; then
err “This script is for Ubuntu/Debian only.”
fi
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo “unknown”)
log “Ubuntu $UBUNTU_VER detected”

# ── Get Mac’s Ollama address ─────────────────────────────────────

hdr “0 / 8  CONFIGURE MAC CONNECTION”
echo -e “${BLD}How is this VM connected to your Mac?${NC}”
echo “”
echo “  1) Tailscale VPN  (recommended — works anywhere)”
echo “  2) Local network  (same router)”
echo “  3) Same machine   (Mac running VM locally)”
echo “”
read -rp “  Enter 1, 2, or 3: “ CONN_TYPE

case “$CONN_TYPE” in
1)
echo “”
echo -e “${AMB}  Get your Mac’s Tailscale IP by running on the Mac:${NC}”
echo -e “${DIM}  tailscale ip -4${NC}”
echo “”
read -rp “  Paste your Mac’s Tailscale IP (e.g. 100.64.0.1): “ MAC_IP
OLLAMA_BASE=“http://${MAC_IP}:11434”
CONN_LABEL=“Tailscale VPN”
;;
2)
echo “”
echo -e “${AMB}  Get your Mac’s local IP:${NC}”
echo -e “${DIM}  System Settings → Wi-Fi → Details → IP Address${NC}”
echo “”
read -rp “  Paste your Mac’s local IP (e.g. 192.168.1.50): “ MAC_IP
OLLAMA_BASE=“http://${MAC_IP}:11434”
CONN_LABEL=“Local Network”
;;
3)
MAC_IP=“host.docker.internal”
OLLAMA_BASE=“http://host.docker.internal:11434”
CONN_LABEL=“Same Machine (host)”
;;
*)
err “Invalid choice. Re-run and enter 1, 2, or 3.”
;;
esac

log “Ollama endpoint: $OLLAMA_BASE  ($CONN_LABEL)”

# Test connectivity before proceeding

log “Testing connection to Mac’s Ollama…”
if curl -s –connect-timeout 5 “${OLLAMA_BASE}/api/tags” > /dev/null 2>&1; then
ok “Ollama is reachable at $OLLAMA_BASE”
else
warn “Cannot reach Ollama right now.”
echo “”
echo -e “  ${AMB}Make sure on your Mac:${NC}”
echo -e “  1. Ollama is running:       ${DIM}ollama serve${NC}”
echo -e “  2. Tailscale is connected:  ${DIM}tailscale up${NC}”
echo -e “  3. OLLAMA_HOST is set:      ${DIM}launchctl setenv OLLAMA_HOST 0.0.0.0${NC}”
echo “”
read -rp “  Continue anyway? (y/N): “ FORCE
[[ “$FORCE” =~ ^[Yy]$ ]] || exit 1
fi

# ── 1. System packages ───────────────────────────────────────────

hdr “1 / 8  SYSTEM PACKAGES”
log “Updating apt…”
sudo apt-get update -qq
log “Installing system dependencies…”
sudo apt-get install -y -qq   
curl wget git build-essential   
python3 python3-pip python3-venv   
libnss3 libatk1.0-0 libatk-bridge2.0-0   
libcups2 libdrm2 libxkbcommon0 libxcomposite1   
libxdamage1 libxfixes3 libxrandr2 libgbm1   
libasound2 libpangocairo-1.0-0 libgtk-3-0   
fonts-liberation xdg-utils
ok “System packages installed”

# ── 2. Python 3.12 ──────────────────────────────────────────────

hdr “2 / 8  PYTHON 3.12”
if python3 –version 2>&1 | grep -qE “3.1[2-9]”; then
ok “Python $(python3 –version) already present”
else
log “Adding deadsnakes PPA for Python 3.12…”
sudo apt-get install -y -qq software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update -qq
sudo apt-get install -y -qq python3.12 python3.12-venv python3.12-dev
sudo update-alternatives –install /usr/bin/python3 python3 /usr/bin/python3.12 1
ok “Python 3.12 installed”
fi

# Install uv

if ! command -v uv &>/dev/null; then
log “Installing uv…”
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH=”$HOME/.local/bin:$PATH”
echo ‘export PATH=”$HOME/.local/bin:$PATH”’ >> ~/.bashrc
fi
ok “uv $(uv –version)”

# ── 3. Tailscale (if chosen) ─────────────────────────────────────

if [ “$CONN_TYPE” = “1” ]; then
hdr “3 / 8  TAILSCALE”
if command -v tailscale &>/dev/null; then
ok “Tailscale already installed”
else
log “Installing Tailscale…”
curl -fsSL https://tailscale.com/install.sh | sh
ok “Tailscale installed”
fi
log “Connecting to Tailscale network…”
sudo tailscale up
VM_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo “pending”)
ok “Tailscale IP: $VM_TAILSCALE_IP”
else
hdr “3 / 8  TAILSCALE  (skipped — not using VPN)”
ok “Skipped”
fi

# ── 4. Project folder + venv ─────────────────────────────────────

hdr “4 / 8  PROJECT FOLDER”
mkdir -p ~/worker-bee/agent/tools ~/worker-bee/projects
cd ~/worker-bee
uv venv .venv –quiet
source .venv/bin/activate
log “Installing Python packages…”
uv pip install   
fastapi “uvicorn[standard]” websockets httpx   
playwright chromadb gitpython pypdf sqlalchemy   
watchdog requests python-dotenv   
google-auth google-auth-oauthlib google-api-python-client   
slack-sdk twilio –quiet
ok “All packages installed”

# ── 5. Write agent files ─────────────────────────────────────────

hdr “5 / 8  WRITING AGENT FILES”

# main.py

cat > ~/worker-bee/main.py << ‘MAINPY’
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import json
from agent.runner import AgentRunner

app = FastAPI(title=“Worker Bee Bridge Agent”)
app.add_middleware(CORSMiddleware, allow_origins=[”*”],
allow_methods=[”*”], allow_headers=[”*”])
runners = {}

@app.get(”/health”)
async def health():
import os
return {
“status”: “ok”,
“service”: “worker-bee-bridge”,
“version”: “1.0.0”,
“ollama_host”: os.getenv(“OLLAMA_HOST”, “not set”)
}

@app.get(”/api/tags”)
async def tags():
import httpx, os
base = os.getenv(“OLLAMA_HOST”, “http://localhost:11434”)
async with httpx.AsyncClient(timeout=10) as c:
r = await c.get(f”{base}/api/tags”)
return r.json()

@app.get(”/api/ps”)
async def ps():
import httpx, os
base = os.getenv(“OLLAMA_HOST”, “http://localhost:11434”)
async with httpx.AsyncClient(timeout=10) as c:
r = await c.get(f”{base}/api/ps”)
return r.json()

@app.get(”/api/connection-test”)
async def conn_test():
import httpx, os
base = os.getenv(“OLLAMA_HOST”, “http://localhost:11434”)
try:
async with httpx.AsyncClient(timeout=5) as c:
r = await c.get(f”{base}/api/tags”)
models = r.json().get(“models”, [])
return {
“connected”: True,
“ollama_host”: base,
“models”: [m[“name”] for m in models]
}
except Exception as e:
return {“connected”: False, “ollama_host”: base, “error”: str(e)}

@app.websocket(”/ws/{tab_id}”)
async def ws_endpoint(ws: WebSocket, tab_id: str):
await ws.accept()
runner = AgentRunner(tab_id, ws)
runners[tab_id] = runner
try:
while True:
data = await ws.receive_text()
await runner.handle(json.loads(data))
except WebSocketDisconnect:
runners.pop(tab_id, None)
await runner.cleanup()
MAINPY

# agent/**init**.py

touch ~/worker-bee/agent/**init**.py
touch ~/worker-bee/agent/tools/**init**.py

# agent/runner.py

cat > ~/worker-bee/agent/runner.py << ‘RUNNERPY’
import httpx, json, os
from .tools.browser import BrowserTool
from .tools.filesystem import FilesystemTool
from .tools.shell import ShellTool

OLLAMA = os.getenv(“OLLAMA_HOST”, “http://localhost:11434”)

class AgentRunner:
def **init**(self, tab_id: str, ws):
self.tab_id = tab_id
self.ws = ws
self.model = os.getenv(“DEFAULT_MODEL”, “llama3.2”)
self.history = []
self.browser = BrowserTool()
self.fs = FilesystemTool()
self.shell = ShellTool()

```
async def handle(self, msg: dict):
    a = msg.get("action")
    if   a == "chat":       await self.chat(msg)
    elif a == "browser":    await self.send("browser_result",
                                await self.browser.navigate(msg["url"]))
    elif a == "shell":      await self.send("shell_result",
                                await self.shell.run(msg["command"]))
    elif a == "file_read":
        try:    await self.send("file_content",
                    {"path": msg["path"], "content": self.fs.read(msg["path"])})
        except Exception as e: await self.send("error", str(e))
    elif a == "file_write":
        try:    await self.send("file_written",
                    {"result": self.fs.write(msg["path"], msg["content"])})
        except Exception as e: await self.send("error", str(e))
    elif a == "ping":       await self.send("pong", {"tab_id": self.tab_id})

async def chat(self, msg: dict):
    if "model" in msg:
        self.model = msg["model"]
    self.history.append({"role": "user", "content": msg["content"]})
    await self.send("status", "streaming")
    full = ""
    try:
        async with httpx.AsyncClient(timeout=120) as c:
            async with c.stream("POST", f"{OLLAMA}/api/chat",
                json={"model": self.model,
                      "messages": self.history,
                      "stream": True}) as r:
                async for line in r.aiter_lines():
                    if not line: continue
                    try:
                        t = json.loads(line).get("message", {}).get("content", "")
                        if t:
                            full += t
                            await self.send("token", t)
                    except Exception:
                        pass
        self.history.append({"role": "assistant", "content": full})
        await self.send("done", {"content": full, "chars": len(full)})
    except Exception as e:
        await self.send("error", str(e))

async def send(self, t: str, d):
    await self.ws.send_text(json.dumps({"type": t, "data": d}))

async def cleanup(self):
    await self.browser.close()
```

RUNNERPY

# agent/tools/browser.py

cat > ~/worker-bee/agent/tools/browser.py << ‘BROWSERPY’
from playwright.async_api import async_playwright
import base64

class BrowserTool:
def **init**(self):
self._pw = None
self._browser = None

```
async def _ensure(self):
    if not self._browser:
        self._pw = await async_playwright().start()
        self._browser = await self._pw.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"]
        )

async def navigate(self, url: str) -> dict:
    await self._ensure()
    page = await self._browser.new_page()
    try:
        await page.goto(url, timeout=30000)
        shot = await page.screenshot()
        return {
            "url": url,
            "title": await page.title(),
            "text": (await page.inner_text("body"))[:4000],
            "screenshot_b64": base64.b64encode(shot).decode(),
            "success": True
        }
    except Exception as e:
        return {"url": url, "error": str(e), "success": False}
    finally:
        await page.close()

async def close(self):
    if self._browser: await self._browser.close()
    if self._pw:      await self._pw.stop()
```

BROWSERPY

# agent/tools/filesystem.py

cat > ~/worker-bee/agent/tools/filesystem.py << ‘FSPY’
import pathlib

SAFE = pathlib.Path.home() / “worker-bee” / “projects”

class FilesystemTool:
def **init**(self):
SAFE.mkdir(parents=True, exist_ok=True)

```
def _safe(self, path: str) -> pathlib.Path:
    p = (SAFE / path).resolve()
    if not str(p).startswith(str(SAFE)):
        raise PermissionError(f"Path outside safe root: {path}")
    return p

def read(self, path: str) -> str:
    return self._safe(path).read_text(encoding="utf-8")

def write(self, path: str, content: str) -> str:
    p = self._safe(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"Written {len(content)} chars to {path}"

def list_dir(self, path: str = "") -> list:
    return [str(f.relative_to(SAFE)) for f in self._safe(path).iterdir()]

def delete(self, path: str) -> str:
    self._safe(path).unlink()
    return f"Deleted {path}"

def exists(self, path: str) -> bool:
    return self._safe(path).exists()
```

FSPY

# agent/tools/shell.py

cat > ~/worker-bee/agent/tools/shell.py << ‘SHELLPY’
import asyncio, pathlib

BLOCKED = [
“rm -rf /”, “sudo rm -rf”, “mkfs”, “dd if=”,
“:(){:|:&};:”, “chmod 777 /”, “curl | bash”, “wget | bash”
]

class ShellTool:
async def run(self, command: str, timeout: int = 30) -> dict:
for b in BLOCKED:
if b in command:
return {“error”: f”Blocked: {b}”, “success”: False}
try:
proc = await asyncio.create_subprocess_shell(
command,
stdout=asyncio.subprocess.PIPE,
stderr=asyncio.subprocess.PIPE,
cwd=str(pathlib.Path.home() / “worker-bee”)
)
out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
return {
“stdout”: out.decode(),
“stderr”: err.decode(),
“returncode”: proc.returncode,
“success”: proc.returncode == 0
}
except asyncio.TimeoutError:
return {“error”: “Timed out”, “success”: False}
SHELLPY

# .env  (with actual MAC_IP baked in)

cat > ~/worker-bee/.env << ENVEOF
OLLAMA_HOST=${OLLAMA_BASE}
DEFAULT_MODEL=llama3.2
AGENT_PORT=8000
SAFE_ROOT=${HOME}/worker-bee/projects
CONN_MODE=${CONN_LABEL}
GMAIL_CLIENT_ID=
GMAIL_CLIENT_SECRET=
SLACK_BOT_TOKEN=
SLACK_DEFAULT_CHANNEL=#general
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM=whatsapp:+14155238886
TWILIO_TO=whatsapp:+1YOURNUMBER
ENVEOF

# start.sh

cat > ~/worker-bee/start.sh << STARTSH
#!/bin/bash

# 🌉 Worker Bee Bridge — run this every time

cd ~/worker-bee
source .venv/bin/activate
echo “🌉 Worker Bee Bridge starting…”
echo “   Ollama: ${OLLAMA_BASE}”
echo “   Agent:  http://$(hostname -I | awk ‘{print $1}’):8000”
uvicorn main:app –reload –host 0.0.0.0 –port 8000
STARTSH
chmod +x ~/worker-bee/start.sh

# Systemd service for auto-start

cat > /tmp/worker-bee.service << SVCEOF
[Unit]
Description=Worker Bee Bridge Agent
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${HOME}/worker-bee
ExecStart=${HOME}/worker-bee/.venv/bin/uvicorn main:app –host 0.0.0.0 –port 8000
Restart=on-failure
RestartSec=5
Environment=OLLAMA_HOST=${OLLAMA_BASE}
Environment=DEFAULT_MODEL=llama3.2

[Install]
WantedBy=multi-user.target
SVCEOF
sudo cp /tmp/worker-bee.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable worker-bee 2>/dev/null || true

ok “All agent files written to ~/worker-bee/”

# ── 6. Playwright + Chromium ─────────────────────────────────────

hdr “6 / 8  PLAYWRIGHT + CHROMIUM”
log “Downloading Chromium for Linux (~170 MB)…”
playwright install chromium

# Linux needs extra deps

playwright install-deps chromium 2>/dev/null || true
ok “Playwright + Chromium installed”
log “Testing Playwright (no Gatekeeper needed on Linux)…”
python3 - << ‘PYTEST’
from playwright.sync_api import sync_playwright
try:
with sync_playwright() as p:
b = p.chromium.launch(args=[”–no-sandbox”])
pg = b.new_page()
pg.goto(“https://example.com”, timeout=15000)
print(f”  Playwright OK — title: {pg.title()}”)
b.close()
except Exception as e:
print(f”  Warning: {e}”)
PYTEST
ok “Playwright ready”

# ── 7. Firewall ──────────────────────────────────────────────────

hdr “7 / 8  FIREWALL”
if command -v ufw &>/dev/null; then
log “Opening port 8000 in ufw…”
sudo ufw allow 8000/tcp 2>/dev/null || true
ok “Port 8000 open”
else
warn “ufw not found — ensure port 8000 is accessible”
fi

# ── 8. Connection test ───────────────────────────────────────────

hdr “8 / 8  FINAL CONNECTION TEST”
log “Starting agent server briefly to test…”
cd ~/worker-bee && source .venv/bin/activate
uvicorn main:app –host 0.0.0.0 –port 8000 &
SRV_PID=$!
sleep 3

log “Testing health endpoint…”
if curl -s http://localhost:8000/health > /dev/null 2>&1; then
ok “Agent server responding”
else
warn “Server not responding yet — may still be starting”
fi

log “Testing Ollama bridge…”
RESULT=$(curl -s http://localhost:8000/api/connection-test 2>/dev/null || echo ‘{“connected”:false}’)
if echo “$RESULT” | grep -q ‘“connected”: true|“connected”:true’; then
ok “Ollama bridge CONNECTED via $CONN_LABEL”
MODELS=$(echo “$RESULT” | python3 -c “import sys,json; d=json.load(sys.stdin); print(’, ’.join(d.get(‘models’,[][:3])))” 2>/dev/null || echo “unknown”)
ok “Models available: $MODELS”
else
warn “Ollama bridge test failed — check Mac connection settings”
echo -e “  ${AMB}Verify on your Mac:${NC}”
echo -e “  • Ollama is running: ${DIM}ollama serve${NC}”
echo -e “  • OLLAMA_HOST is set: ${DIM}launchctl setenv OLLAMA_HOST 0.0.0.0${NC}”
echo -e “  • Tailscale is up: ${DIM}tailscale up${NC}”
fi

kill $SRV_PID 2>/dev/null || true

# ── Done ─────────────────────────────────────────────────────────

VM_IP=$(hostname -I | awk ‘{print $1}’)
clear
echo -e “${GRN}${BLD}”
echo “  ✅  WORKER BEE BRIDGE IS READY”
echo -e “${NC}”
echo -e “  ${DIM}Ollama (on Mac)  →  ${OLLAMA_BASE}${NC}”
echo -e “  ${DIM}Agent (this VM)  →  http://${VM_IP}:8000${NC}”
echo “”
echo -e “  ${BLD}${BLU}Auto-start enabled:${NC}  sudo systemctl start worker-bee”
echo -e “  ${BLD}${BLU}Manual start:${NC}        cd ~/worker-bee && ./start.sh”
echo “”
echo -e “  ${BLD}${AMB}In the Worker Bee UI:${NC}”
echo -e “  CONFIG → Tailscale mode → endpoint:”
echo -e “  ${AMB}  http://${VM_IP}:8000${NC}”
echo “”
echo -e “${BLU}Starting bridge now…${NC}”
echo “”
cd ~/worker-bee && source .venv/bin/activate
uvicorn main:app –reload –host 0.0.0.0 –port 8000
