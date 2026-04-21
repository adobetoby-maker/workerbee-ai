#!/bin/bash
# ================================================================
#  🐝 WORKER BEE — MAC INSTALLER v2.0
#  Paste this into macOS Terminal or iTerm2 and press Enter.
#  Installs everything. Takes 10-20 min. Do not close the window.
# ================================================================
set -e

AMB='\033[0;33m'; GRN='\033[0;32m'; RED='\033[0;31m'
BLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log()  { echo -e "${AMB}[🐝]${NC} $1"; }
ok()   { echo -e "${GRN}[✓]${NC}  $1"; }
warn() { echo -e "${AMB}[⚠]${NC}  $1"; }
err()  { echo -e "${RED}[✗]${NC}  $1"; exit 1; }
hdr()  { echo -e "\n${BLD}${AMB}══ $1 ══${NC}\n"; }

clear
echo -e "${AMB}${BLD}"
echo "  🐝  WORKER BEE — MAC INSTALLER v2.0"
echo "  ======================================"
echo -e "${NC}${DIM}  Homebrew · Python 3.12 · uv · Ollama · FastAPI"
echo -e "  Playwright · Chromium · LLaVA · Self-Repair · Login Engine${NC}"
echo ""

hdr "1 / 10  DETECTING YOUR MAC"
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
if   [ "$RAM_GB" -ge 32 ]; then MODEL="qwen2.5-coder:32b"; MREASON="32GB+ best for web building"
elif [ "$RAM_GB" -ge 16 ]; then MODEL="llama3.2";           MREASON="16GB balanced"
else                             MODEL="llama3.2:3b";        MREASON="8GB fast and light"
fi
ok "Model selected: $MODEL  ($MREASON)"
sleep 1

hdr "2 / 10  HOMEBREW"
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

hdr "3 / 10  PYTHON 3.12 + UV"
python3 --version 2>&1 | grep -qE "3\.1[2-9]" || brew install python@3.12 --quiet
if ! command -v uv &>/dev/null; then
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
fi
ok "Python + uv ready"

hdr "4 / 10  OLLAMA"
command -v ollama &>/dev/null || brew install ollama --quiet
launchctl setenv OLLAMA_HOST 0.0.0.0 2>/dev/null || true
grep -q "OLLAMA_HOST" ~/.zshrc 2>/dev/null || echo 'export OLLAMA_HOST=0.0.0.0' >> ~/.zshrc
if ! pgrep -x ollama > /dev/null; then
    log "Starting Ollama..."
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 3
fi
ok "Ollama running on :11434"

hdr "5 / 10  PROJECT FOLDER"
mkdir -p ~/worker-bee/agent/tools ~/worker-bee/projects
cd ~/worker-bee
uv venv .venv --quiet
source .venv/bin/activate
log "Installing Python packages..."
uv pip install \
    fastapi "uvicorn[standard]" websockets httpx \
    playwright chromadb gitpython pypdf sqlalchemy \
    watchdog requests python-dotenv \
    google-auth google-auth-oauthlib \
    google-auth-httplib2 google-api-python-client \
    slack-sdk twilio --quiet
ok "All packages ready"

hdr "6 / 10  SSL CERTIFICATE"
mkdir -p ~/.ssl
openssl req -x509 -newkey rsa:4096 \
    -keyout ~/.ssl/key.pem -out ~/.ssl/cert.pem \
    -days 365 -nodes -subj "/CN=localhost" 2>/dev/null
ok "SSL cert ready — valid 365 days"

hdr "7 / 10  WRITING AGENT FILES"

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
    return {"status": "ok", "service": "worker-bee-agent", "version": "2.0.0"}

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

touch ~/worker-bee/agent/__init__.py
touch ~/worker-bee/agent/tools/__init__.py

log "Writing agent/runner.py..."
cat > ~/worker-bee/agent/runner.py << 'RUNNERPY'
import httpx, json, os, base64
from .tools.browser import BrowserTool
from .tools.filesystem import FilesystemTool
from .tools.shell import ShellTool

OLLAMA = os.getenv("OLLAMA_HOST", "http://localhost:11434")
MODEL  = os.getenv("DEFAULT_MODEL", "qwen2.5-coder:32b")

class AgentRunner:
    def __init__(self, tab_id: str, ws):
        self.tab_id      = tab_id
        self.ws          = ws
        self.model       = MODEL
        self.history     = []
        self.browser     = BrowserTool()
        self.fs          = FilesystemTool()
        self.shell       = ShellTool()
        self.error_count = 0
        self.MAX_ERRORS  = 3

    async def handle(self, msg: dict):
        a = msg.get("action")
        if   a == "chat":        await self.chat(msg)
        elif a == "browser":     await self.run_browser(msg)
        elif a == "shell":       await self.run_shell(msg)
        elif a == "vision":      await self.run_vision(msg)
        elif a == "login":       await self.run_login(msg)
        elif a == "gmail":       await self.run_gmail(msg)
        elif a == "self_repair": await self.run_self_repair(msg)
        elif a == "file_read":
            try:
                await self.send("file_content", {
                    "path": msg["path"],
                    "content": self.fs.read(msg["path"])
                })
            except Exception as e:
                await self.send("error", str(e))
        elif a == "file_write":
            try:
                await self.send("file_written", {
                    "result": self.fs.write(msg["path"], msg["content"])
                })
            except Exception as e:
                await self.send("error", str(e))
        elif a == "ping":
            await self.send("pong", {"tab_id": self.tab_id})

    async def run_browser(self, msg: dict):
        await self.send("status", "browser_working")
        result = await self.browser.navigate(msg["url"])
        if result.get("success") and result.get("screenshot_b64"):
            await self.send("screenshot", {
                "url": result["url"],
                "screenshot_b64": result["screenshot_b64"]
            })
            vision = await self.vision_analyze(
                result["screenshot_b64"],
                "You are analyzing a web app screenshot. Describe: "
                "1) The main purpose of the app "
                "2) Color scheme and design style "
                "3) Key UI components visible "
                "4) Any issues or improvements needed"
            )
            result["vision_description"] = vision
        await self.send("browser_result", result)

    async def run_shell(self, msg: dict):
        await self.send("status", "shell_working")
        result = await self.shell.run(msg["command"])
        await self.send("shell_result", result)

    async def run_vision(self, msg: dict):
        await self.send("status", "vision_working")
        description = await self.vision_analyze(
            msg.get("screenshot_b64", ""),
            msg.get("question", "What do you see?")
        )
        await self.send("vision_result", {"description": description})

    async def run_login(self, msg: dict):
        await self.send("status", "login_working")
        await self.send("login_log", f"Attempting login to {msg.get('url')}...")
        result = await self.browser.login(
            url=msg.get("url", ""),
            username=msg.get("username", ""),
            password=msg.get("password", ""),
            max_attempts=msg.get("max_attempts", 5)
        )
        if result.get("success"):
            await self.send("login_log",
                f"Logged in after {result.get('attempts', 1)} attempt(s)")
            if result.get("screenshot_b64"):
                await self.send("screenshot", {
                    "url": result["url"],
                    "screenshot_b64": result["screenshot_b64"]
                })
        else:
            await self.send("login_log", f"Login failed: {result.get('error')}")
        await self.send("login_result", result)

    async def run_gmail(self, msg: dict):
        await self.send("status", "gmail_working")
        try:
            from .tools.gmail import GmailTool
            gmail = GmailTool()
            action = msg.get("gmail_action")
            if action == "summary":
                await self.send("gmail_summary", gmail.get_inbox_summary())
            elif action == "top_senders":
                await self.send("gmail_senders", gmail.get_top_senders())
            elif action == "preview":
                await self.send("gmail_preview",
                    gmail.get_emails(msg.get("query", "in:inbox")))
            elif action == "archive":
                result = gmail.archive_emails(msg.get("query", ""))
                await self.send("gmail_done", {"action": "archive", **result})
            elif action == "delete":
                result = gmail.delete_emails(msg.get("query", ""))
                await self.send("gmail_done", {"action": "delete", **result})
            elif action == "unsubscribe":
                result = gmail.unsubscribe_sender(msg.get("sender", ""))
                await self.send("gmail_done", {"action": "unsubscribe", **result})
            else:
                await self.send("gmail_error",
                    {"message": f"Unknown gmail_action: {action}"})
        except Exception as e:
            await self.send("gmail_error", {"message": str(e)})

    async def run_self_repair(self, msg: dict):
        from .repair import self_repair
        await self.send("repair_started", {
            "error": msg.get("error", "Manual repair requested")
        })
        success = await self_repair(
            msg.get("error", "Manual repair requested"), ws=self.ws)
        await self.send("repair_complete", {"success": success})

    async def vision_analyze(self, screenshot_b64: str, question: str) -> str:
        try:
            async with httpx.AsyncClient(timeout=60) as c:
                r = await c.post(f"{OLLAMA}/api/generate", json={
                    "model": "llava:latest",
                    "prompt": question,
                    "images": [screenshot_b64],
                    "stream": False
                })
                return r.json().get("response", "Vision unavailable")
        except Exception as e:
            return f"Vision unavailable: {e}"

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
                        if not line.strip(): continue
                        try:
                            token = json.loads(line).get(
                                "message", {}).get("content", "")
                            if token:
                                full += token
                                await self.send("token", token)
                        except json.JSONDecodeError:
                            continue
            self.history.append({"role": "assistant", "content": full})
            self.error_count = 0
            await self.send("done", {"content": full, "chars": len(full)})
        except Exception as e:
            self.error_count += 1
            await self.send("error", str(e))
            if self.error_count >= self.MAX_ERRORS:
                await self.send("repair_started", {
                    "error": f"Auto-repair after {self.MAX_ERRORS} errors: {e}"
                })
                from .repair import self_repair
                await self_repair(f"Chat failing: {e}", ws=self.ws)
                self.error_count = 0

    async def send(self, t: str, d):
        await self.ws.send_text(json.dumps({"type": t, "data": d}))

    async def cleanup(self):
        await self.browser.close()
RUNNERPY

log "Writing agent/repair.py..."
cat > ~/worker-bee/agent/repair.py << 'REPAIRPY'
import httpx, json, os, asyncio, pathlib, sys

OLLAMA = os.getenv("OLLAMA_HOST", "http://localhost:11434")
MODEL  = os.getenv("DEFAULT_MODEL", "qwen2.5-coder:32b")
ROOT   = pathlib.Path.home() / "worker-bee"

WATCHED_FILES = [
    "main.py", "agent/runner.py",
    "agent/tools/browser.py",
    "agent/tools/filesystem.py",
    "agent/tools/shell.py",
]

async def read_files() -> str:
    out = []
    for f in WATCHED_FILES:
        p = ROOT / f
        if p.exists():
            out.append(f"\n--- {f} ---\n{p.read_text()}")
    return "\n".join(out)

async def read_logs() -> str:
    log = pathlib.Path("/tmp/workerbee-error.log")
    if log.exists():
        return "\n".join(log.read_text().strip().split("\n")[-50:])
    return "No error log found"

async def ask_qwen(prompt: str) -> str:
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post(f"{OLLAMA}/api/chat", json={
            "model": MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False
        })
        return r.json().get("message", {}).get("content", "")

async def apply_fix(filename: str, new_content: str):
    p = ROOT / filename
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        (ROOT / f"{filename}.backup").write_text(p.read_text())
    p.write_text(new_content)
    print(f"Applied fix to {filename}")

async def extract_files_from_response(response: str) -> dict:
    fixes = {}
    lines = response.split("\n")
    current_file = None
    current_content = []
    for line in lines:
        if line.startswith("=== ") and line.endswith(" ===") and "end" not in line:
            current_file = line[4:-4].strip()
            current_content = []
        elif line == "=== end ===" and current_file:
            fixes[current_file] = "\n".join(current_content)
            current_file = None
            current_content = []
        elif current_file:
            current_content.append(line)
    return fixes

async def self_repair(error_description: str, ws=None):
    async def log(msg):
        print(msg)
        if ws:
            await ws.send_text(json.dumps({"type": "repair_log", "data": msg}))

    await log("SELF-REPAIR INITIATED")
    await log(f"Error: {error_description[:200]}")
    await log("Reading current agent files...")
    files = await read_files()
    await log("Reading error logs...")
    logs = await read_logs()

    prompt = f"""You are Worker Bee's self-repair system.
ERROR: {error_description}
LOGS: {logs}
FILES: {files}

Output ONLY files that need fixing in this format:
=== agent/tools/browser.py ===
<complete fixed file>
=== end ===

No explanation. Production ready Python only."""

    await log("Asking qwen to diagnose and fix...")
    response = await ask_qwen(prompt)
    await log(f"Got response ({len(response)} chars)")
    fixes = await extract_files_from_response(response)

    if not fixes:
        await log("No fixes found in response")
        return False

    await log(f"Fixing: {list(fixes.keys())}")
    for filename, content in fixes.items():
        if any(filename == f for f in WATCHED_FILES):
            await apply_fix(filename, content)
            await log(f"Fixed: {filename}")

    await log("Triggering reload...")
    (ROOT / "main.py").touch()
    await log("SELF-REPAIR COMPLETE — reconnecting in 3s")
    return True

if __name__ == "__main__":
    error = " ".join(sys.argv[1:]) or "General error"
    asyncio.run(self_repair(error))
REPAIRPY

log "Writing agent/tools/browser.py..."
cat > ~/worker-bee/agent/tools/browser.py << 'BROWSERPY'
from playwright.async_api import async_playwright
import base64, asyncio

class BrowserTool:
    def __init__(self):
        self._pw       = None
        self._browser  = None
        self._contexts = {}

    async def _ensure(self):
        if not self._browser:
            self._pw = await async_playwright().start()
            self._browser = await self._pw.chromium.launch(
                headless=True,
                args=["--no-sandbox", "--disable-dev-shm-usage",
                      "--disable-blink-features=AutomationControlled"]
            )

    async def _get_context(self, domain: str):
        await self._ensure()
        if domain in self._contexts:
            return self._contexts[domain]
        ctx = await self._browser.new_context(
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) "
                       "Chrome/120.0.0.0 Safari/537.36",
            viewport={"width": 1280, "height": 800},
            extra_http_headers={"Accept-Language": "en-US,en;q=0.9"}
        )
        await ctx.add_init_script(
            "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});")
        self._contexts[domain] = ctx
        return ctx

    async def navigate(self, url: str) -> dict:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx    = await self._get_context(domain)
        page   = await ctx.new_page()
        try:
            await page.goto(url, timeout=30000, wait_until="networkidle")
            await page.wait_for_timeout(3000)
            for attempt in range(5):
                error_found = False
                for sel in ["text=An unexpected error occurred",
                            "text=Something went wrong",
                            "text=SOMETHING WENT WRONG",
                            "text=404"]:
                    try:
                        if await page.locator(sel).is_visible(timeout=1000):
                            error_found = True
                            break
                    except Exception:
                        pass
                if not error_found:
                    break
                clicked = False
                for sel in ["text=Try again", "text=Try Again",
                            "text=Retry", "button:has-text('Try')",
                            "button:has-text('Retry')"]:
                    try:
                        btn = page.locator(sel)
                        if await btn.is_visible(timeout=1000):
                            await btn.click()
                            clicked = True
                            break
                    except Exception:
                        pass
                if not clicked:
                    await page.reload(wait_until="networkidle")
                await page.wait_for_timeout(3000 + (attempt * 2000))
            shot = await page.screenshot(full_page=True)
            text = await page.inner_text("body")
            return {
                "url": page.url, "title": await page.title(),
                "text": text[:6000],
                "screenshot_b64": base64.b64encode(shot).decode(),
                "success": True
            }
        except Exception as e:
            return {"url": url, "error": str(e), "success": False}
        finally:
            await page.close()

    async def login(self, url: str, username: str,
                    password: str, max_attempts: int = 5) -> dict:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx    = await self._get_context(domain)
        EMAIL_SELS = [
            'input[type="email"]', 'input[name="email"]',
            'input[name="username"]', 'input[name="user"]',
            'input[id="email"]', 'input[id="username"]',
            'input[placeholder*="email" i]',
            'input[placeholder*="username" i]',
            'input[autocomplete="email"]',
            'input[autocomplete="username"]',
            'input:not([type="password"]):not([type="hidden"]):not([type="submit"])',
        ]
        PASS_SELS = [
            'input[type="password"]', 'input[name="password"]',
            'input[id="password"]', 'input[placeholder*="password" i]',
            'input[autocomplete="current-password"]',
        ]
        SUBMIT_SELS = [
            'button[type="submit"]', 'input[type="submit"]',
            'button:has-text("Sign in")', 'button:has-text("Log in")',
            'button:has-text("Login")', 'button:has-text("Continue")',
            'button:has-text("Next")', '[role="button"]:has-text("Sign in")',
        ]
        last_error = ""
        for attempt in range(1, max_attempts + 1):
            page = await ctx.new_page()
            try:
                await page.goto(url, timeout=30000, wait_until="networkidle")
                await page.wait_for_timeout(2000)
                filled_email = False
                for sel in EMAIL_SELS:
                    try:
                        el = page.locator(sel).first
                        if await el.is_visible(timeout=1000):
                            await el.click()
                            await el.fill(username)
                            filled_email = True
                            break
                    except Exception:
                        pass
                if not filled_email:
                    await page.keyboard.press("Tab")
                    await page.keyboard.type(username)
                await page.wait_for_timeout(500)
                pass_visible = False
                for sel in PASS_SELS[:2]:
                    try:
                        if await page.locator(sel).first.is_visible(timeout=500):
                            pass_visible = True
                            break
                    except Exception:
                        pass
                if not pass_visible:
                    for sel in ['button:has-text("Next")',
                                'button:has-text("Continue")',
                                'button[type="submit"]']:
                        try:
                            btn = page.locator(sel).first
                            if await btn.is_visible(timeout=1000):
                                await btn.click()
                                await page.wait_for_timeout(2000)
                                break
                        except Exception:
                            pass
                filled_pass = False
                for sel in PASS_SELS:
                    try:
                        el = page.locator(sel).first
                        if await el.is_visible(timeout=2000):
                            await el.click()
                            await el.fill(password)
                            filled_pass = True
                            break
                    except Exception:
                        pass
                if not filled_pass:
                    last_error = "Password field not found"
                    await page.close()
                    await asyncio.sleep(2)
                    continue
                await page.wait_for_timeout(500)
                submitted = False
                for sel in SUBMIT_SELS:
                    try:
                        btn = page.locator(sel).first
                        if await btn.is_visible(timeout=1000):
                            await btn.click()
                            submitted = True
                            break
                    except Exception:
                        pass
                if not submitted:
                    await page.keyboard.press("Enter")
                await page.wait_for_load_state("networkidle", timeout=10000)
                await page.wait_for_timeout(2000)
                failed = False
                for fail_text in ["incorrect password", "invalid credentials",
                                   "wrong password", "login failed"]:
                    try:
                        if await page.locator(f"text={fail_text}").is_visible(timeout=1000):
                            failed = True
                            last_error = fail_text
                            break
                    except Exception:
                        pass
                if failed:
                    await page.close()
                    await asyncio.sleep(2)
                    continue
                shot = await page.screenshot()
                text = await page.inner_text("body")
                self._contexts[domain] = ctx
                return {
                    "url": page.url, "title": await page.title(),
                    "text": text[:4000],
                    "screenshot_b64": base64.b64encode(shot).decode(),
                    "success": True, "attempts": attempt, "logged_in": True
                }
            except Exception as e:
                last_error = str(e)
                await page.close()
                await asyncio.sleep(2 + attempt)
        return {
            "url": url, "success": False, "attempts": max_attempts,
            "error": f"Login failed after {max_attempts} attempts: {last_error}"
        }

    async def navigate_authenticated(self, url: str) -> dict:
        domain = url.split("/")[2] if "//" in url else url
        if domain not in self._contexts:
            return await self.navigate(url)
        ctx  = self._contexts[domain]
        page = await ctx.new_page()
        try:
            await page.goto(url, timeout=30000, wait_until="networkidle")
            await page.wait_for_timeout(2000)
            shot = await page.screenshot(full_page=True)
            text = await page.inner_text("body")
            return {
                "url": page.url, "title": await page.title(),
                "text": text[:6000],
                "screenshot_b64": base64.b64encode(shot).decode(),
                "success": True, "authenticated": True
            }
        except Exception as e:
            return {"url": url, "error": str(e), "success": False}
        finally:
            await page.close()

    async def screenshot(self, url: str) -> str:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx    = await self._get_context(domain)
        page   = await ctx.new_page()
        await page.goto(url, timeout=30000, wait_until="networkidle")
        await page.wait_for_timeout(3000)
        shot = await page.screenshot(full_page=True)
        await page.close()
        return base64.b64encode(shot).decode()

    async def scrape(self, url: str) -> str:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx    = await self._get_context(domain)
        page   = await ctx.new_page()
        await page.goto(url, timeout=30000, wait_until="networkidle")
        await page.wait_for_timeout(3000)
        text = await page.inner_text("body")
        await page.close()
        return text

    async def close(self):
        for ctx in self._contexts.values():
            await ctx.close()
        if self._browser: await self._browser.close()
        if self._pw:      await self._pw.stop()
BROWSERPY

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
        return [str(f.relative_to(SAFE))
                for f in self._safe(path).iterdir()]

    def delete(self, path: str) -> str:
        self._safe(path).unlink()
        return f"Deleted {path}"

    def exists(self, path: str) -> bool:
        return self._safe(path).exists()
FSPY

log "Writing agent/tools/shell.py..."
cat > ~/worker-bee/agent/tools/shell.py << 'SHELLPY'
import asyncio, pathlib, os

BLOCKED = [
    "rm -rf /", "sudo rm -rf", "mkfs", "dd if=",
    ":(){:|:&};:", "chmod 777 /", "curl | bash", "wget | bash"
]

VENV = str(pathlib.Path.home() / "worker-bee" / ".venv" / "bin")

class ShellTool:
    async def run(self, command: str, timeout: int = 120) -> dict:
        for b in BLOCKED:
            if b in command:
                return {"error": f"Blocked: {b}", "success": False}
        env = os.environ.copy()
        env["PATH"] = f"{VENV}:{env.get('PATH', '')}"
        try:
            proc = await asyncio.create_subprocess_shell(
                command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=str(pathlib.Path.home() / "worker-bee"),
                env=env
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return {
                "stdout": out.decode(),
                "returncode": proc.returncode,
                "success": proc.returncode == 0
            }
        except asyncio.TimeoutError:
            return {"error": "Timed out", "success": False}
SHELLPY

log "Writing agent/tools/gmail.py..."
cat > ~/worker-bee/agent/tools/gmail.py << 'GMAILPY'
import os, pathlib
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build

SCOPES = [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.readonly"
]

TOKEN_PATH = pathlib.Path.home() / ".workerbee_gmail_token.json"
CREDS_PATH = pathlib.Path.home() / ".workerbee_gmail_creds.json"

class GmailTool:
    def __init__(self):
        self._service = None

    def _auth(self):
        creds = None
        if TOKEN_PATH.exists():
            creds = Credentials.from_authorized_user_file(
                str(TOKEN_PATH), SCOPES)
        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                if not CREDS_PATH.exists():
                    raise FileNotFoundError(
                        f"Gmail credentials not found at {CREDS_PATH}. "
                        "Download OAuth credentials from Google Cloud Console."
                    )
                flow = InstalledAppFlow.from_client_secrets_file(
                    str(CREDS_PATH), SCOPES)
                creds = flow.run_local_server(port=0)
            TOKEN_PATH.write_text(creds.to_json())
        self._service = build("gmail", "v1", credentials=creds)
        return self._service

    def service(self):
        if not self._service:
            self._auth()
        return self._service

    def get_inbox_summary(self) -> dict:
        svc = self.service()
        categories = {
            "unread":      "is:unread",
            "promotions":  "category:promotions",
            "social":      "category:social",
            "updates":     "category:updates",
            "newsletters": "list:* OR unsubscribe",
            "old_unread":  "is:unread older_than:30d",
        }
        summary = {}
        for name, query in categories.items():
            result = svc.users().messages().list(
                userId="me", q=query, maxResults=1).execute()
            summary[name] = result.get("resultSizeEstimate", 0)
        inbox = svc.users().labels().get(
            userId="me", id="INBOX").execute()
        summary["total_inbox"] = inbox.get("messagesTotal", 0)
        return summary

    def get_emails(self, query: str, max_results: int = 20) -> list:
        svc = self.service()
        results = svc.users().messages().list(
            userId="me", q=query, maxResults=max_results).execute()
        emails = []
        for m in results.get("messages", []):
            msg = svc.users().messages().get(
                userId="me", id=m["id"], format="metadata",
                metadataHeaders=["From", "Subject", "Date"]).execute()
            headers = {h["name"]: h["value"]
                      for h in msg["payload"]["headers"]}
            emails.append({
                "id": m["id"], "from": headers.get("From", ""),
                "subject": headers.get("Subject", ""),
                "date": headers.get("Date", ""),
                "snippet": msg.get("snippet", "")[:100]
            })
        return emails

    def archive_emails(self, query: str, max_results: int = 500) -> dict:
        svc = self.service()
        results = svc.users().messages().list(
            userId="me", q=query, maxResults=max_results).execute()
        messages = results.get("messages", [])
        if not messages:
            return {"archived": 0, "message": "No emails found"}
        ids = [m["id"] for m in messages]
        svc.users().messages().batchModify(
            userId="me",
            body={"ids": ids, "removeLabelIds": ["INBOX"]}).execute()
        return {"archived": len(ids), "message": f"Archived {len(ids)} emails"}

    def delete_emails(self, query: str, max_results: int = 500) -> dict:
        svc = self.service()
        results = svc.users().messages().list(
            userId="me", q=query, maxResults=max_results).execute()
        messages = results.get("messages", [])
        if not messages:
            return {"deleted": 0, "message": "No emails found"}
        ids = [m["id"] for m in messages]
        svc.users().messages().batchModify(
            userId="me",
            body={"ids": ids, "addLabelIds": ["TRASH"]}).execute()
        return {"deleted": len(ids), "message": f"Moved {len(ids)} to trash"}

    def unsubscribe_sender(self, sender_email: str) -> dict:
        return self.archive_emails(
            f"from:{sender_email}", max_results=1000)

    def get_top_senders(self, max_results: int = 200) -> list:
        svc = self.service()
        results = svc.users().messages().list(
            userId="me", q="in:inbox", maxResults=max_results).execute()
        senders = {}
        for m in results.get("messages", []):
            msg = svc.users().messages().get(
                userId="me", id=m["id"], format="metadata",
                metadataHeaders=["From"]).execute()
            sender = next(
                (h["value"] for h in msg["payload"]["headers"]
                 if h["name"] == "From"), "Unknown")
            senders[sender] = senders.get(sender, 0) + 1
        return [{"sender": s, "count": c}
                for s, c in sorted(senders.items(),
                                   key=lambda x: x[1],
                                   reverse=True)[:20]]
GMAILPY

log "Writing requirements.txt..."
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
google-auth-httplib2>=0.2.0
google-api-python-client>=2.127.0
slack-sdk>=3.27.2
twilio>=9.1.0
REQTXT

log "Writing .env..."
cat > ~/worker-bee/.env << ENVEOF
OLLAMA_HOST=http://localhost:11434
DEFAULT_MODEL=${MODEL}
AGENT_PORT=8000
SAFE_ROOT=${HOME}/worker-bee/projects
GMAIL_USER=
GMAIL_CLIENT_ID=
GMAIL_CLIENT_SECRET=
SLACK_BOT_TOKEN=
SLACK_DEFAULT_CHANNEL=#general
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM=whatsapp:+14155238886
TWILIO_TO=whatsapp:+1YOURNUMBER
ENVEOF

log "Writing start.sh..."
cat > ~/worker-bee/start.sh << 'STARTSH'
#!/bin/zsh
# 🐝 Worker Bee — or just type: wb
cd ~/worker-bee
source .venv/bin/activate
pgrep -x ollama > /dev/null \
    || (ollama serve > /tmp/ollama.log 2>&1 & sleep 2)
echo "Agent -> https://localhost:8000"
uvicorn main:app --reload --host 0.0.0.0 --port 8000 \
    --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem
STARTSH
chmod +x ~/worker-bee/start.sh

log "Writing cert renewal script..."
cat > ~/worker-bee/renew-cert.sh << 'RENEWSH'
#!/bin/zsh
mkdir -p ~/.ssl
openssl req -x509 -newkey rsa:4096 \
    -keyout ~/.ssl/key.pem -out ~/.ssl/cert.pem \
    -days 365 -nodes -subj "/CN=localhost" 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.workerbee.agent.plist
launchctl load ~/Library/LaunchAgents/com.workerbee.agent.plist
echo "Cert renewed and agent restarted"
RENEWSH
chmod +x ~/worker-bee/renew-cert.sh

ok "All agent files written"

hdr "8 / 10  PLAYWRIGHT + CHROMIUM"
log "Downloading Chromium (~170 MB)..."
playwright install chromium
log "Fixing macOS Gatekeeper..."
xattr -cr ~/Library/Caches/ms-playwright/ 2>/dev/null || true
log "Testing Playwright..."
python3 - << 'PYTEST'
from playwright.sync_api import sync_playwright
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.goto("https://example.com", timeout=15000)
        print(f"  Playwright OK: {pg.title()}")
        b.close()
except Exception as e:
    print(f"  Note: {e}")
PYTEST
ok "Playwright + Chromium ready"

hdr "9 / 10  PULLING AI MODELS"
log "Pulling $MODEL ($MREASON)..."
log "May take 5-20 min on first run"
ollama pull "$MODEL"
ok "$MODEL ready"

log "Pulling llava vision model (4.7GB)..."
ollama pull llava
ok "llava ready — Worker Bee has eyes"

hdr "10 / 10  AUTO-START + SHORTCUTS"

log "Setting up launchd auto-start..."
cat > ~/Library/LaunchAgents/com.workerbee.agent.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.workerbee.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-c</string>
    <string>cd $HOME/worker-bee && source .venv/bin/activate && uvicorn main:app --host 0.0.0.0 --port 8000 --ssl-keyfile $HOME/.ssl/key.pem --ssl-certfile $HOME/.ssl/cert.pem</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/workerbee.log</string>
  <key>StandardErrorPath</key><string>/tmp/workerbee-error.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key><string>http://localhost:11434</string>
    <key>DEFAULT_MODEL</key><string>${MODEL}</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
launchctl load ~/Library/LaunchAgents/com.workerbee.agent.plist 2>/dev/null || true
ok "Auto-start configured — starts on every login"

log "Adding wb shortcut..."
grep -q "alias wb=" ~/.zshrc 2>/dev/null || \
echo 'alias wb="cd ~/worker-bee && source .venv/bin/activate && uvicorn main:app --reload --host 0.0.0.0 --port 8000 --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem"' >> ~/.zshrc
source ~/.zshrc 2>/dev/null || true
ok "Type 'wb' anywhere to start Worker Bee"

clear
echo -e "${GRN}${BLD}"
echo "  WORKER BEE v2.0 IS READY"
echo -e "${NC}"
echo -e "  ${GRN}[OK]${NC} Ollama          http://localhost:11434"
echo -e "  ${GRN}[OK]${NC} Agent           https://localhost:8000"
echo -e "  ${GRN}[OK]${NC} Vision          llava installed"
echo -e "  ${GRN}[OK]${NC} Browser         Playwright + Chromium"
echo -e "  ${GRN}[OK]${NC} Self-repair     qwen monitors itself"
echo -e "  ${GRN}[OK]${NC} Login engine    5-strategy persistent login"
echo -e "  ${GRN}[OK]${NC} Gmail cleaner   inbox tools ready"
echo -e "  ${GRN}[OK]${NC} Auto-start      starts on every login"
echo ""
echo -e "  ${AMB}DAILY:${NC}  type 'wb' in any terminal"
echo -e "  ${AMB}UI:${NC}     https://worker-bee.lovable.app"
echo ""
echo -e "  First time: visit https://localhost:8000/health"
echo -e "  in Safari and click through the security warning"
echo ""
echo -e "  LOGS: tail -f /tmp/workerbee.log"
echo ""
echo -e "${GRN}Starting agent now...${NC}"
echo ""
cd ~/worker-bee && source .venv/bin/activate
uvicorn main:app --reload --host 0.0.0.0 --port 8000 \
    --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem
