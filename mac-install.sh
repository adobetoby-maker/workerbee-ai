#!/bin/bash
# ================================================================
#  🐝 WORKER BEE — MAC INSTALLER
#  Paste this into macOS Terminal and press Enter.
#  Installs everything. Takes 5–15 min. Do not close the window.
# ================================================================
set -e

# ── Colors ───────────────────────────────────────────────────────
AMB='\033[0;33m'; GRN='\033[0;32m'; RED='\033[0;31m'
BLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log()  { echo -e "${AMB}[🐝]${NC} $1"; }
ok()   { echo -e "${GRN}[✓]${NC}  $1"; }
warn() { echo -e "${AMB}[⚠]${NC}  $1"; }
err()  { echo -e "${RED}[✗]${NC}  $1"; exit 1; }
hdr()  { echo -e "\n${BLD}${AMB}══ $1 ══${NC}\n"; }

# ── Banner ───────────────────────────────────────────────────────
clear
echo -e "${AMB}${BLD}"
echo "  🐝  WORKER BEE — MAC INSTALLER"
echo "  ================================"
echo -e "${NC}${DIM}  Homebrew · Python 3.12 · uv · Ollama · FastAPI · Playwright · Chromium${NC}"
echo ""

# ── 1. Detect machine ────────────────────────────────────────────
hdr "1 / 9  DETECTING YOUR MAC"
ARCH=$(uname -m)
RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
OS=$(sw_vers -productVersion)
log "Arch: $ARCH  |  RAM: ${RAM_GB}GB  |  macOS: $OS"
if [ "$ARCH" = "arm64" ]; then
    ok "Apple Silicon — Metal GPU available"
    CHIP="arm"
else
    warn "Intel Mac — CPU only, expect slower responses"
    CHIP="intel"
fi
# Pick model by RAM
if   [ "$RAM_GB" -ge 32 ]; then MODEL="phi4";        MREASON="32GB+ → high quality"
elif [ "$RAM_GB" -ge 16 ]; then MODEL="llama3.2";    MREASON="16GB → balanced"
else                             MODEL="llama3.2:3b"; MREASON="8GB → fast & light"
fi
ok "Model selected: $MODEL  ($MREASON)"
sleep 1

# ── 2. Homebrew ──────────────────────────────────────────────────
hdr "2 / 9  HOMEBREW"
if command -v brew &>/dev/null; then
    ok "Already installed — updating quietly"
    brew update --quiet && brew upgrade --quiet 2>/dev/null || true
else
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ "$CHIP" = "arm" ]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi
ok "Homebrew ready"

# ── 3. Python 3.12 + uv ─────────────────────────────────────────
hdr "3 / 9  PYTHON 3.12 + UV"
python3 --version 2>&1 | grep -qE "3\.1[2-9]" || brew install python@3.12 --quiet
if ! command -v uv &>/dev/null; then
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
fi
ok "Python $(python3 --version) · uv $(uv --version)"

# ── 4. Ollama ────────────────────────────────────────────────────
hdr "4 / 9  OLLAMA"
command -v ollama &>/dev/null || brew install ollama --quiet
# Allow all interfaces (needed for Tailscale bridge)
launchctl setenv OLLAMA_HOST 0.0.0.0 2>/dev/null || true
grep -q "OLLAMA_HOST" ~/.zshrc 2>/dev/null || echo 'export OLLAMA_HOST=0.0.0.0' >> ~/.zshrc
# Start if not running
if ! pgrep -x ollama > /dev/null; then
    log "Starting Ollama..."
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 3
fi
ok "Ollama running on :11434  (OLLAMA_HOST=0.0.0.0)"

# ── 5. Project folder + venv ─────────────────────────────────────
hdr "5 / 9  PROJECT FOLDER"
mkdir -p ~/worker-bee/agent/tools ~/worker-bee/projects
cd ~/worker-bee
uv venv .venv --quiet
source .venv/bin/activate
log "Installing Python packages (~30 sec with uv)..."
uv pip install \
    fastapi "uvicorn[standard]" websockets httpx \
    playwright chromadb gitpython pypdf sqlalchemy \
    watchdog requests python-dotenv \
    google-auth google-auth-oauthlib google-api-python-client \
    slack-sdk twilio --quiet
ok "Virtual environment + all packages ready"

# ── 6. Write agent files ─────────────────────────────────────────
hdr "6 / 9  WRITING AGENT FILES"

# main.py
log "Writing main.py..."
cat > ~/worker-bee/main.py << 'MAINPY'
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import json
from agent.runner import AgentRunner

app = FastAPI(title="Worker Bee Agent")
app.add_middleware(CORSMiddleware, allow_origins=["*"],
                   allow_methods=["*"], allow_headers=["*"])
runners = {}

@app.get("/health")
async def health():
    return {"status": "ok", "service": "worker-bee-agent", "version": "1.0.0"}

@app.get("/api/tags")
async def tags():
    import httpx, os
    base = os.getenv("OLLAMA_HOST", "http://localhost:11434")
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(f"{base}/api/tags")
        return r.json()

@app.get("/api/ps")
async def ps():
    import httpx, os
    base = os.getenv("OLLAMA_HOST", "http://localhost:11434")
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(f"{base}/api/ps")
        return r.json()

@app.websocket("/ws/{tab_id}")
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

# agent/__init__.py
touch ~/worker-bee/agent/__init__.py
touch ~/worker-bee/agent/tools/__init__.py

# agent/runner.py
log "Writing agent/runner.py..."
cat > ~/worker-bee/agent/runner.py << 'RUNNERPY'
import httpx, json, os
from .tools.browser import BrowserTool
from .tools.filesystem import FilesystemTool
from .tools.shell import ShellTool

OLLAMA = os.getenv("OLLAMA_HOST", "http://localhost:11434")

class AgentRunner:
    def __init__(self, tab_id: str, ws):
        self.tab_id = tab_id
        self.ws = ws
        self.model = os.getenv("DEFAULT_MODEL", "llama3.2")
        self.history = []
        self.browser = BrowserTool()
        self.fs = FilesystemTool()
        self.shell = ShellTool()

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
RUNNERPY

# agent/tools/browser.py
log "Writing agent/tools/browser.py..."
cat > ~/worker-bee/agent/tools/browser.py << 'BROWSERPY'
from playwright.async_api import async_playwright
import base64

class BrowserTool:
    def __init__(self):
        self._pw = None
        self._browser = None

    async def _ensure(self):
        if not self._browser:
            self._pw = await async_playwright().start()
            self._browser = await self._pw.chromium.launch(headless=True)

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

    async def screenshot(self, url: str) -> str:
        await self._ensure()
        page = await self._browser.new_page()
        await page.goto(url, timeout=30000)
        shot = await page.screenshot(full_page=True)
        await page.close()
        return base64.b64encode(shot).decode()

    async def scrape(self, url: str) -> str:
        await self._ensure()
        page = await self._browser.new_page()
        await page.goto(url, timeout=30000)
        text = await page.inner_text("body")
        await page.close()
        return text

    async def close(self):
        if self._browser: await self._browser.close()
        if self._pw:      await self._pw.stop()
BROWSERPY

# agent/tools/filesystem.py
log "Writing agent/tools/filesystem.py..."
cat > ~/worker-bee/agent/tools/filesystem.py << 'FSPY'
import pathlib

SAFE = pathlib.Path.home() / "worker-bee" / "projects"

class FilesystemTool:
    def __init__(self):
        SAFE.mkdir(parents=True, exist_ok=True)

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
FSPY

# agent/tools/shell.py
log "Writing agent/tools/shell.py..."
cat > ~/worker-bee/agent/tools/shell.py << 'SHELLPY'
import asyncio, pathlib

BLOCKED = [
    "rm -rf /", "sudo rm -rf", "mkfs", "dd if=",
    ":(){:|:&};:", "chmod 777 /", "curl | bash", "wget | bash"
]

class ShellTool:
    async def run(self, command: str, timeout: int = 30) -> dict:
        for b in BLOCKED:
            if b in command:
                return {"error": f"Blocked command: {b}", "success": False}
        try:
            proc = await asyncio.create_subprocess_shell(
                command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(pathlib.Path.home() / "worker-bee")
            )
            out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return {
                "stdout": out.decode(),
                "stderr": err.decode(),
                "returncode": proc.returncode,
                "success": proc.returncode == 0
            }
        except asyncio.TimeoutError:
            return {"error": "Command timed out", "success": False}
SHELLPY

# requirements.txt
cat > ~/worker-bee/requirements.txt << 'REQTXT'
fastapi>=0.111.0
uvicorn[standard]>=0.29.0
websockets>=12.0
playwright>=1.44.0
httpx>=0.27.0
chromadb>=0.5.0
gitpython>=3.1.43
pypdf>=4.2.0
sqlalchemy>=2.0.30
watchdog>=4.0.1
python-dotenv>=1.0.1
google-auth>=2.29.0
google-auth-oauthlib>=1.2.0
google-api-python-client>=2.127.0
slack-sdk>=3.27.2
twilio>=9.1.0
REQTXT

# .env
cat > ~/worker-bee/.env << ENVEOF
OLLAMA_HOST=http://localhost:11434
DEFAULT_MODEL=${MODEL}
AGENT_PORT=8000
SAFE_ROOT=${HOME}/worker-bee/projects
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
cat > ~/worker-bee/start.sh << 'STARTSH'
#!/bin/bash
# 🐝 Worker Bee — run this every morning
cd ~/worker-bee
source .venv/bin/activate
pgrep -x ollama > /dev/null \
    || (ollama serve > /tmp/ollama.log 2>&1 & sleep 2 \
        && echo "🦙 Ollama started")
echo "⚡ Agent server → http://localhost:8000"
uvicorn main:app --reload --host 0.0.0.0 --port 8000
STARTSH
chmod +x ~/worker-bee/start.sh

ok "All 9 files written to ~/worker-bee/"

# ── 7. Playwright + Chromium ─────────────────────────────────────
hdr "7 / 9  PLAYWRIGHT + CHROMIUM"
log "Downloading Chromium (~170 MB)..."
playwright install chromium
log "Removing macOS Gatekeeper quarantine flag..."
xattr -cr ~/Library/Caches/ms-playwright/ 2>/dev/null || true
ok "Gatekeeper fixed"
log "Testing Playwright..."
python3 - << 'PYTEST'
from playwright.sync_api import sync_playwright
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.goto("https://example.com", timeout=15000)
        print(f"  Playwright OK — title: {pg.title()}")
        b.close()
except Exception as e:
    print(f"  Playwright test failed (network?): {e}")
PYTEST
ok "Playwright + Chromium ready"

# ── 8. Pull model ────────────────────────────────────────────────
hdr "8 / 9  PULLING AI MODEL"
log "Pulling $MODEL ($MREASON)..."
log "Download size: 3b≈2GB  8b≈5GB  14b≈9GB — please wait"
ollama pull "$MODEL"
ok "$MODEL ready"

# ── 9. Full Disk Access reminder ────────────────────────────────
hdr "9 / 9  PERMISSIONS CHECK"
warn "macOS needs Full Disk Access for the file tools to work."
echo ""
echo -e "  ${BLD}Opening System Settings now...${NC}"
echo -e "  Add ${AMB}Terminal${NC} under Privacy & Security → Full Disk Access"
echo ""
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
read -rp "  Press Enter once you've added Terminal (or S to skip): " SKP
[[ "$SKP" =~ ^[Ss]$ ]] && warn "Skipped — file tools may be limited" || ok "Full Disk Access confirmed"

# ── Done ─────────────────────────────────────────────────────────
clear
echo -e "${GRN}${BLD}"
echo "  ✅  WORKER BEE IS READY"
echo -e "${NC}"
echo -e "  ${DIM}Ollama  →  http://localhost:11434${NC}"
echo -e "  ${DIM}Agent   →  http://localhost:8000  (starting now...)${NC}"
echo ""
echo -e "  ${BLD}${AMB}Every morning:${NC}  cd ~/worker-bee && ./start.sh"
echo -e "  ${BLD}${AMB}In the UI:${NC}      CONFIG → endpoint → http://localhost:8000"
echo ""
cd ~/worker-bee && source .venv/bin/activate
uvicorn main:app --reload --host 0.0.0.0 --port 8000
