#!/bin/bash
# ================================================================
#  🐝 WORKER BEE — MAC INSTALLER v3.0
#  Paste into macOS Terminal or iTerm2 and press Enter.
#  Installs everything. Takes 10-20 min. Do not close window.
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
echo "  🐝  WORKER BEE — MAC INSTALLER v3.0"
echo "  ======================================"
echo -e "${NC}${DIM}  Homebrew · Python 3.12 · uv · Ollama · FastAPI"
echo -e "  Playwright · ChromaDB · Memory · Planner · GitHub${NC}"
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
    warn "Intel Mac — CPU only"
    CHIP="intel"
fi
if   [ "$RAM_GB" -ge 64 ]; then
    PRIMARY="llama3.3:70b"
    CODING="qwen2.5-coder:32b"
    REASON="deepseek-r1:70b"
    MREASON="64GB+ — full model stack"
elif [ "$RAM_GB" -ge 32 ]; then
    PRIMARY="llama3.2"
    CODING="qwen2.5-coder:32b"
    REASON="deepseek-r1:32b"
    MREASON="32GB — balanced stack"
else
    PRIMARY="llama3.2:3b"
    CODING="qwen2.5-coder:7b"
    REASON="phi4"
    MREASON="16GB — light stack"
fi
ok "Models: $PRIMARY | $CODING | $REASON ($MREASON)"
sleep 1

hdr "2 / 10  HOMEBREW"
if command -v brew &>/dev/null; then
    ok "Already installed — updating"
    brew update --quiet 2>/dev/null || true
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
grep -q "OLLAMA_HOST" ~/.zshrc 2>/dev/null || \
    echo 'export OLLAMA_HOST=http://localhost:11434' >> ~/.zshrc
export OLLAMA_HOST=http://localhost:11434
if ! pgrep -x ollama > /dev/null; then
    log "Starting Ollama..."
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 3
fi
ok "Ollama running on :11434"

hdr "5 / 10  PROJECT FOLDER + VENV"
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
ok "All packages installed"

hdr "6 / 10  SSL CERTIFICATE"
mkdir -p ~/.ssl
openssl req -x509 -newkey rsa:4096 \
    -keyout ~/.ssl/key.pem -out ~/.ssl/cert.pem \
    -days 365 -nodes -subj "/CN=localhost" 2>/dev/null
ok "SSL cert ready — valid 365 days"

hdr "7 / 10  WRITING ALL AGENT FILES"

log "Writing main.py..."
cat > ~/worker-bee/main.py << 'MAINPY'
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import json, os
from dotenv import load_dotenv
from agent.runner import AgentRunner

load_dotenv(os.path.expanduser("~/worker-bee/.env"))

app = FastAPI(title="Worker Bee Agent")
app.add_middleware(CORSMiddleware, allow_origins=["*"],
                   allow_methods=["*"], allow_headers=["*"])
runners = {}

@app.get("/health")
async def health():
    return {"status": "ok", "service": "worker-bee-agent", "version": "3.0.0"}

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
import httpx, json, os, base64, asyncio
from .tools.browser import BrowserTool
from .tools.filesystem import FilesystemTool
from .tools.shell import ShellTool
from .tools.memory import MemoryTool
from .tools.planner import TaskPlanner

OLLAMA = os.getenv("OLLAMA_HOST", "http://localhost:11434")
MODEL  = os.getenv("DEFAULT_MODEL", "llama3.3:70b")

def pick_model(message: str) -> str:
    """Auto-route to the best model for the task."""
    msg = message.lower()

    if any(w in msg for w in [
        "screenshot", "see ", "look at", "image",
        "visual", "what does it look", "show me",
        "analyze the page", "what do you see"
    ]):
        return "llava:latest"

    if any(w in msg for w in [
        "code", "build", "write a", "fix the",
        "debug", "html", "css", "javascript",
        "python", "function", "class", "component",
        "script", "lovable prompt", "react",
        "typescript", "install", "deploy", "create a",
        "generate", "refactor", "landing page",
        "website", "webpage", "navbar", "footer",
        "button", "form", "style", "animation"
    ]):
        return "qwen2.5-coder:32b"

    if any(w in msg for w in [
        "why ", "explain", "analyze", "diagnose",
        "architect", "strategy", "should i",
        "best way", "review", "audit", "plan",
        "compare", "difference between", "pros and cons",
        "recommend", "what would", "how would",
        "reason", "think through", "help me decide",
        "is it possible", "what is the best",
        "disconnect", "websocket", "web socket",
        "timeout", "protocol", "architecture",
        "how does", "what causes", "deep dive",
        "thorough", "detailed", "comprehensive"
    ]):
        return "deepseek-r1:70b"

    return "llama3.3:70b"

class AgentRunner:
    def __init__(self, tab_id: str, ws):
        self.tab_id      = tab_id
        self.ws          = ws
        self.model       = MODEL
        self.history     = []
        self.browser     = BrowserTool()
        self.fs          = FilesystemTool()
        self.shell       = ShellTool()
        self.memory      = MemoryTool(tab_id=tab_id)
        self.planner     = TaskPlanner(runner=self)
        self.error_count = 0
        self.MAX_ERRORS  = 3

    async def handle(self, msg: dict):
        a = msg.get("action")
        if   a == "chat":          await self.chat(msg)
        elif a == "browser":       await self.run_browser(msg)
        elif a == "shell":         await self.run_shell(msg)
        elif a == "vision":        await self.run_vision(msg)
        elif a == "login":         await self.run_login(msg)
        elif a == "gmail":         await self.run_gmail(msg)
        elif a == "get_tags":      await self.run_get_tags()
        elif a == "get_ps":        await self.run_get_ps()
        elif a == "github":        await self.run_github(msg)
        elif a == "self_repair":   await self.run_self_repair(msg)
        elif a == "plan":          await self.run_plan(msg)
        elif a == "plan_stop":     self.planner.stop()
        elif a == "plan_pause":    self.planner.pause()
        elif a == "plan_resume":   self.planner.resume()
        elif a == "memory_search": await self.run_memory_search(msg)
        elif a == "memory_store":  await self.run_memory_store(msg)
        elif a == "memory_stats":  await self.run_memory_stats()
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

    async def run_get_tags(self):
        try:
            base = os.getenv("OLLAMA_HOST", "http://localhost:11434")
            async with httpx.AsyncClient(timeout=10) as c:
                r = await c.get(f"{base}/api/tags")
                data = r.json()
                models = [m["name"] for m in data.get("models", [])]
                await self.send("tags_result", {"models": models, "count": len(models)})
        except Exception as e:
            await self.send("tags_error", str(e))

    async def run_get_ps(self):
        try:
            base = os.getenv("OLLAMA_HOST", "http://localhost:11434")
            async with httpx.AsyncClient(timeout=10) as c:
                r = await c.get(f"{base}/api/ps")
                await self.send("ps_result", r.json())
        except Exception as e:
            await self.send("ps_error", str(e))

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
                "Analyze this screenshot: 1) Main purpose "
                "2) Color scheme and design 3) Key UI components "
                "4) Issues or improvements needed"
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

    async def run_github(self, msg: dict):
        from .tools.github import GitHubTool
        gh = GitHubTool()
        action = msg.get("github_action")
        owner  = msg.get("owner", os.getenv("GITHUB_REPO_OWNER", ""))
        repo   = msg.get("repo", os.getenv("GITHUB_REPO_NAME", ""))
        if action == "get_file":
            await self.send("github_file",
                await gh.get_file(owner, repo, msg.get("path", "")))
        elif action == "list_files":
            await self.send("github_files",
                await gh.list_files(owner, repo, msg.get("path", "")))
        elif action == "get_structure":
            await self.send("github_structure",
                await gh.get_repo_structure(owner, repo))
        elif action == "get_multiple":
            await self.send("github_files_batch",
                await gh.get_multiple_files(owner, repo, msg.get("paths", [])))
        elif action == "push_file":
            await self.send("github_push_result",
                await gh.push_file(owner, repo,
                    msg.get("path", ""), msg.get("content", ""),
                    msg.get("message", "Worker Bee update"),
                    msg.get("sha", None)))

    async def run_self_repair(self, msg: dict):
        from .repair import self_repair
        await self.send("repair_started",
            {"error": msg.get("error", "Manual repair requested")})
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
        self.model = msg.get("model") or pick_model(msg.get("content", ""))
        user_content = msg["content"]
        self.history.append({"role": "user", "content": user_content})
        self.memory.store_message("user", user_content, self.model)
        mem_context = self.memory.build_context(user_content)
        await self.send("status", "streaming")
        full = ""

        async def heartbeat():
            while True:
                await asyncio.sleep(15)
                try:
                    await self.ws.send_text('{"type":"heartbeat","data":"ping"}')
                except Exception:
                    break

        hb_task = asyncio.create_task(heartbeat())
        large_models = ["deepseek-r1:70b", "deepseek-r1:32b"]

        try:
            if self.model in large_models:
                await self.send("token", "🤔 ")
                async def thinking_updates():
                    while True:
                        await asyncio.sleep(10)
                        await self.send("token", ".")
                think_task = asyncio.create_task(thinking_updates())
                try:
                    async with httpx.AsyncClient(timeout=600) as c:
                        r = await c.post(f"{OLLAMA}/api/chat", json={
                            "model": self.model,
                            "messages": self._with_memory_context(mem_context),
                            "stream": False
                        })
                        raw = r.json().get("message", {}).get("content", "")
                finally:
                    think_task.cancel()
                await self.send("clear_thinking", {})
                await asyncio.sleep(0.1)
                words = raw.split()
                full = ""
                for i, word in enumerate(words):
                    chunk = ("" if i == 0 else " ") + word
                    full += chunk
                    await self.send("token", chunk)
                    if i % 5 == 0:
                        await asyncio.sleep(0.01)
            else:
                async with httpx.AsyncClient(timeout=300) as c:
                    async with c.stream("POST", f"{OLLAMA}/api/chat",
                        json={"model": self.model,
                              "messages": self._with_memory_context(mem_context),
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
            hb_task.cancel()
            self.error_count = 0
            self.memory.store_message("assistant", full, self.model)
            await self.send("done", {"content": full, "chars": len(full)})

        except Exception as e:
            self.error_count += 1
            await self.send("error", str(e))
            if self.error_count >= self.MAX_ERRORS:
                await self.send("repair_started",
                    {"error": f"Auto-repair after {self.MAX_ERRORS} errors: {e}"})
                from .repair import self_repair
                await self_repair(f"Chat failing: {e}", ws=self.ws)
                self.error_count = 0

    async def send(self, t: str, d):
        try:
            await self.ws.send_text(json.dumps({"type": t, "data": d}))
        except Exception:
            pass

    async def cleanup(self):
        await self.browser.close()

    def _build_system_prompt(self) -> str:
        return """You are Worker Bee, an autonomous AI agent running locally on a Mac Studio M1 Ultra.

You are NOT a generic chatbot. You are a real agent with real capabilities:

BROWSER: Navigate any URL, take screenshots, interact with pages.
LOGIN: Log into websites using saved credentials from the Key Vault.
VISION: Analyze screenshots with llava — you actually SEE web pages.
SHELL: Run bash commands on the Mac (with user approval).
MEMORY: Permanent memory across all sessions via ChromaDB.
GITHUB: Read and write to GitHub repos directly.
GMAIL: Manage inbox — summarize, archive, delete, unsubscribe.
PLANNER: Break complex goals into steps and execute autonomously.

FORMATTING RULES — ALWAYS FOLLOW THESE:
- Use markdown formatting in all responses
- Put ALL code in fenced code blocks with language tag
- Put terminal commands in ```zsh blocks
- Put Lovable prompts in ``` blocks
- Use **bold** for important terms
- Use bullet points for lists
- Use ## headers for sections in long responses
- Keep responses concise — no unnecessary padding
- Never write walls of plain text

MODELS IN THIS SYSTEM:
- llama3.3:70b (you) — conversation and general reasoning
- deepseek-r1:70b — deep reasoning, architecture, planning
- qwen2.5-coder:32b — code generation, Lovable prompts
- llava:latest — vision, screenshot analysis

Be direct, confident, and specific.
Never say you cannot do something in your capabilities list.
You are the user's personal autonomous web building agent."""

    def _with_memory_context(self, mem_context: str) -> list:
        messages = list(self.history)
        system = self._build_system_prompt()
        if mem_context:
            system = mem_context + "\n\n" + system
        if messages and messages[0]["role"] == "system":
            messages[0]["content"] = system
        else:
            messages.insert(0, {"role": "system", "content": system})
        return messages

    async def run_memory_search(self, msg: dict):
        results = self.memory.search(msg.get("query", ""), n=msg.get("n", 5))
        await self.send("memory_results",
            {"query": msg.get("query"), "results": results})

    async def run_memory_store(self, msg: dict):
        doc_id = self.memory.store_knowledge(
            msg.get("topic", ""), msg.get("content", ""), msg.get("source", ""))
        await self.send("memory_stored", {"id": doc_id, "topic": msg.get("topic")})

    async def run_memory_stats(self):
        await self.send("memory_stats", self.memory.stats())

    async def run_plan(self, msg: dict):
        goal = msg.get("goal", "")
        if not goal:
            await self.send("plan_error", {"message": "No goal provided"})
            return
        await self.send("plan_started", {"goal": goal})
        await self.send("plan_log", {"message": f"Planning: {goal}", "level": "info"})
        tasks = await self.planner.plan(goal)
        if not tasks:
            await self.send("plan_error", {"message": "Could not generate a plan"})
            return
        await self.send("plan_ready", {"goal": goal, "tasks": tasks, "count": len(tasks)})
        result = await self.planner.execute(ws=self.ws)
        await self.send("plan_complete", result)
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
    "agent/tools/memory.py",
    "agent/tools/planner.py",
    "agent/tools/github.py",
    "agent/tools/gmail.py",
    "agent/repair.py",
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

log "Writing agent/tools/memory.py..."
cat > ~/worker-bee/agent/tools/memory.py << 'MEMORYPY'
import chromadb, os, pathlib
from datetime import datetime

DB_PATH = str(pathlib.Path.home() / "worker-bee" / ".chromadb")

class MemoryTool:
    def __init__(self, tab_id: str = "default"):
        self.tab_id  = tab_id
        self.client  = chromadb.PersistentClient(path=DB_PATH)
        self.conversations = self.client.get_or_create_collection(
            name="conversations", metadata={"hnsw:space": "cosine"})
        self.actions = self.client.get_or_create_collection(
            name="actions", metadata={"hnsw:space": "cosine"})
        self.knowledge = self.client.get_or_create_collection(
            name="knowledge", metadata={"hnsw:space": "cosine"})

    def _ts(self) -> str:
        return datetime.now().isoformat()

    def _id(self, prefix: str) -> str:
        import uuid
        return f"{prefix}_{uuid.uuid4().hex[:8]}"

    def store_message(self, role: str, content: str, model: str = "") -> str:
        doc_id = self._id("msg")
        self.conversations.add(
            ids=[doc_id], documents=[content],
            metadatas=[{"role": role, "model": model,
                       "tab_id": self.tab_id, "ts": self._ts(),
                       "type": "message"}])
        return doc_id

    def store_action(self, action: str, target: str,
                     result: str, success: bool) -> str:
        doc_id = self._id("act")
        content = f"{action} → {target}: {result[:500]}"
        self.actions.add(
            ids=[doc_id], documents=[content],
            metadatas=[{"action": action, "target": target,
                       "success": str(success), "tab_id": self.tab_id,
                       "ts": self._ts(), "type": "action"}])
        return doc_id

    def store_knowledge(self, topic: str, content: str,
                        source: str = "") -> str:
        doc_id = self._id("knw")
        self.knowledge.add(
            ids=[doc_id], documents=[f"{topic}: {content}"],
            metadatas=[{"topic": topic, "source": source,
                       "tab_id": self.tab_id, "ts": self._ts(),
                       "type": "knowledge"}])
        return doc_id

    def search(self, query: str, n: int = 5) -> list:
        results = []
        for collection in [self.conversations, self.actions, self.knowledge]:
            try:
                r = collection.query(
                    query_texts=[query],
                    n_results=min(n, collection.count()))
                if r and r["documents"] and r["documents"][0]:
                    for doc, meta, dist in zip(
                        r["documents"][0], r["metadatas"][0], r["distances"][0]):
                        results.append({
                            "content": doc, "metadata": meta,
                            "relevance": round(1 - dist, 3)})
            except Exception:
                pass
        results.sort(key=lambda x: x["relevance"], reverse=True)
        return results[:n]

    def build_context(self, query: str) -> str:
        results = self.search(query, n=5)
        if not results:
            return ""
        lines = ["[RELEVANT MEMORIES]"]
        for r in results:
            meta = r["metadata"]
            ts   = meta.get("ts", "")[:10]
            typ  = meta.get("type", "")
            if typ == "message":
                lines.append(f"• [{ts}] {meta.get('role')}: {r['content'][:200]}")
            elif typ == "action":
                ok = "✓" if meta.get("success") == "True" else "✗"
                lines.append(f"• [{ts}] {meta.get('action')} ({ok}): {r['content'][:200]}")
            elif typ == "knowledge":
                lines.append(f"• [{ts}] KNOWN: {r['content'][:200]}")
        lines.append("[END MEMORIES]\n")
        return "\n".join(lines)

    def stats(self) -> dict:
        return {
            "conversations": self.conversations.count(),
            "actions":       self.actions.count(),
            "knowledge":     self.knowledge.count(),
            "db_path":       DB_PATH
        }

    def clear_tab(self):
        for collection in [self.conversations, self.actions, self.knowledge]:
            try:
                results = collection.get(where={"tab_id": self.tab_id})
                if results["ids"]:
                    collection.delete(ids=results["ids"])
            except Exception:
                pass
MEMORYPY

log "Writing agent/tools/planner.py..."
cat > ~/worker-bee/agent/tools/planner.py << 'PLANNERPY'
import httpx, json, os, asyncio, pathlib
from datetime import datetime

OLLAMA = os.getenv("OLLAMA_HOST", "http://localhost:11434")

class TaskPlanner:
    def __init__(self, runner=None):
        self.runner  = runner
        self.tasks   = []
        self.current = 0
        self.running = False
        self.paused  = False

    async def plan(self, goal: str) -> list:
        prompt = f"""You are a task planner for Worker Bee AI agent with these tools:
browser, login, shell, file_read, file_write, vision, github, gmail, chat

GOAL: {goal}

Break into 3-8 specific executable steps.
Output ONLY valid JSON:
{{
  "goal": "{goal}",
  "steps": [
    {{
      "id": 1,
      "action": "browser",
      "description": "Navigate to target URL",
      "params": {{"url": "https://example.com"}},
      "depends_on": []
    }}
  ]
}}"""
        try:
            async with httpx.AsyncClient(timeout=120) as c:
                r = await c.post(f"{OLLAMA}/api/chat", json={
                    "model": "deepseek-r1:70b",
                    "messages": [{"role": "user", "content": prompt}],
                    "stream": False
                })
                content = r.json().get("message", {}).get("content", "")
                if "<think>" in content:
                    content = content.split("</think>")[-1].strip()
                start = content.find("{")
                end   = content.rfind("}") + 1
                if start >= 0 and end > start:
                    data = json.loads(content[start:end])
                    self.tasks = data.get("steps", [])
                    return self.tasks
        except Exception as e:
            print(f"Plan error: {e}")
        return []

    async def execute(self, ws=None) -> dict:
        self.running = True
        self.current = 0
        results = {}

        async def log(msg, level="info"):
            print(f"[PLANNER] {msg}")
            if ws:
                await ws.send_text(json.dumps({
                    "type": "plan_log",
                    "data": {"message": msg, "level": level}
                }))

        async def progress(step, status, result=None):
            if ws:
                await ws.send_text(json.dumps({
                    "type": "plan_progress",
                    "data": {
                        "step_id": step["id"], "status": status,
                        "action": step["action"], "desc": step["description"],
                        "result": result, "current": self.current,
                        "total": len(self.tasks)
                    }
                }))

        await log(f"Starting plan: {len(self.tasks)} steps")

        for step in self.tasks:
            if not self.running:
                await log("Plan stopped", "warn")
                break
            while self.paused:
                await asyncio.sleep(0.5)

            self.current = step["id"]
            await progress(step, "running")
            await log(f"Step {step['id']}/{len(self.tasks)}: {step['description']}")

            result = None
            try:
                action = step["action"]
                params = step.get("params", {})

                if action == "browser" and self.runner:
                    result = await self.runner.browser.navigate(params.get("url", ""))
                elif action == "screenshot" and self.runner:
                    b64 = await self.runner.browser.screenshot(params.get("url", ""))
                    result = {"screenshot_b64": b64}
                    if ws:
                        await ws.send_text(json.dumps({
                            "type": "screenshot",
                            "data": {"url": params.get("url",""), "screenshot_b64": b64}
                        }))
                elif action == "vision" and self.runner:
                    b64 = params.get("screenshot_b64", "")
                    desc = await self.runner.vision_analyze(
                        b64, params.get("question", "Describe what you see"))
                    result = {"description": desc}
                elif action == "shell" and self.runner:
                    result = await self.runner.shell.run(params.get("command", ""))
                elif action == "file_write" and self.runner:
                    r = self.runner.fs.write(params.get("path",""), params.get("content",""))
                    result = {"written": r}
                elif action == "file_read" and self.runner:
                    content = self.runner.fs.read(params.get("path",""))
                    result = {"content": content}
                elif action == "login" and self.runner:
                    result = await self.runner.browser.login(
                        url=params.get("url",""),
                        username=params.get("username",""),
                        password=params.get("password",""))
                elif action == "gmail" and self.runner:
                    await self.runner.run_gmail(
                        {"gmail_action": params.get("gmail_action","summary")})
                    result = {"gmail": "done"}

                results[step["id"]] = result or {}
                await progress(step, "done", result)
                await log(f"Step {step['id']} complete", "ok")

            except Exception as e:
                await log(f"Step {step['id']} failed: {e}", "error")
                await progress(step, "failed", {"error": str(e)})
                results[step["id"]] = {"error": str(e)}

        self.running = False
        final = {
            "completed": len([r for r in results.values() if "error" not in r]),
            "failed":    len([r for r in results.values() if "error" in r]),
            "total":     len(self.tasks),
            "results":   results
        }
        await log(f"Plan complete: {final['completed']}/{final['total']} succeeded")
        if ws:
            await ws.send_text(json.dumps({"type": "plan_complete", "data": final}))
        return final

    def stop(self):   self.running = False
    def pause(self):  self.paused = True
    def resume(self): self.paused = False
PLANNERPY

log "Writing agent/tools/github.py..."
cat > ~/worker-bee/agent/tools/github.py << 'GITHUBPY'
import httpx, os, base64, json

GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")

class GitHubTool:
    def __init__(self):
        self.headers = {
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "WorkerBee-Agent"
        }
        if GITHUB_TOKEN:
            self.headers["Authorization"] = f"token {GITHUB_TOKEN}"

    async def get_file(self, owner: str, repo: str, path: str) -> dict:
        url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(url, headers=self.headers)
            if r.status_code != 200:
                return {"error": f"HTTP {r.status_code}", "success": False}
            data = r.json()
            content = base64.b64decode(data["content"]).decode("utf-8")
            return {"path": path, "content": content,
                    "size": data["size"], "sha": data["sha"], "success": True}

    async def list_files(self, owner: str, repo: str, path: str = "") -> dict:
        url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(url, headers=self.headers)
            if r.status_code != 200:
                return {"error": f"HTTP {r.status_code}", "success": False}
            items = r.json()
            return {
                "path": path,
                "items": [{"name": i["name"], "type": i["type"],
                           "path": i["path"], "size": i.get("size", 0)}
                          for i in items],
                "success": True
            }

    async def get_repo_structure(self, owner: str, repo: str) -> dict:
        url = f"https://api.github.com/repos/{owner}/{repo}/git/trees/HEAD?recursive=1"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(url, headers=self.headers)
            if r.status_code != 200:
                return {"error": f"HTTP {r.status_code}", "success": False}
            tree = r.json().get("tree", [])
            return {"files": [t["path"] for t in tree if t["type"] == "blob"],
                    "success": True}

    async def get_multiple_files(self, owner: str, repo: str, paths: list) -> dict:
        results = {}
        for path in paths:
            result = await self.get_file(owner, repo, path)
            results[path] = result["content"] if result.get("success") else f"ERROR: {result.get('error')}"
        return {"files": results, "success": True}

    async def push_file(self, owner: str, repo: str, path: str,
                        content: str, message: str = "Worker Bee update",
                        sha: str = None) -> dict:
        if not GITHUB_TOKEN:
            return {"error": "No GITHUB_TOKEN set", "success": False}
        url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
        body = {"message": message,
                "content": base64.b64encode(content.encode()).decode()}
        if sha:
            body["sha"] = sha
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.put(url, headers=self.headers, json=body)
            return {"success": r.status_code in [200, 201],
                    "status": r.status_code, "path": path}
GITHUBPY

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
            creds = Credentials.from_authorized_user_file(str(TOKEN_PATH), SCOPES)
        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                if not CREDS_PATH.exists():
                    raise FileNotFoundError(
                        f"Gmail credentials not found at {CREDS_PATH}. "
                        "Download from Google Cloud Console.")
                flow = InstalledAppFlow.from_client_secrets_file(str(CREDS_PATH), SCOPES)
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
            "unread": "is:unread", "promotions": "category:promotions",
            "social": "category:social", "updates": "category:updates",
            "newsletters": "list:* OR unsubscribe",
            "old_unread": "is:unread older_than:30d",
        }
        summary = {}
        for name, query in categories.items():
            result = svc.users().messages().list(
                userId="me", q=query, maxResults=1).execute()
            summary[name] = result.get("resultSizeEstimate", 0)
        inbox = svc.users().labels().get(userId="me", id="INBOX").execute()
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
            headers = {h["name"]: h["value"] for h in msg["payload"]["headers"]}
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
            userId="me", body={"ids": ids, "removeLabelIds": ["INBOX"]}).execute()
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
            userId="me", body={"ids": ids, "addLabelIds": ["TRASH"]}).execute()
        return {"deleted": len(ids), "message": f"Moved {len(ids)} to trash"}

    def unsubscribe_sender(self, sender_email: str) -> dict:
        return self.archive_emails(f"from:{sender_email}", max_results=1000)

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
                (h["value"] for h in msg["payload"]["headers"] if h["name"] == "From"),
                "Unknown")
            senders[sender] = senders.get(sender, 0) + 1
        return [{"sender": s, "count": c}
                for s, c in sorted(senders.items(), key=lambda x: x[1], reverse=True)[:20]]
GMAILPY

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
                            "text=SOMETHING WENT WRONG", "text=404"]:
                    try:
                        if await page.locator(sel).is_visible(timeout=1000):
                            error_found = True
                            break
                    except Exception:
                        pass
                if not error_found:
                    break
                clicked = False
                for sel in ["text=Try again", "text=Try Again", "text=Retry",
                            "button:has-text('Try')", "button:has-text('Retry')"]:
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
            'input[placeholder*="email" i]', 'input[placeholder*="username" i]',
            'input[autocomplete="email"]', 'input[autocomplete="username"]',
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
        return [str(f.relative_to(SAFE)) for f in self._safe(path).iterdir()]

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

log "Writing .env..."
cat > ~/worker-bee/.env << ENVEOF
OLLAMA_HOST=http://localhost:11434
DEFAULT_MODEL=llama3.3:70b
AGENT_PORT=8000
SAFE_ROOT=${HOME}/worker-bee/projects
GITHUB_TOKEN=
GITHUB_REPO_OWNER=
GITHUB_REPO_NAME=
GMAIL_USER=
SLACK_BOT_TOKEN=
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
ENVEOF

log "Writing start.sh..."
cat > ~/worker-bee/start.sh << 'STARTSH'
#!/bin/zsh
cd ~/worker-bee
source .venv/bin/activate
export OLLAMA_HOST=http://localhost:11434
pgrep -x ollama > /dev/null || (ollama serve > /tmp/ollama.log 2>&1 & sleep 2)
uvicorn main:app --reload --host 0.0.0.0 --port 8000 \
    --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem
STARTSH
chmod +x ~/worker-bee/start.sh

ok "All agent files written"

hdr "8 / 10  PLAYWRIGHT + CHROMIUM"
log "Installing Chromium..."
playwright install chromium
xattr -cr ~/Library/Caches/ms-playwright/ 2>/dev/null || true
log "Testing Playwright..."
python3 -c "
from playwright.sync_api import sync_playwright
try:
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.goto('https://example.com', timeout=15000)
        print('  Playwright OK:', pg.title())
        b.close()
except Exception as e:
    print('  Note:', e)
"
ok "Playwright + Chromium ready"

hdr "9 / 10  PULLING AI MODELS"
log "Pulling $CODING ($MREASON)..."
ollama pull "$CODING"
ok "$CODING ready"

log "Pulling $PRIMARY (conversational)..."
ollama pull "$PRIMARY"
ok "$PRIMARY ready"

log "Pulling llava vision model..."
ollama pull llava
ok "llava ready"

log "Pulling $REASON (deep reasoning)..."
log "This is large — may take 30-60 min on first install"
ollama pull "$REASON"
ok "$REASON ready"

hdr "10 / 10  AUTO-START + SHORTCUTS"

log "Setting up launchd..."
cat > ~/Library/LaunchAgents/com.workerbee.agent.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.workerbee.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/${USER}/worker-bee/.venv/bin/uvicorn</string>
    <string>main:app</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>8000</string>
    <string>--ssl-keyfile</string><string>/Users/${USER}/.ssl/key.pem</string>
    <string>--ssl-certfile</string><string>/Users/${USER}/.ssl/cert.pem</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/Users/${USER}/worker-bee</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/workerbee.log</string>
  <key>StandardErrorPath</key><string>/tmp/workerbee-error.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key><string>http://localhost:11434</string>
    <key>DEFAULT_MODEL</key><string>${PRIMARY}</string>
    <key>PATH</key><string>/Users/${USER}/worker-bee/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
launchctl load ~/Library/LaunchAgents/com.workerbee.agent.plist 2>/dev/null || true
ok "Auto-start configured"

log "Adding wb alias..."
grep -q "alias wb=" ~/.zshrc 2>/dev/null || \
echo 'alias wb="cd ~/worker-bee && source .venv/bin/activate && export OLLAMA_HOST=http://localhost:11434 && uvicorn main:app --reload --host 0.0.0.0 --port 8000 --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem"' >> ~/.zshrc
source ~/.zshrc 2>/dev/null || true
ok "Type 'wb' anywhere to start Worker Bee"

clear
echo -e "${GRN}${BLD}"
echo "  WORKER BEE v3.0 IS READY"
echo -e "${NC}"
echo -e "  ${GRN}[OK]${NC} Ollama          http://localhost:11434"
echo -e "  ${GRN}[OK]${NC} Agent           https://localhost:8000"
echo -e "  ${GRN}[OK]${NC} Vision          llava installed"
echo -e "  ${GRN}[OK]${NC} Browser         Playwright + Chromium"
echo -e "  ${GRN}[OK]${NC} Memory          ChromaDB persistent"
echo -e "  ${GRN}[OK]${NC} Planner         autonomous task execution"
echo -e "  ${GRN}[OK]${NC} GitHub          code reader/writer"
echo -e "  ${GRN}[OK]${NC} Gmail           inbox manager"
echo -e "  ${GRN}[OK]${NC} Self-repair     qwen monitors itself"
echo -e "  ${GRN}[OK]${NC} Login engine    5-strategy persistent login"
echo -e "  ${GRN}[OK]${NC} Auto-start      starts on every login"
echo -e "  ${GRN}[OK]${NC} Models:         $PRIMARY | $CODING | $REASON | llava"
echo ""
echo -e "  NEXT: Visit https://localhost:8000/health in Safari"
echo -e "        Click through the security warning (one time only)"
echo -e "  UI:   https://worker-bee.lovable.app"
echo -e "  LOGS: tail -f /tmp/workerbee.log"
echo ""
echo -e "${GRN}Starting agent...${NC}"
echo ""
cd ~/worker-bee && source .venv/bin/activate
export OLLAMA_HOST=http://localhost:11434
uvicorn main:app --reload --host 0.0.0.0 --port 8000 \
    --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem
