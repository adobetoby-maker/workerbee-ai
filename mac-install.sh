#!/bin/bash
# ================================================================
#  🐝 WORKER BEE — MAC INSTALLER v3.2
#  Paste into macOS Terminal and press Enter.
#  Installs everything. Takes 10-30 min. Do not close window.
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
echo "  🐝  WORKER BEE — MAC INSTALLER v3.2"
echo "  ======================================"
echo -e "${NC}${DIM}  Homebrew · Python · uv · Ollama · FastAPI"
echo -e "  Playwright · ChromaDB · Voice · Builder · Vision${NC}"
echo ""

hdr "1 / 10  DETECTING YOUR MAC"
ARCH=$(uname -m)
RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
OS=$(sw_vers -productVersion)
log "Arch: $ARCH  |  RAM: ${RAM_GB}GB  |  macOS: $OS"
[ "$ARCH" = "arm64" ] && ok "Apple Silicon — Metal GPU" || warn "Intel Mac — CPU only"

if   [ "$RAM_GB" -ge 64 ]; then
    PRIMARY="llama3.3:70b"; CODING="qwen2.5-coder:32b"
    REASON="deepseek-r1:70b"; MREASON="64GB+ full stack"
elif [ "$RAM_GB" -ge 32 ]; then
    PRIMARY="llama3.2"; CODING="qwen2.5-coder:32b"
    REASON="deepseek-r1:32b"; MREASON="32GB balanced"
else
    PRIMARY="llama3.2:3b"; CODING="qwen2.5-coder:7b"
    REASON="phi4"; MREASON="16GB light"
fi
ok "Models: $PRIMARY | $CODING | $REASON ($MREASON)"
sleep 1

hdr "2 / 10  HOMEBREW"
if command -v brew &>/dev/null; then
    ok "Already installed"; brew update --quiet 2>/dev/null || true
else
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ "$ARCH" = "arm64" ]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi
ok "Homebrew ready"

hdr "3 / 10  PYTHON + UV + SYSTEM TOOLS"
python3 --version 2>&1 | grep -qE "3\.1[2-9]" || brew install python@3.12 --quiet
brew install sox ffmpeg node 2>/dev/null || true
if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
fi
ok "Python + uv + sox + ffmpeg + node ready"

hdr "4 / 10  OLLAMA"
command -v ollama &>/dev/null || brew install ollama --quiet
grep -q "OLLAMA_HOST" ~/.zshrc 2>/dev/null || \
    echo 'export OLLAMA_HOST=http://localhost:11434' >> ~/.zshrc
export OLLAMA_HOST=http://localhost:11434
pgrep -x ollama > /dev/null || (ollama serve > /tmp/ollama.log 2>&1 & sleep 3)
ok "Ollama running on :11434"

hdr "5 / 10  PROJECT FOLDER + VENV"
mkdir -p ~/worker-bee/agent/tools ~/worker-bee/projects ~/worker-bee/.cookies
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
    openai-whisper sounddevice scipy numpy \
    kokoro huggingface_hub \
    slack-sdk twilio --quiet
ok "All packages installed"

hdr "6 / 10  SSL CERTIFICATE"
mkdir -p ~/.ssl
[ -f ~/.ssl/key.pem ] || openssl req -x509 -newkey rsa:4096 \
    -keyout ~/.ssl/key.pem -out ~/.ssl/cert.pem \
    -days 365 -nodes -subj "/CN=localhost" 2>/dev/null
ok "SSL cert ready"

hdr "7 / 10  WRITING ALL AGENT FILES"

log "Writing main.py..."
cat > ~/worker-bee/main.py << 'MAINPY'
import asyncio
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
voice_daemon_ws = None

@app.get("/health")
async def health():
    return {"status": "ok", "service": "worker-bee-agent", "version": "3.2.0"}

@app.get("/api/tags")
async def tags():
    import httpx
    base = os.getenv("OLLAMA_HOST", "http://localhost:11434")
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(f"{base}/api/tags")
        return r.json()

@app.get("/api/ps")
async def ps():
    import httpx
    base = os.getenv("OLLAMA_HOST", "http://localhost:11434")
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(f"{base}/api/ps")
        return r.json()

@app.websocket("/ws/voice-daemon")
async def voice_daemon_endpoint(ws: WebSocket):
    global voice_daemon_ws
    await ws.accept()
    voice_daemon_ws = ws
    print("[VOICE DAEMON] Connected")
    try:
        while True:
            data = await ws.receive_text()
            msg = json.loads(data)
            if msg.get("type") == "voice_transcription":
                for runner in runners.values():
                    await runner.send("voice_transcription", msg.get("data", {}))
                    break
    except Exception:
        voice_daemon_ws = None
        print("[VOICE DAEMON] Disconnected")

@app.websocket("/ws/{tab_id}")
async def ws_endpoint(ws: WebSocket, tab_id: str):
    await ws.accept()
    runner = AgentRunner(tab_id, ws)
    runners[tab_id] = runner
    try:
        while True:
            data = await ws.receive_text()
            asyncio.create_task(runner.handle(json.loads(data)))
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
MODEL  = os.getenv("DEFAULT_MODEL", "llama3.2")

def pick_model(message: str) -> str:
    msg = message.lower()
    if any(w in msg for w in ["screenshot","see ","look at","image","visual","what do you see"]):
        return "llava:latest"
    if any(w in msg for w in ["code","build","write a","fix the","debug","html","css","javascript",
        "python","function","class","component","script","react","typescript","create a","generate",
        "refactor","landing page","website","webpage","button","form","style","animation"]):
        return os.getenv("CODING_MODEL", "qwen2.5-coder:32b")
    if any(w in msg for w in ["why ","explain","analyze","diagnose","architect","strategy","should i",
        "best way","review","audit","plan","compare","recommend","reason","think through",
        "how does","deep dive","comprehensive","thorough"]):
        return os.getenv("REASON_MODEL", "deepseek-r1:32b")
    return MODEL

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
        print(f"[ACTION] {a} — {str(msg)[:120]}")
        if   a == "chat":              await self.chat(msg)
        elif a == "browser":           await self.run_browser(msg)
        elif a == "shell":             await self.run_shell(msg)
        elif a == "vision":            await self.run_vision(msg)
        elif a == "login":             await self.run_login(msg)
        elif a == "gmail":             await self.run_gmail(msg)
        elif a == "get_tags":          await self.run_get_tags()
        elif a == "get_ps":            await self.run_get_ps()
        elif a == "github":            await self.run_github(msg)
        elif a == "self_repair":       await self.run_self_repair(msg)
        elif a == "plan":              await self.run_plan(msg)
        elif a == "plan_stop":         self.planner.stop()
        elif a == "plan_pause":        self.planner.pause()
        elif a == "plan_resume":       self.planner.resume()
        elif a == "memory_search":     await self.run_memory_search(msg)
        elif a == "memory_store":      await self.run_memory_store(msg)
        elif a == "memory_stats":      await self.run_memory_stats()
        elif a == "vision_report":     await self.run_vision_report(msg)
        elif a == "save_cookies":      await self.run_save_cookies(msg)
        elif a == "learn_now":         await self.run_learn_now(msg)
        elif a == "speak":             await self.run_speak(msg)
        elif a == "voice_input":       await self.run_voice_input(msg)
        elif a == "voice_transcribe":  await self.run_voice_transcribe(msg)
        elif a == "index_site":        await self.run_index_site(msg)
        elif a == "build":             await self.run_build(msg)
        elif a == "build_start":       await self.run_build_start(msg)
        elif a == "dev_server_start":  await self.run_dev_server(msg)
        elif a == "dev_server_stop":   await self.run_dev_server_stop(msg)
        elif a == "scaffold":          await self.run_scaffold(msg)
        elif a == "list_projects":     await self.run_list_projects()
        elif a == "file_read":
            try:
                await self.send("file_content", {"path": msg["path"], "content": self.fs.read(msg["path"])})
            except Exception as e:
                await self.send("error", str(e))
        elif a == "file_write":
            try:
                await self.send("file_written", {"result": self.fs.write(msg["path"], msg["content"])})
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
            await self.send("screenshot", {"url": result["url"], "screenshot_b64": result["screenshot_b64"]})
            vision = await self.vision_analyze(result["screenshot_b64"],
                "Analyze: 1) Purpose 2) Design 3) Key UI 4) Issues")
            result["vision_description"] = vision
        await self.send("browser_result", result)

    async def run_shell(self, msg: dict):
        await self.send("status", "shell_working")
        result = await self.shell.run(msg["command"])
        await self.send("shell_result", result)

    async def run_vision(self, msg: dict):
        await self.send("status", "vision_working")
        description = await self.vision_analyze(
            msg.get("screenshot_b64", ""), msg.get("question", "What do you see?"))
        await self.send("vision_result", {"description": description})

    async def run_login(self, msg: dict):
        await self.send("status", "login_working")
        await self.send("login_log", f"Attempting login to {msg.get('url')}...")
        result = await self.browser.login(
            url=msg.get("url", ""), username=msg.get("username", ""),
            password=msg.get("password", ""), max_attempts=msg.get("max_attempts", 5))
        if result.get("success"):
            await self.send("login_log", f"Logged in after {result.get('attempts', 1)} attempt(s)")
            if result.get("screenshot_b64"):
                await self.send("screenshot", {"url": result["url"], "screenshot_b64": result["screenshot_b64"]})
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
                await self.send("gmail_preview", gmail.get_emails(msg.get("query", "in:inbox")))
            elif action == "archive":
                await self.send("gmail_done", {"action": "archive", **gmail.archive_emails(msg.get("query", ""))})
            elif action == "delete":
                await self.send("gmail_done", {"action": "delete", **gmail.delete_emails(msg.get("query", ""))})
            elif action == "unsubscribe":
                await self.send("gmail_done", {"action": "unsubscribe", **gmail.unsubscribe_sender(msg.get("sender", ""))})
        except Exception as e:
            await self.send("gmail_error", {"message": str(e)})

    async def run_github(self, msg: dict):
        from .tools.github import GitHubTool
        gh = GitHubTool()
        action = msg.get("github_action")
        owner  = msg.get("owner", os.getenv("GITHUB_REPO_OWNER", ""))
        repo   = msg.get("repo", os.getenv("GITHUB_REPO_NAME", ""))
        if action == "get_file":
            await self.send("github_file", await gh.get_file(owner, repo, msg.get("path", "")))
        elif action == "list_files":
            await self.send("github_files", await gh.list_files(owner, repo, msg.get("path", "")))
        elif action == "get_structure":
            await self.send("github_structure", await gh.get_repo_structure(owner, repo))
        elif action == "get_multiple":
            await self.send("github_files_batch", await gh.get_multiple_files(owner, repo, msg.get("paths", [])))
        elif action == "push_file":
            await self.send("github_push_result", await gh.push_file(
                owner, repo, msg.get("path", ""), msg.get("content", ""),
                msg.get("message", "Worker Bee update"), msg.get("sha", None)))

    async def run_self_repair(self, msg: dict):
        from .repair import self_repair
        await self.send("repair_started", {"error": msg.get("error", "Manual repair")})
        success = await self_repair(msg.get("error", "Manual repair"), ws=self.ws)
        await self.send("repair_complete", {"success": success})

    async def run_vision_report(self, msg: dict):
        from .tools.vision_reporter import VisionReporter
        vr = VisionReporter()
        url   = msg.get("url", "https://worker-bee.lovable.app")
        label = msg.get("label", "worker-bee-ui")
        await self.send("status", "Taking screenshot...")
        result = await self.browser.navigate(url)
        if not result.get("success"):
            await self.send("error", f"Screenshot failed: {result.get('error')}")
            return
        screenshot_b64 = result.get("screenshot_b64", "")
        await self.send("status", "Analyzing with llava...")
        vision = await self.vision_analyze(screenshot_b64,
            "Analyze Worker Bee UI: 1) Layout 2) Design 3) Issues 4) Compare to Claude.ai")
        await self.send("status", "Pushing to GitHub...")
        push_result = await vr.push_screenshot(screenshot_b64, label=label, description=vision)
        if push_result.get("success"):
            await self.send("screenshot", {"url": url, "screenshot_b64": screenshot_b64})
            await self.send("vision_result", {"description": vision})
            await self.send("vision_report_done", {
                "github_url": push_result["github_url"],
                "raw_url": push_result["url"],
                "label": label, "analysis": vision
            })
        else:
            await self.send("error", f"Push failed: {push_result.get('error')}")

    async def run_save_cookies(self, msg: dict):
        try:
            from .tools.cookies import save_cookies
            path = save_cookies(msg.get("domain", ""), msg.get("cookies", []))
            await self.send("cookies_saved", {
                "domain": msg.get("domain"), "count": len(msg.get("cookies", [])), "path": path})
        except Exception as e:
            await self.send("error", str(e))

    async def run_learn_now(self, msg: dict):
        from .tools.learner import learn_session
        await self.send("status", "Learning from the web...")
        async def log_fn(m): await self.send("token", f"\n{m}")
        count = await learn_session(memory=self.memory, log_fn=log_fn)
        await self.send("done", {"content": f"\n✅ Learning complete — {count} sources processed.", "chars": 50})

    async def run_speak(self, msg: dict):
        import re
        text = msg.get("text", "")
        if not text: return
        text = re.sub(r'\*\*|__|\*|_|#{1,6} |`', '', text)[:500]
        proc = await asyncio.create_subprocess_shell(
            f'say "{text}"', stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await proc.wait()
        await self.send("speak_done", {"success": True})

    async def run_voice_input(self, msg: dict):
        import main as app_main
        await self.send("status", "listening")
        if app_main.voice_daemon_ws:
            await app_main.voice_daemon_ws.send_text(json.dumps({
                "type": "voice_request", "seconds": msg.get("seconds", 5)}))
        else:
            from .tools.ears import listen
            result = await listen(seconds=msg.get("seconds", 5), gain=15)
            if result.get("success") and result.get("text"):
                await self.send("voice_transcription", {"text": result["text"]})
            else:
                await self.send("voice_error", {"message": result.get("error", "No speech detected")})

    async def run_voice_transcribe(self, msg: dict):
        import base64, pathlib
        audio_b64 = msg.get("audio_b64", "")
        fmt = msg.get("format", "webm")
        if not audio_b64:
            await self.send("voice_error", {"message": "No audio received"}); return
        raw_path = pathlib.Path(f"/tmp/wb_voice.{fmt}")
        wav_path = pathlib.Path("/tmp/wb_voice.wav")
        raw_path.write_bytes(base64.b64decode(audio_b64))
        proc = await asyncio.create_subprocess_shell(
            f"ffmpeg -y -i {raw_path} -ar 16000 -ac 1 {wav_path}",
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await proc.wait()
        from .tools.ears import get_model
        model = get_model()
        result = model.transcribe(str(wav_path), language="en", fp16=False)
        text = result["text"].strip()
        if text:
            await self.send("voice_transcription", {"text": text})
        else:
            await self.send("voice_error", {"message": "No speech detected"})

    async def run_index_site(self, msg: dict):
        from .tools.site_indexer import index_site
        url = msg.get("url", "")
        if not url:
            await self.send("error", "URL required"); return
        await self.send("index_started", {"url": url})
        async def log_fn(m): await self.send("index_log", {"message": m})
        result = await index_site(url=url, browser=self.browser,
            vision_analyze_fn=self.vision_analyze, log_fn=log_fn)
        if result.get("success"):
            await self.send("index_complete", result)
            await self.send("done", {
                "content": f"✅ Visual index — {result['pages']} pages\n\n📁 {result['index_url']}", "chars": 100})
        else:
            await self.send("error", f"Index failed: {result.get('error')}")

    async def run_scaffold(self, msg: dict):
        from .tools.scaffold import create_project
        import re
        name = re.sub(r'[^a-z0-9-]', '-', msg.get("name", "").lower()).strip('-')
        if not name:
            await self.send("error", "Project name required"); return
        await self.send("build_log", {"message": f"Creating project: {name}..."})
        result = await create_project(name, msg.get("template", "react-ts"))
        await self.send("scaffold_result", result)

    async def run_list_projects(self):
        from .tools.scaffold import list_projects
        projects = list_projects()
        await self.send("projects_list", {"projects": projects, "count": len(projects)})

    async def run_dev_server(self, msg: dict):
        from .tools.devserver import start
        name = msg.get("project", "")
        port = msg.get("port", 5173)
        await self.send("build_log", {"message": f"Starting dev server for {name}..."})
        result = await start(name, port)
        await self.send("dev_server_result", result)

    async def run_dev_server_stop(self, msg: dict):
        from .tools.devserver import stop
        result = await stop(msg.get("project", ""))
        await self.send("dev_server_stopped", result)

    async def run_build(self, msg: dict):
        from .tools.builder import build
        from .tools.scaffold import get_project_files, apply_changes
        prompt  = msg.get("prompt", "")
        project = msg.get("project", "")
        if not prompt or not project:
            await self.send("error", "prompt and project required"); return
        await self.send("build_started", {"prompt": prompt, "project": project})
        use_claude    = msg.get("use_claude", False)
        use_architect = msg.get("use_architect", True)
        current_files = get_project_files(project)
        result = await build(prompt, project, current_files, self.ws,
            use_architect=use_architect, use_claude=use_claude)
        if result.get("success"):
            applied = apply_changes(project, result["files"])
            await self.send("build_applied", {"files": applied, "project": project})
            from .tools.devserver import get_url
            url = get_url(project)
            if url:
                await asyncio.sleep(2)
                shot = await self.browser.navigate(url)
                if shot.get("success"):
                    await self.send("screenshot", {"url": url, "screenshot_b64": shot["screenshot_b64"]})
                    vision = await self.vision_analyze(shot["screenshot_b64"],
                        f"Does this match: '{prompt[:100]}'? Reply YES or describe issues.")
                    await self.send("build_vision", {"vision": vision, "prompt": prompt})
        else:
            await self.send("build_error", result)

    async def run_build_start(self, msg: dict):
        from .tools.builder import build_loop
        result = await build_loop(
            prompt=msg.get("prompt", ""), project_name=msg.get("project", ""),
            runner=self, ws=self.ws, max_iterations=msg.get("iterations", 3))
        await self.send("build_complete", result)

    async def vision_analyze(self, screenshot_b64: str, question: str) -> str:
        try:
            async with httpx.AsyncClient(timeout=60) as c:
                r = await c.post(f"{OLLAMA}/api/generate", json={
                    "model": "llava:latest", "prompt": question,
                    "images": [screenshot_b64], "stream": False})
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
                try: await self.ws.send_text('{"type":"heartbeat","data":"ping"}')
                except: break

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
                            "stream": False})
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
                    if i % 5 == 0: await asyncio.sleep(0.01)
            else:
                async with httpx.AsyncClient(timeout=300) as c:
                    async with c.stream("POST", f"{OLLAMA}/api/chat",
                        json={"model": self.model,
                              "messages": self._with_memory_context(mem_context),
                              "stream": True}) as r:
                        async for line in r.aiter_lines():
                            if not line.strip(): continue
                            try:
                                token = json.loads(line).get("message", {}).get("content", "")
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
                from .repair import self_repair
                await self_repair(f"Chat failing: {e}", ws=self.ws)
                self.error_count = 0

    async def send(self, t: str, d):
        try: await self.ws.send_text(json.dumps({"type": t, "data": d}))
        except: pass

    async def cleanup(self):
        await self.browser.close()

    def _build_system_prompt(self) -> str:
        feedback = self.memory.search("positive response pattern", n=3)
        avoid    = self.memory.search("negative response pattern", n=3)
        feedback_context = ""
        if feedback:
            good = [r["content"][:100] for r in feedback[:2]]
            feedback_context += "RESPONSE STYLES USER LIKES:\n" + "\n".join(f"• {g}" for g in good) + "\n\n"
        if avoid:
            bad = [r["content"][:100] for r in avoid[:2]]
            feedback_context += "RESPONSE STYLES USER DISLIKES:\n" + "\n".join(f"• {b}" for b in bad) + "\n\n"

        return feedback_context + """You are Worker Bee, an autonomous AI agent running locally on a Mac.

You are NOT a generic chatbot. You have REAL capabilities — USE THEM:

BROWSER: Navigate any URL, take screenshots, interact with pages
LOGIN: Log into websites with saved credentials
VISION: Analyze screenshots with llava — you SEE web pages
SHELL: Run bash commands on the Mac
MEMORY: Permanent memory via ChromaDB
GITHUB: Read and write to GitHub repos directly
GMAIL: Manage inbox — summarize, archive, delete, unsubscribe
PLANNER: Break complex goals into steps and execute autonomously
BUILDER: Create React/TypeScript/Tailwind projects with qwen
ARCHITECT: Design briefs with deepseek or Claude API
VOICE: Speak responses aloud, transcribe voice input
VISION REPORT: Screenshot any URL and push to GitHub
SITE INDEX: Crawl entire site, screenshot all pages

FORMATTING:
- Markdown in all responses
- Code in fenced blocks with language tags
- Bold for important terms
- Concise — no padding

MODELS:
- llama3.2 — conversation (you)
- qwen2.5-coder:32b — coding and building
- deepseek-r1 — deep reasoning and planning
- llava — vision and screenshots

ALWAYS execute actions directly. Never just describe doing something — DO IT."""

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
        await self.send("memory_results", {"query": msg.get("query"), "results": results})

    async def run_memory_store(self, msg: dict):
        doc_id = self.memory.store_knowledge(
            msg.get("topic", ""), msg.get("content", ""), msg.get("source", ""))
        await self.send("memory_stored", {"id": doc_id, "topic": msg.get("topic")})

    async def run_memory_stats(self):
        await self.send("memory_stats", self.memory.stats())

    async def run_plan(self, msg: dict):
        goal = msg.get("goal", "")
        if not goal:
            await self.send("plan_error", {"message": "No goal provided"}); return
        await self.send("plan_started", {"goal": goal})
        tasks = await self.planner.plan(goal)
        if not tasks:
            await self.send("plan_error", {"message": "Could not generate plan"}); return
        await self.send("plan_ready", {"goal": goal, "tasks": tasks, "count": len(tasks)})
        result = await self.planner.execute(ws=self.ws)
        await self.send("plan_complete", result)
RUNNERPY

log "Writing agent/repair.py..."
cat > ~/worker-bee/agent/repair.py << 'REPAIRPY'
import httpx, json, os, asyncio, pathlib, sys
from dotenv import dotenv_values

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
OLLAMA = _env.get("OLLAMA_HOST", "http://localhost:11434")
MODEL  = _env.get("CODING_MODEL", "qwen2.5-coder:32b")
ROOT   = pathlib.Path.home() / "worker-bee"

WATCHED_FILES = [
    "main.py", "agent/runner.py",
    "agent/tools/browser.py", "agent/tools/filesystem.py",
    "agent/tools/shell.py", "agent/tools/memory.py",
    "agent/tools/planner.py", "agent/tools/github.py",
    "agent/tools/gmail.py", "agent/tools/vision_reporter.py",
    "agent/tools/cookies.py", "agent/tools/ears.py",
    "agent/tools/mouth.py", "agent/tools/learner.py",
    "agent/tools/scaffold.py", "agent/tools/devserver.py",
    "agent/tools/builder.py", "agent/tools/architect.py",
    "agent/tools/site_indexer.py", "agent/repair.py",
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
            "stream": False})
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
            current_file = line[4:-4].strip(); current_content = []
        elif line == "=== end ===" and current_file:
            fixes[current_file] = "\n".join(current_content)
            current_file = None; current_content = []
        elif current_file:
            current_content.append(line)
    return fixes

async def self_repair(error_description: str, ws=None):
    async def log(msg):
        print(msg)
        if ws: await ws.send_text(json.dumps({"type": "repair_log", "data": msg}))
    await log("SELF-REPAIR INITIATED")
    await log(f"Error: {error_description[:200]}")
    files = await read_files()
    logs  = await read_logs()
    prompt = f"""Worker Bee self-repair.
ERROR: {error_description}
LOGS: {logs}
FILES: {files}
Output ONLY files that need fixing:
=== agent/tools/browser.py ===
<complete fixed file>
=== end ===
No explanation. Production Python only."""
    await log("Asking qwen to diagnose...")
    response = await ask_qwen(prompt)
    fixes = await extract_files_from_response(response)
    if not fixes:
        await log("No fixes found"); return False
    await log(f"Fixing: {list(fixes.keys())}")
    for filename, content in fixes.items():
        if any(filename == f for f in WATCHED_FILES):
            await apply_fix(filename, content)
            await log(f"Fixed: {filename}")
    (ROOT / "main.py").touch()
    await log("SELF-REPAIR COMPLETE")
    return True

if __name__ == "__main__":
    error = " ".join(sys.argv[1:]) or "General error"
    asyncio.run(self_repair(error))
REPAIRPY

log "Writing agent/tools/memory.py..."
cat > ~/worker-bee/agent/tools/memory.py << 'MEMORYPY'
import chromadb, pathlib
from datetime import datetime

DB_PATH = str(pathlib.Path.home() / "worker-bee" / ".chromadb")

class MemoryTool:
    def __init__(self, tab_id: str = "default"):
        self.tab_id  = tab_id
        self.client  = chromadb.PersistentClient(path=DB_PATH)
        self.conversations = self.client.get_or_create_collection(
            "conversations", metadata={"hnsw:space": "cosine"})
        self.actions   = self.client.get_or_create_collection(
            "actions", metadata={"hnsw:space": "cosine"})
        self.knowledge = self.client.get_or_create_collection(
            "knowledge", metadata={"hnsw:space": "cosine"})

    def _ts(self) -> str: return datetime.now().isoformat()
    def _id(self, prefix: str) -> str:
        import uuid; return f"{prefix}_{uuid.uuid4().hex[:8]}"

    def store_message(self, role: str, content: str, model: str = "") -> str:
        doc_id = self._id("msg")
        self.conversations.add(ids=[doc_id], documents=[content],
            metadatas=[{"role": role, "model": model, "tab_id": self.tab_id,
                        "ts": self._ts(), "type": "message"}])
        return doc_id

    def store_action(self, action: str, target: str, result: str, success: bool) -> str:
        doc_id = self._id("act")
        self.actions.add(ids=[doc_id], documents=[f"{action} → {target}: {result[:500]}"],
            metadatas=[{"action": action, "target": target, "success": str(success),
                        "tab_id": self.tab_id, "ts": self._ts(), "type": "action"}])
        return doc_id

    def store_knowledge(self, topic: str, content: str, source: str = "") -> str:
        doc_id = self._id("knw")
        self.knowledge.add(ids=[doc_id], documents=[f"{topic}: {content}"],
            metadatas=[{"topic": topic, "source": source, "tab_id": self.tab_id,
                        "ts": self._ts(), "type": "knowledge"}])
        return doc_id

    def search(self, query: str, n: int = 5) -> list:
        results = []
        for collection in [self.conversations, self.actions, self.knowledge]:
            try:
                r = collection.query(query_texts=[query], n_results=min(n, collection.count()))
                if r and r["documents"] and r["documents"][0]:
                    for doc, meta, dist in zip(r["documents"][0], r["metadatas"][0], r["distances"][0]):
                        results.append({"content": doc, "metadata": meta, "relevance": round(1 - dist, 3)})
            except Exception: pass
        results.sort(key=lambda x: x["relevance"], reverse=True)
        return results[:n]

    def search_knowledge(self, query: str, n: int = 3) -> list:
        try:
            r = self.knowledge.query(query_texts=[query], n_results=min(n, self.knowledge.count()))
            if r and r["documents"] and r["documents"][0]:
                return [{"content": doc, "metadata": meta}
                        for doc, meta in zip(r["documents"][0], r["metadatas"][0])]
        except Exception: pass
        return []

    def build_context(self, query: str) -> str:
        results = self.search(query, n=5)
        if not results: return ""
        lines = ["[RELEVANT MEMORIES]"]
        for r in results:
            meta = r["metadata"]; ts = meta.get("ts", "")[:10]; typ = meta.get("type", "")
            if typ == "message":
                lines.append(f"• [{ts}] {meta.get('role')}: {r['content'][:200]}")
            elif typ == "action":
                lines.append(f"• [{ts}] {meta.get('action')} ({'✓' if meta.get('success')=='True' else '✗'}): {r['content'][:200]}")
            elif typ == "knowledge":
                lines.append(f"• [{ts}] KNOWN: {r['content'][:200]}")
        lines.append("[END MEMORIES]\n")
        return "\n".join(lines)

    def stats(self) -> dict:
        return {"conversations": self.conversations.count(), "actions": self.actions.count(),
                "knowledge": self.knowledge.count(), "db_path": DB_PATH}

    def clear_tab(self):
        for collection in [self.conversations, self.actions, self.knowledge]:
            try:
                results = collection.get(where={"tab_id": self.tab_id})
                if results["ids"]: collection.delete(ids=results["ids"])
            except Exception: pass
MEMORYPY

log "Writing agent/tools/planner.py..."
cat > ~/worker-bee/agent/tools/planner.py << 'PLANNERPY'
import httpx, json, os, asyncio
from dotenv import dotenv_values

_env = dotenv_values(str(__import__('pathlib').Path.home() / "worker-bee" / ".env"))
OLLAMA       = _env.get("OLLAMA_HOST", "http://localhost:11434")
REASON_MODEL = _env.get("REASON_MODEL", "deepseek-r1:32b")

class TaskPlanner:
    def __init__(self, runner=None):
        self.runner = runner; self.tasks = []; self.current = 0
        self.running = False; self.paused = False

    async def plan(self, goal: str) -> list:
        prompt = f"""Task planner for Worker Bee AI agent.
Tools: browser, login, shell, file_read, file_write, vision, github, gmail, chat
GOAL: {goal}
Output ONLY valid JSON:
{{"goal": "{goal}", "steps": [{{"id": 1, "action": "browser", "description": "Navigate", "params": {{"url": "https://example.com"}}, "depends_on": []}}]}}"""
        try:
            async with httpx.AsyncClient(timeout=120) as c:
                r = await c.post(f"{OLLAMA}/api/chat", json={
                    "model": REASON_MODEL,
                    "messages": [{"role": "user", "content": prompt}],
                    "stream": False})
                content = r.json().get("message", {}).get("content", "")
                if "<think>" in content: content = content.split("</think>")[-1].strip()
                start = content.find("{"); end = content.rfind("}") + 1
                if start >= 0 and end > start:
                    data = json.loads(content[start:end])
                    self.tasks = data.get("steps", [])
                    return self.tasks
        except Exception as e: print(f"Plan error: {e}")
        return []

    async def execute(self, ws=None) -> dict:
        self.running = True; self.current = 0; results = {}

        async def log(msg, level="info"):
            print(f"[PLANNER] {msg}")
            if ws: await ws.send_text(json.dumps({"type": "plan_log", "data": {"message": msg, "level": level}}))

        async def progress(step, status, result=None):
            if ws: await ws.send_text(json.dumps({"type": "plan_progress", "data": {
                "step_id": step["id"], "status": status, "action": step["action"],
                "desc": step["description"], "result": result,
                "current": self.current, "total": len(self.tasks)}}))

        await log(f"Starting: {len(self.tasks)} steps")
        for step in self.tasks:
            if not self.running: break
            while self.paused: await asyncio.sleep(0.5)
            self.current = step["id"]; await progress(step, "running")
            await log(f"Step {step['id']}/{len(self.tasks)}: {step['description']}")
            result = None
            try:
                action = step["action"]; params = step.get("params", {})
                if action == "browser" and self.runner:
                    result = await self.runner.browser.navigate(params.get("url", ""))
                elif action == "shell" and self.runner:
                    result = await self.runner.shell.run(params.get("command", ""))
                elif action == "vision" and self.runner:
                    desc = await self.runner.vision_analyze(
                        params.get("screenshot_b64", ""), params.get("question", "Describe"))
                    result = {"description": desc}
                elif action == "login" and self.runner:
                    result = await self.runner.browser.login(
                        url=params.get("url",""), username=params.get("username",""),
                        password=params.get("password",""))
                results[step["id"]] = result or {}
                await progress(step, "done", result)
                await log(f"Step {step['id']} complete", "ok")
            except Exception as e:
                await log(f"Step {step['id']} failed: {e}", "error")
                await progress(step, "failed", {"error": str(e)})
                results[step["id"]] = {"error": str(e)}

        self.running = False
        final = {"completed": len([r for r in results.values() if "error" not in r]),
                 "failed": len([r for r in results.values() if "error" in r]),
                 "total": len(self.tasks), "results": results}
        await log(f"Complete: {final['completed']}/{final['total']}")
        if ws: await ws.send_text(json.dumps({"type": "plan_complete", "data": final}))
        return final

    def stop(self):   self.running = False
    def pause(self):  self.paused = True
    def resume(self): self.paused = False
PLANNERPY

log "Writing agent/tools/github.py..."
cat > ~/worker-bee/agent/tools/github.py << 'GITHUBPY'
import httpx, os, base64, pathlib
from dotenv import dotenv_values

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
GITHUB_TOKEN = _env.get("GITHUB_TOKEN", "")

class GitHubTool:
    def __init__(self):
        self.headers = {"Accept": "application/vnd.github.v3+json", "User-Agent": "WorkerBee-Agent"}
        if GITHUB_TOKEN: self.headers["Authorization"] = f"token {GITHUB_TOKEN}"

    async def get_file(self, owner: str, repo: str, path: str) -> dict:
        url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(url, headers=self.headers)
            if r.status_code != 200: return {"error": f"HTTP {r.status_code}", "success": False}
            data = r.json()
            return {"path": path, "content": base64.b64decode(data["content"]).decode("utf-8"),
                    "size": data["size"], "sha": data["sha"], "success": True}

    async def list_files(self, owner: str, repo: str, path: str = "") -> dict:
        url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(url, headers=self.headers)
            if r.status_code != 200: return {"error": f"HTTP {r.status_code}", "success": False}
            return {"path": path, "items": [{"name": i["name"], "type": i["type"],
                    "path": i["path"]} for i in r.json()], "success": True}

    async def get_repo_structure(self, owner: str, repo: str) -> dict:
        url = f"https://api.github.com/repos/{owner}/{repo}/git/trees/HEAD?recursive=1"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(url, headers=self.headers)
            if r.status_code != 200: return {"error": f"HTTP {r.status_code}", "success": False}
            return {"files": [t["path"] for t in r.json().get("tree", []) if t["type"] == "blob"],
                    "success": True}

    async def get_multiple_files(self, owner: str, repo: str, paths: list) -> dict:
        results = {}
        for path in paths:
            result = await self.get_file(owner, repo, path)
            results[path] = result["content"] if result.get("success") else f"ERROR: {result.get('error')}"
        return {"files": results, "success": True}

    async def push_file(self, owner: str, repo: str, path: str, content: str,
                        message: str = "Worker Bee update", sha: str = None) -> dict:
        if not GITHUB_TOKEN: return {"error": "No GITHUB_TOKEN", "success": False}
        url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
        body = {"message": message, "content": base64.b64encode(content.encode()).decode()}
        if sha: body["sha"] = sha
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.put(url, headers=self.headers, json=body)
            return {"success": r.status_code in [200, 201], "status": r.status_code, "path": path}
GITHUBPY

log "Writing agent/tools/vision_reporter.py..."
cat > ~/worker-bee/agent/tools/vision_reporter.py << 'VISIONPY'
import httpx, base64, pathlib
from datetime import datetime
from dotenv import dotenv_values

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
GITHUB_TOKEN      = _env.get("GITHUB_TOKEN", "")
VISION_REPO_OWNER = _env.get("VISION_REPO_OWNER", "adobetoby-maker")
VISION_REPO_NAME  = _env.get("VISION_REPO_NAME", "worker-bee-vision")

class VisionReporter:
    def __init__(self):
        self.headers = {"Accept": "application/vnd.github.v3+json",
                        "User-Agent": "WorkerBee-Agent",
                        "Authorization": f"token {GITHUB_TOKEN}"}

    async def push_screenshot(self, screenshot_b64: str, label: str = "", description: str = "") -> dict:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_label = label.replace(" ", "_").replace("/", "_")[:30]
        filename = f"screenshots/{ts}_{safe_label}.png"
        url = f"https://api.github.com/repos/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/contents/{filename}"
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.put(url, headers=self.headers, json={
                "message": f"Worker Bee screenshot: {label}", "content": screenshot_b64})
        if r.status_code not in [200, 201]:
            return {"success": False, "error": f"HTTP {r.status_code}: {r.text[:200]}"}
        await self.update_readme(filename, label, description, ts)
        raw_url = f"https://raw.githubusercontent.com/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/main/{filename}"
        return {"success": True, "filename": filename, "url": raw_url,
                "github_url": f"https://github.com/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/blob/main/{filename}"}

    async def update_readme(self, filename: str, label: str, description: str, ts: str):
        readme_url = f"https://api.github.com/repos/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/contents/README.md"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(readme_url, headers=self.headers)
            sha = r.json().get("sha", "") if r.status_code == 200 else ""
        raw_url = f"https://raw.githubusercontent.com/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/main/{filename}"
        content = f"# Worker Bee Vision Log\n\nLatest: {ts} — {label}\n\n![Latest]({raw_url})\n\n## Analysis\n{description}\n"
        body = {"message": f"Update vision log: {label}",
                "content": base64.b64encode(content.encode()).decode()}
        if sha: body["sha"] = sha
        async with httpx.AsyncClient(timeout=15) as c:
            await c.put(readme_url, headers=self.headers, json=body)

    async def get_latest_url(self) -> str:
        url = f"https://api.github.com/repos/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/contents/screenshots"
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(url, headers=self.headers)
            if r.status_code != 200: return ""
            files = r.json()
            if not files: return ""
            latest = sorted(files, key=lambda x: x["name"], reverse=True)[0]
            return f"https://raw.githubusercontent.com/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/main/{latest['path']}"
VISIONPY

log "Writing agent/tools/cookies.py..."
cat > ~/worker-bee/agent/tools/cookies.py << 'COOKIEPY'
import json, pathlib

COOKIE_DIR = pathlib.Path.home() / "worker-bee" / ".cookies"
COOKIE_DIR.mkdir(exist_ok=True)

def save_cookies(domain: str, cookies: list) -> str:
    path = COOKIE_DIR / f"{domain.replace('.', '_')}.json"
    path.write_text(json.dumps(cookies, indent=2))
    return str(path)

def load_cookies(domain: str) -> list:
    path = COOKIE_DIR / f"{domain.replace('.', '_')}.json"
    if not path.exists(): return []
    return json.loads(path.read_text())

def list_saved() -> list:
    return [f.stem.replace('_', '.') for f in COOKIE_DIR.glob("*.json")]
COOKIEPY

log "Writing agent/tools/ears.py..."
cat > ~/worker-bee/agent/tools/ears.py << 'EARSPY'
import asyncio, pathlib, whisper

_model = None

def get_model():
    global _model
    if _model is None:
        _model = whisper.load_model("base")
    return _model

async def listen(seconds: int = 5, gain: int = 15) -> dict:
    wav_path = pathlib.Path("/tmp/workerbee_listen.wav")
    try:
        import sounddevice as sd
        import scipy.io.wavfile as wav_io
        import numpy as np
        sample_rate = 16000
        recording = sd.rec(int(seconds * sample_rate), samplerate=sample_rate, channels=1, dtype=np.int16)
        sd.wait()
        recording = np.clip(recording * gain, -32768, 32767).astype(np.int16)
        wav_io.write(str(wav_path), sample_rate, recording)
        if not wav_path.exists():
            return {"success": False, "error": "Recording failed"}
        model = get_model()
        result = model.transcribe(str(wav_path), language="en", fp16=False)
        return {"success": True, "text": result["text"].strip(), "language": result.get("language", "en")}
    except Exception as e:
        return {"success": False, "error": str(e)}

if __name__ == "__main__":
    async def test():
        print("Listening 5 seconds...")
        result = await listen(5)
        print(f"Heard: {result}")
    asyncio.run(test())
EARSPY

log "Writing agent/tools/mouth.py..."
cat > ~/worker-bee/agent/tools/mouth.py << 'MOUTHPY'
import asyncio, pathlib, base64

async def speak(text: str, voice: str = "af_sky", play: bool = True) -> dict:
    try:
        from kokoro import KPipeline
        import soundfile as sf
        import numpy as np
        pipeline = KPipeline(lang_code="a")
        audio_chunks = []
        for _, _, audio in pipeline(text, voice=voice):
            audio_chunks.append(audio)
        if not audio_chunks:
            raise Exception("No audio generated")
        combined = np.concatenate(audio_chunks)
        wav_path = pathlib.Path("/tmp/workerbee_speech.wav")
        sf.write(str(wav_path), combined, 24000)
        if play:
            proc = await asyncio.create_subprocess_shell(
                f"afplay {wav_path}",
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            await proc.wait()
        audio_b64 = base64.b64encode(wav_path.read_bytes()).decode()
        return {"success": True, "text": text, "audio_b64": audio_b64, "method": "kokoro"}
    except Exception:
        try:
            safe = text.replace('"', "'")[:300]
            proc = await asyncio.create_subprocess_shell(
                f'say "{safe}"',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            await proc.wait()
            return {"success": True, "text": text, "method": "macos_say"}
        except Exception as e2:
            return {"success": False, "error": str(e2)}

if __name__ == "__main__":
    async def test():
        result = await speak("Hello Toby. Worker Bee is online and ready.")
        print(f"Result: {result}")
    asyncio.run(test())
MOUTHPY

log "Writing agent/tools/learner.py..."
cat > ~/worker-bee/agent/tools/learner.py << 'LEARNERPY'
import httpx, asyncio, re
from datetime import datetime
from dotenv import dotenv_values
import pathlib

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
OLLAMA = _env.get("OLLAMA_HOST", "http://localhost:11434")

SOURCES = [
    {"url": "https://tympanus.net/codrops/", "topic": "MXUX creative 3D web design"},
    {"url": "https://gsap.com/blog/", "topic": "GSAP animation techniques"},
    {"url": "https://www.smashingmagazine.com/", "topic": "web design best practices"},
    {"url": "https://getjobber.com/academy/", "topic": "field service business"},
    {"url": "https://wptavern.com/", "topic": "WordPress best practices"},
    {"url": "https://simonwillison.net/", "topic": "AI agents and LLMs"},
    {"url": "https://www.mux.com/blog", "topic": "video streaming tech"},
    {"url": "https://www.joshwcomeau.com/", "topic": "React and CSS techniques"},
    {"url": "https://supabase.com/blog", "topic": "Supabase and backend patterns"},
]

async def fetch_page(url: str) -> str:
    try:
        async with httpx.AsyncClient(timeout=30, follow_redirects=True,
            headers={"User-Agent": "Mozilla/5.0 WorkerBee-Learner"}) as c:
            r = await c.get(url)
            if r.status_code != 200: return ""
            text = re.sub(r'<script[^>]*>.*?</script>', '', r.text, flags=re.DOTALL)
            text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL)
            text = re.sub(r'<[^>]+>', ' ', text)
            return re.sub(r'\s+', ' ', text).strip()[:8000]
    except Exception as e:
        print(f"Fetch error {url}: {e}"); return ""

async def extract_insights(text: str, topic: str, url: str) -> str:
    prompt = f"""Extract 3-5 actionable insights about {topic} from this content.
URL: {url}
CONTENT: {text[:4000]}
Format as bullet points. Specific and practical only."""
    try:
        async with httpx.AsyncClient(timeout=60) as c:
            r = await c.post(f"{OLLAMA}/api/chat", json={
                "model": "qwen2.5-coder:32b",
                "messages": [{"role": "user", "content": prompt}],
                "stream": False})
            return r.json().get("message", {}).get("content", "")
    except Exception as e:
        return f"Extract error: {e}"

async def learn_session(memory=None, log_fn=None):
    async def log(msg):
        print(f"[LEARNER] {msg}")
        if log_fn: await log_fn(msg)
    await log(f"Learning session started — {len(SOURCES)} sources")
    learned = 0
    for source in SOURCES:
        try:
            await log(f"Reading: {source['url']}")
            text = await fetch_page(source["url"])
            if not text: continue
            insights = await extract_insights(text, source["topic"], source["url"])
            if memory and insights and len(insights) > 50:
                memory.store_knowledge(
                    topic=f"Auto-learned: {source['topic']}",
                    content=insights,
                    source=f"{source['url']} — {datetime.now().strftime('%Y-%m-%d')}")
                await log(f"Stored insights from {source['url']}")
            learned += 1
            await asyncio.sleep(5)
        except Exception as e:
            await log(f"Error with {source['url']}: {e}")
    await log(f"Complete — {learned}/{len(SOURCES)} sources processed")
    return learned

if __name__ == "__main__":
    asyncio.run(learn_session())
LEARNERPY

log "Writing agent/tools/scaffold.py..."
cat > ~/worker-bee/agent/tools/scaffold.py << 'SCAFFOLDPY'
import asyncio, pathlib, os, json, re

PROJECTS = pathlib.Path.home() / "worker-bee" / "projects"

async def create_project(name: str, template: str = "react-ts") -> dict:
    name = re.sub(r'[^a-z0-9-]', '-', name.lower()).strip('-')
    project_path = PROJECTS / name
    if project_path.exists():
        return {"success": False, "error": f"Project {name} already exists", "path": str(project_path)}
    PROJECTS.mkdir(parents=True, exist_ok=True)

    proc = await asyncio.create_subprocess_shell(
        f"cd {PROJECTS} && npm create vite@latest {name} -- --template {template} --yes",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await asyncio.wait_for(proc.communicate(), timeout=60)
    if proc.returncode != 0:
        return {"success": False, "error": err.decode()}

    proc2 = await asyncio.create_subprocess_shell(
        f"cd {project_path} && npm install",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    await asyncio.wait_for(proc2.communicate(), timeout=120)

    proc3 = await asyncio.create_subprocess_shell(
        f"cd {project_path} && npm install -D tailwindcss postcss autoprefixer && npx tailwindcss init -p",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    await asyncio.wait_for(proc3.communicate(), timeout=60)

    (project_path / "src" / "index.css").write_text(
        "@tailwind base;\n@tailwind components;\n@tailwind utilities;\n")
    (project_path / "tailwind.config.js").write_text(
        'export default { content: ["./index.html","./src/**/*.{js,ts,jsx,tsx}"], theme: { extend: {} }, plugins: [] }\n')

    used_ports = set()
    for p in PROJECTS.iterdir():
        m = p / "wb-project.json"
        if m.exists():
            try: used_ports.add(json.loads(m.read_text()).get("port", 0))
            except: pass
    next_port = 5173
    while next_port in used_ports: next_port += 1

    manifest = {"name": name, "template": template,
                "created": __import__('datetime').datetime.now().isoformat(),
                "path": str(project_path), "port": next_port}
    (project_path / "wb-project.json").write_text(json.dumps(manifest, indent=2))
    return {"success": True, "name": name, "path": str(project_path),
            "port": next_port, "message": f"Project {name} created on port {next_port}"}

def list_projects() -> list:
    projects = []
    if not PROJECTS.exists(): return projects
    for p in PROJECTS.iterdir():
        manifest = p / "wb-project.json"
        if manifest.exists():
            try: projects.append(json.loads(manifest.read_text()))
            except: pass
        elif (p / "package.json").exists():
            projects.append({"name": p.name, "path": str(p), "port": 5173})
    return projects

def get_project_files(project_name: str) -> dict:
    project_path = PROJECTS / project_name
    if not project_path.exists(): return {}
    files = {}
    src_path = project_path / "src"
    if src_path.exists():
        for f in src_path.rglob("*"):
            if f.is_file() and f.suffix in ['.tsx','.ts','.jsx','.js','.css','.html','.json']:
                rel_path = f.relative_to(project_path)
                try: files[str(rel_path)] = f.read_text()
                except: pass
    return files

def apply_changes(project_name: str, changes: dict) -> list:
    project_path = PROJECTS / project_name
    applied = []
    for filepath, content in changes.items():
        full_path = project_path / filepath
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(content)
        applied.append(filepath)
    return applied
SCAFFOLDPY

log "Writing agent/tools/devserver.py..."
cat > ~/worker-bee/agent/tools/devserver.py << 'DEVSERVERPY'
import asyncio, pathlib, json

PROJECTS = pathlib.Path.home() / "worker-bee" / "projects"
_servers = {}

async def start(project_name: str, port: int = 5173) -> dict:
    project_path = PROJECTS / project_name
    if not project_path.exists():
        return {"success": False, "error": f"Project {project_name} not found"}
    manifest = project_path / "wb-project.json"
    if manifest.exists():
        try: port = json.loads(manifest.read_text()).get("port", port)
        except: pass
    if project_name in _servers:
        return {"success": True, "message": "Already running", "url": f"http://localhost:{port}"}
    proc = await asyncio.create_subprocess_shell(
        f"cd {project_path} && npm run dev -- --port {port} --host",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    _servers[project_name] = {"proc": proc, "port": port, "path": str(project_path)}
    await asyncio.sleep(3)
    return {"success": True, "project": project_name, "url": f"http://localhost:{port}",
            "message": f"Dev server running at http://localhost:{port}"}

async def stop(project_name: str) -> dict:
    if project_name not in _servers:
        return {"success": False, "error": "Server not running"}
    server = _servers.pop(project_name)
    server["proc"].terminate()
    await server["proc"].wait()
    return {"success": True, "message": f"Stopped {project_name}"}

async def stop_all():
    for name in list(_servers.keys()): await stop(name)

def get_running() -> list:
    return [{"name": k, "url": f"http://localhost:{v['port']}"} for k, v in _servers.items()]

def get_url(project_name: str) -> str:
    if project_name in _servers:
        return f"http://localhost:{_servers[project_name]['port']}"
    return ""
DEVSERVERPY

log "Writing agent/tools/builder.py..."
cat > ~/worker-bee/agent/tools/builder.py << 'BUILDERPY'
import httpx, json, os, asyncio, pathlib, re
from dotenv import dotenv_values

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
OLLAMA = _env.get("OLLAMA_HOST", "http://localhost:11434")

BASE_FILES_PROMPT = """
CRITICAL: Always output ALL of these base files plus your custom components:

=== src/main.tsx ===
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>)
=== end ===

=== src/index.css ===
@tailwind base;
@tailwind components;
@tailwind utilities;
=== end ===

Then output src/App.tsx that imports all your components,
then output each component file separately.
"""

BUILDER_PROMPT = """You are Worker Bee Builder — expert React/TypeScript/Tailwind developer.

OUTPUT FORMAT — use this EXACT format for every file:
=== src/components/Hero.tsx ===
<complete file content — never partial>
=== end ===

RULES:
1. ALWAYS output COMPLETE files — never snippets
2. ALWAYS include src/main.tsx, src/index.css, src/App.tsx
3. TypeScript always
4. Tailwind CSS for ALL styling
5. Mobile first
6. After files list: CHANGED: filename

DESIGN: Clean modern dark themes, glass morphism, smooth animations, professional."""

def extract_files(response: str) -> dict:
    files = {}
    lines = response.split('\n')
    current_file = None
    current_content = []
    for line in lines:
        if line.startswith('=== ') and line.endswith(' ===') and 'end' not in line.lower():
            current_file = line[4:-4].strip(); current_content = []
        elif line.strip() == '=== end ===' and current_file:
            files[current_file] = '\n'.join(current_content)
            current_file = None; current_content = []
        elif current_file is not None:
            current_content.append(line)
    return files

def extract_changed(response: str) -> list:
    return [line.replace('CHANGED:', '').strip() for line in response.split('\n') if line.startswith('CHANGED:')]

async def build(prompt: str, project_name: str, current_files: dict = None,
                ws=None, use_architect: bool = True, use_claude: bool = False) -> dict:
    async def log(msg):
        print(f"[BUILDER] {msg}")
        if ws: await ws.send_text(json.dumps({"type": "build_log", "data": {"message": msg}}))

    await log(f"Building: {prompt[:80]}...")
    context = ""
    if current_files:
        context = "\n\nCURRENT FILES:\n"
        for filepath, content in list(current_files.items())[:8]:
            context += f"\n--- {filepath} ---\n{content[:1500]}\n"

    if use_architect:
        await log("🏗 Architect designing...")
        if ws: await ws.send_text(json.dumps({"type": "build_phase",
            "data": {"phase": "architect", "message": "Designing..."}}))
        from .architect import architect
        brief = await architect(prompt, context, use_claude=use_claude, fast=not use_claude)
        await log(f"📋 Brief ready ({len(brief)} chars)")
        if ws: await ws.send_text(json.dumps({"type": "build_brief",
            "data": {"brief": brief[:500] + "..."}}))
        full_prompt = f"{BASE_FILES_PROMPT}\n\nExecute this brief:\n{brief}\n\nOriginal: {prompt}{context}"
        await log("⚡ qwen coding...")
        if ws: await ws.send_text(json.dumps({"type": "build_phase",
            "data": {"phase": "builder", "message": "qwen coding..."}}))
    else:
        full_prompt = f"{BASE_FILES_PROMPT}\n\n{prompt}{context}"

    try:
        async with httpx.AsyncClient(timeout=300) as c:
            r = await c.post(f"{OLLAMA}/api/chat", json={
                "model": "qwen2.5-coder:32b",
                "messages": [
                    {"role": "system", "content": BUILDER_PROMPT},
                    {"role": "user", "content": full_prompt}
                ],
                "stream": False,
                "options": {"num_predict": 8192}
            })
            response = r.json().get("message", {}).get("content", "")
    except Exception as e:
        return {"success": False, "error": str(e)}

    await log(f"Got response ({len(response)} chars)")
    files = extract_files(response)
    changed = extract_changed(response)
    if not files:
        return {"success": False, "error": "No files generated", "response": response}
    await log(f"Generated {len(files)} files: {list(files.keys())}")
    return {"success": True, "files": files, "changed": changed, "response": response, "file_count": len(files)}

async def build_loop(prompt: str, project_name: str, runner=None, ws=None, max_iterations: int = 3) -> dict:
    from .scaffold import get_project_files, apply_changes
    from .devserver import get_url
    results = []
    for iteration in range(1, max_iterations + 1):
        current_files = get_project_files(project_name)
        result = await build(prompt, project_name, current_files, ws, use_architect=True)
        if not result.get("success"): break
        applied = apply_changes(project_name, result["files"])
        if ws: await ws.send_text(json.dumps({"type": "build_applied",
            "data": {"files": applied, "iteration": iteration}}))
        url = get_url(project_name)
        if url and runner:
            await asyncio.sleep(2)
            screenshot = await runner.browser.navigate(url)
            if screenshot.get("success"):
                if ws: await ws.send_text(json.dumps({"type": "screenshot",
                    "data": {"url": url, "screenshot_b64": screenshot["screenshot_b64"]}}))
                vision = await runner.vision_analyze(screenshot["screenshot_b64"],
                    f"Does this match: '{prompt[:100]}'? Reply YES or describe issues.")
                results.append({"iteration": iteration, "files": applied, "vision": vision})
                if "YES" in vision.upper(): break
                if iteration < max_iterations:
                    prompt = f"Fix: {vision}\n\nOriginal: {prompt}"
        else:
            results.append({"iteration": iteration, "files": applied})
            break
    if ws: await ws.send_text(json.dumps({"type": "build_complete",
        "data": {"project": project_name, "results": results}}))
    return {"success": True, "project": project_name, "iterations": len(results), "results": results}
BUILDERPY

log "Writing agent/tools/architect.py..."
cat > ~/worker-bee/agent/tools/architect.py << 'ARCHPY'
import httpx, pathlib
from dotenv import dotenv_values

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
OLLAMA        = _env.get("OLLAMA_HOST", "http://localhost:11434")
ANTHROPIC_KEY = _env.get("ANTHROPIC_API_KEY", "")

ARCHITECT_PROMPT = """You are the Worker Bee Architect — world-class UI/UX designer and frontend engineer.

Your job is to write a precise technical brief for qwen2.5-coder to execute.
qwen is excellent at following specs but has NO design sense on its own.

Output a TECHNICAL BRIEF with:
## COMPONENT STRUCTURE — every component needed
## DESIGN SYSTEM — exact colors, typography, spacing, shadows
## MXUX ELEMENTS — gradient mesh, glass cards, animations, 3D effects
## RESPONSIVE BEHAVIOR — exact breakpoints
## COMPONENT SPECS — exact implementation for each component
## TAILWIND CLASSES — key classes to use
## FILE STRUCTURE — exact files to create

Be extremely specific. Leave nothing to interpretation."""

async def architect_local(request: str, context: str = "", fast: bool = False) -> str:
    model = "phi4:latest" if fast else "deepseek-r1:70b"
    system = "Write a precise technical UI brief for qwen to execute. Be specific about colors, spacing, and animations." if fast else ARCHITECT_PROMPT
    prompt = f"{request}"
    if context: prompt += f"\n\nCONTEXT:\n{context}"
    async with httpx.AsyncClient(timeout=300) as c:
        r = await c.post(f"{OLLAMA}/api/chat", json={
            "model": model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
            "stream": False})
        content = r.json().get("message", {}).get("content", "")
        if "<think>" in content: content = content.split("</think>")[-1].strip()
        return content

async def architect_claude(request: str, context: str = "") -> str:
    if not ANTHROPIC_KEY: return await architect_local(request, context)
    prompt = f"{request}"
    if context: prompt += f"\n\nCONTEXT:\n{context}"
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post("https://api.anthropic.com/v1/messages",
            headers={"x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01",
                     "content-type": "application/json"},
            json={"model": "claude-sonnet-4-5", "max_tokens": 4000,
                  "system": ARCHITECT_PROMPT,
                  "messages": [{"role": "user", "content": prompt}]})
        data = r.json()
        if "content" in data:
            return data["content"][0].get("text", "")
        return ""

async def architect(request: str, context: str = "", use_claude: bool = False, fast: bool = False) -> str:
    if use_claude and ANTHROPIC_KEY:
        return await architect_claude(request, context)
    return await architect_local(request, context, fast)
ARCHPY

log "Writing agent/tools/site_indexer.py..."
cat > ~/worker-bee/agent/tools/site_indexer.py << 'SITEINDEXPY'
import httpx, asyncio, pathlib, base64, re
from datetime import datetime
from dotenv import dotenv_values

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
GITHUB_TOKEN      = _env.get("GITHUB_TOKEN", "")
VISION_REPO_OWNER = _env.get("VISION_REPO_OWNER", "adobetoby-maker")
VISION_REPO_NAME  = _env.get("VISION_REPO_NAME", "worker-bee-vision")

HEADERS = {"Accept": "application/vnd.github.v3+json", "User-Agent": "WorkerBee-Agent",
           "Authorization": f"token {GITHUB_TOKEN}"}

async def discover_pages(url: str, browser) -> list:
    base_domain = url.split("/")[2]
    visited = set(); to_visit = [url]; pages = []
    while to_visit and len(pages) < 20:
        current = to_visit.pop(0)
        if current in visited: continue
        visited.add(current)
        try:
            result = await browser.navigate(current)
            if not result.get("success"): continue
            pages.append({"url": current, "title": result.get("title", ""),
                          "text": result.get("text", "")[:500],
                          "screenshot_b64": result.get("screenshot_b64", "")})
            text = result.get("text", "")
            links = re.findall(r'https?://' + re.escape(base_domain) + r'[^\s"\'<>]*', text)
            for link in links:
                clean = link.split("#")[0].rstrip("/")
                if clean not in visited: to_visit.append(clean)
        except Exception as e:
            print(f"Error visiting {current}: {e}")
    return pages

async def push_visual_index(site_url: str, pages: list, analyses: list, log_fn=None) -> dict:
    async def log(msg):
        print(f"[INDEXER] {msg}")
        if log_fn: await log_fn(msg)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    domain = site_url.split("/")[2].replace(".", "_")
    folder = f"indexes/{domain}_{ts}"
    pushed = []
    for i, page in enumerate(pages):
        if not page.get("screenshot_b64"): continue
        page_name = (page["url"].replace(site_url, "").replace("/", "_").strip("_") or "home")
        filename = f"{folder}/{i+1:02d}_{page_name}.png"
        await log(f"Pushing {filename}...")
        url = f"https://api.github.com/repos/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/contents/{filename}"
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.put(url, headers=HEADERS, json={
                "message": f"Visual index: {page['url']}", "content": page["screenshot_b64"]})
        if r.status_code in [200, 201]:
            raw_url = f"https://raw.githubusercontent.com/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/main/{filename}"
            pushed.append({"url": page["url"], "title": page.get("title", ""),
                           "raw_url": raw_url,
                           "analysis": analyses[i] if i < len(analyses) else ""})
    if not pushed: return {"success": False, "error": "No pages pushed"}
    readme_lines = [f"# Visual Index: {site_url}", f"Generated: {ts}",
                    f"Pages: {len(pushed)}", "", "---", ""]
    for page in pushed:
        readme_lines += [f"## {page['title'] or page['url']}", f"**URL:** {page['url']}", "",
                         f"![{page['title']}]({page['raw_url']})", "",
                         f"**Analysis:** {page.get('analysis','')[:300]}", "", "---", ""]
    content = "\n".join(readme_lines)
    readme_url = f"https://api.github.com/repos/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/contents/{folder}/README.md"
    async with httpx.AsyncClient(timeout=15) as c:
        await c.put(readme_url, headers=HEADERS, json={
            "message": f"Visual index: {site_url}",
            "content": base64.b64encode(content.encode()).decode()})
    return {"success": True, "pages": len(pushed), "folder": folder,
            "index_url": f"https://github.com/{VISION_REPO_OWNER}/{VISION_REPO_NAME}/tree/main/{folder}",
            "pages_data": pushed}

async def index_site(url: str, browser, vision_analyze_fn=None, log_fn=None) -> dict:
    async def log(msg):
        print(f"[INDEXER] {msg}")
        if log_fn: await log_fn(msg)
    await log(f"Starting visual index of {url}")
    pages = await discover_pages(url, browser)
    await log(f"Found {len(pages)} pages")
    analyses = []
    for i, page in enumerate(pages):
        await log(f"Analyzing {i+1}/{len(pages)}: {page['url']}")
        if vision_analyze_fn and page.get("screenshot_b64"):
            analysis = await vision_analyze_fn(page["screenshot_b64"],
                "Describe: 1) Purpose 2) Key content 3) Main CTA 4) Design quality")
            analyses.append(analysis)
        else:
            analyses.append("")
    result = await push_visual_index(url, pages, analyses, log_fn)
    if result.get("success"):
        await log(f"✅ Complete: {result['pages']} pages — {result['index_url']}")
    return result
SITEINDEXPY

log "Writing agent/tools/browser.py..."
cat > ~/worker-bee/agent/tools/browser.py << 'BROWSERPY'
from playwright.async_api import async_playwright
import base64, asyncio

class BrowserTool:
    def __init__(self):
        self._pw = None; self._browser = None; self._contexts = {}

    async def _ensure(self):
        if not self._browser:
            self._pw = await async_playwright().start()
            self._browser = await self._pw.chromium.launch(
                headless=True,
                args=["--no-sandbox","--disable-dev-shm-usage",
                      "--disable-blink-features=AutomationControlled"])

    async def _get_context(self, domain: str):
        await self._ensure()
        if domain in self._contexts: return self._contexts[domain]
        ctx = await self._browser.new_context(
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            viewport={"width": 1280, "height": 800},
            extra_http_headers={"Accept-Language": "en-US,en;q=0.9"})
        await ctx.add_init_script(
            "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});")
        try:
            from .cookies import load_cookies
            cookies = load_cookies(domain)
            if cookies: await ctx.add_cookies(cookies)
        except: pass
        self._contexts[domain] = ctx
        return ctx

    async def navigate(self, url: str) -> dict:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx = await self._get_context(domain)
        page = await ctx.new_page()
        try:
            await page.goto(url, timeout=60000, wait_until="domcontentloaded")
            await page.wait_for_timeout(3000)
            shot = await page.screenshot(full_page=True)
            text = await page.inner_text("body")
            return {"url": page.url, "title": await page.title(), "text": text[:6000],
                    "screenshot_b64": base64.b64encode(shot).decode(), "success": True}
        except Exception as e:
            return {"url": url, "error": str(e), "success": False}
        finally:
            await page.close()

    async def login(self, url: str, username: str, password: str, max_attempts: int = 5) -> dict:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx = await self._get_context(domain)
        EMAIL_SELS = ['input[type="email"]','input[name="email"]','input[name="username"]',
                      'input[id="email"]','input[id="username"]','input[placeholder*="email" i]',
                      'input[autocomplete="email"]','input[autocomplete="username"]']
        PASS_SELS  = ['input[type="password"]','input[name="password"]',
                      'input[id="password"]','input[autocomplete="current-password"]']
        SUBMIT_SELS= ['button[type="submit"]','button:has-text("Sign in")',
                      'button:has-text("Log in")','button:has-text("Continue")']
        last_error = ""
        for attempt in range(1, max_attempts + 1):
            page = await ctx.new_page()
            try:
                await page.goto(url, timeout=60000, wait_until="domcontentloaded")
                await page.wait_for_timeout(2000)
                filled_email = False
                for sel in EMAIL_SELS:
                    try:
                        el = page.locator(sel).first
                        if await el.is_visible(timeout=1000):
                            await el.click(); await el.fill(username)
                            filled_email = True; break
                    except: pass
                if not filled_email: await page.keyboard.type(username)
                await page.wait_for_timeout(500)
                pass_visible = False
                for sel in PASS_SELS[:2]:
                    try:
                        if await page.locator(sel).first.is_visible(timeout=500):
                            pass_visible = True; break
                    except: pass
                if not pass_visible:
                    for sel in ['button:has-text("Next")','button:has-text("Continue")','button[type="submit"]']:
                        try:
                            btn = page.locator(sel).first
                            if await btn.is_visible(timeout=1000):
                                await btn.click(); await page.wait_for_timeout(2000); break
                        except: pass
                filled_pass = False
                for sel in PASS_SELS:
                    try:
                        el = page.locator(sel).first
                        if await el.is_visible(timeout=2000):
                            await el.click(); await el.fill(password)
                            filled_pass = True; break
                    except: pass
                if not filled_pass:
                    last_error = "Password field not found"
                    await page.close(); await asyncio.sleep(2); continue
                submitted = False
                for sel in SUBMIT_SELS:
                    try:
                        btn = page.locator(sel).first
                        if await btn.is_visible(timeout=1000):
                            await btn.click(); submitted = True; break
                    except: pass
                if not submitted: await page.keyboard.press("Enter")
                await page.wait_for_load_state("networkidle", timeout=10000)
                await page.wait_for_timeout(2000)
                shot = await page.screenshot()
                text = await page.inner_text("body")
                return {"url": page.url, "title": await page.title(), "text": text[:4000],
                        "screenshot_b64": base64.b64encode(shot).decode(),
                        "success": True, "attempts": attempt}
            except Exception as e:
                last_error = str(e); await page.close(); await asyncio.sleep(2 + attempt)
        return {"url": url, "success": False, "attempts": max_attempts,
                "error": f"Login failed after {max_attempts} attempts: {last_error}"}

    async def screenshot(self, url: str) -> str:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx = await self._get_context(domain)
        page = await ctx.new_page()
        await page.goto(url, timeout=60000, wait_until="domcontentloaded")
        await page.wait_for_timeout(3000)
        shot = await page.screenshot(full_page=True)
        await page.close()
        return base64.b64encode(shot).decode()

    async def scrape(self, url: str) -> str:
        await self._ensure()
        domain = url.split("/")[2] if "//" in url else url
        ctx = await self._get_context(domain)
        page = await ctx.new_page()
        await page.goto(url, timeout=60000, wait_until="domcontentloaded")
        await page.wait_for_timeout(3000)
        text = await page.inner_text("body")
        await page.close()
        return text

    async def close(self):
        for ctx in self._contexts.values(): await ctx.close()
        if self._browser: await self._browser.close()
        if self._pw: await self._pw.stop()
BROWSERPY

log "Writing agent/tools/filesystem.py..."
cat > ~/worker-bee/agent/tools/filesystem.py << 'FSPY'
import pathlib

SAFE = pathlib.Path.home() / "worker-bee" / "projects"

class FilesystemTool:
    def __init__(self): SAFE.mkdir(parents=True, exist_ok=True)

    def _safe(self, path: str) -> pathlib.Path:
        p = (SAFE / path).resolve()
        if not str(p).startswith(str(SAFE)):
            raise PermissionError(f"Path outside safe root: {path}")
        return p

    def read(self, path: str) -> str:
        return self._safe(path).read_text(encoding="utf-8")

    def write(self, path: str, content: str) -> str:
        p = self._safe(path); p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        return f"Written {len(content)} chars to {path}"

    def list_dir(self, path: str = "") -> list:
        return [str(f.relative_to(SAFE)) for f in self._safe(path).iterdir()]

    def delete(self, path: str) -> str:
        self._safe(path).unlink(); return f"Deleted {path}"

    def exists(self, path: str) -> bool:
        return self._safe(path).exists()
FSPY

log "Writing agent/tools/shell.py..."
cat > ~/worker-bee/agent/tools/shell.py << 'SHELLPY'
import asyncio, pathlib, os

BLOCKED = ["rm -rf /","sudo rm -rf","mkfs","dd if=",
           ":(){:|:&};:","chmod 777 /","curl | bash","wget | bash"]
VENV = str(pathlib.Path.home() / "worker-bee" / ".venv" / "bin")

class ShellTool:
    async def run(self, command: str, timeout: int = 120) -> dict:
        for b in BLOCKED:
            if b in command: return {"error": f"Blocked: {b}", "success": False}
        env = os.environ.copy()
        env["PATH"] = f"{VENV}:{env.get('PATH', '')}"
        try:
            proc = await asyncio.create_subprocess_shell(
                command, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=str(pathlib.Path.home() / "worker-bee"), env=env)
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return {"stdout": out.decode(), "returncode": proc.returncode,
                    "success": proc.returncode == 0}
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

SCOPES = ["https://www.googleapis.com/auth/gmail.modify",
          "https://www.googleapis.com/auth/gmail.readonly"]
TOKEN_PATH = pathlib.Path.home() / ".workerbee_gmail_token.json"
CREDS_PATH = pathlib.Path.home() / ".workerbee_gmail_creds.json"

class GmailTool:
    def __init__(self): self._service = None

    def _auth(self):
        creds = None
        if TOKEN_PATH.exists():
            creds = Credentials.from_authorized_user_file(str(TOKEN_PATH), SCOPES)
        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                if not CREDS_PATH.exists():
                    raise FileNotFoundError(f"Gmail credentials not found at {CREDS_PATH}")
                creds = InstalledAppFlow.from_client_secrets_file(
                    str(CREDS_PATH), SCOPES).run_local_server(port=0)
            TOKEN_PATH.write_text(creds.to_json())
        self._service = build("gmail", "v1", credentials=creds)
        return self._service

    def service(self):
        if not self._service: self._auth()
        return self._service

    def get_inbox_summary(self) -> dict:
        svc = self.service()
        categories = {"unread":"is:unread","promotions":"category:promotions",
                      "social":"category:social","old_unread":"is:unread older_than:30d"}
        summary = {}
        for name, query in categories.items():
            result = svc.users().messages().list(userId="me", q=query, maxResults=1).execute()
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
            msg = svc.users().messages().get(userId="me", id=m["id"], format="metadata",
                metadataHeaders=["From","Subject","Date"]).execute()
            headers = {h["name"]: h["value"] for h in msg["payload"]["headers"]}
            emails.append({"id": m["id"], "from": headers.get("From",""),
                           "subject": headers.get("Subject",""), "date": headers.get("Date",""),
                           "snippet": msg.get("snippet","")[:100]})
        return emails

    def archive_emails(self, query: str, max_results: int = 500) -> dict:
        svc = self.service()
        messages = svc.users().messages().list(
            userId="me", q=query, maxResults=max_results).execute().get("messages",[])
        if not messages: return {"archived": 0, "message": "No emails found"}
        ids = [m["id"] for m in messages]
        svc.users().messages().batchModify(
            userId="me", body={"ids": ids, "removeLabelIds": ["INBOX"]}).execute()
        return {"archived": len(ids), "message": f"Archived {len(ids)} emails"}

    def delete_emails(self, query: str, max_results: int = 500) -> dict:
        svc = self.service()
        messages = svc.users().messages().list(
            userId="me", q=query, maxResults=max_results).execute().get("messages",[])
        if not messages: return {"deleted": 0, "message": "No emails found"}
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
            msg = svc.users().messages().get(userId="me", id=m["id"], format="metadata",
                metadataHeaders=["From"]).execute()
            sender = next((h["value"] for h in msg["payload"]["headers"]
                          if h["name"] == "From"), "Unknown")
            senders[sender] = senders.get(sender, 0) + 1
        return [{"sender": s, "count": c} for s, c in
                sorted(senders.items(), key=lambda x: x[1], reverse=True)[:20]]
GMAILPY

log "Writing voice_chat.py..."
cat > ~/worker-bee/voice_chat.py << 'VOICECHATPY'
#!/usr/bin/env python3
"""Worker Bee Voice Chat — Terminal Edition"""
import asyncio, httpx, pathlib
from datetime import datetime
from dotenv import dotenv_values
from agent.tools.ears import listen
from agent.tools.mouth import speak
from agent.tools.memory import MemoryTool

_env = dotenv_values(str(pathlib.Path.home() / "worker-bee" / ".env"))
OLLAMA = _env.get("OLLAMA_HOST", "http://localhost:11434")
memory = MemoryTool(tab_id="voice-chat")
history = []

SYSTEM = """You are Worker Bee, Toby's personal AI assistant.
Speak conversationally — no markdown, no bullet points, just natural speech.
2-4 sentences max. You remember past conversations.
Toby is an orthopedic surgeon building Worker Bee and LinguaLens."""

async def think(text: str) -> str:
    mem_context = memory.build_context(text)
    system = (mem_context + "\n\n" + SYSTEM) if mem_context else SYSTEM
    messages = [{"role": "system", "content": system}] + history[-10:] + [{"role": "user", "content": text}]
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post(f"{OLLAMA}/api/chat",
            json={"model": "llama3.3:70b", "messages": messages, "stream": False})
        return r.json().get("message", {}).get("content", "")

async def remember(user_text: str, bee_response: str):
    memory.store_message("user", user_text, "voice")
    memory.store_message("assistant", bee_response, "llama3.3:70b")
    if any(w in user_text.lower() for w in ["idea","think","want to","what if","plan","build","remember"]):
        memory.store_knowledge(
            topic=f"Voice idea — {datetime.now().strftime('%Y-%m-%d')}",
            content=f"Toby said: {user_text}", source="voice-chat")
        print("  💾 Idea stored")

async def voice_loop():
    print("\n🐝 Worker Bee Voice Chat")
    print("=" * 40)
    print("Enter = speak 5 seconds")
    print("'ideas' = list stored ideas")
    print("'memory' = show stats")
    print("Ctrl+C = exit")
    print("=" * 40)
    stats = memory.stats()
    greeting = f"Worker Bee online. {stats['conversations'] + stats['knowledge']} memories stored. What's on your mind?"
    print(f"\nBee: {greeting}")
    await speak(greeting)
    while True:
        try:
            cmd = input("\n[Enter to speak / type command] ").strip().lower()
            if cmd == "memory":
                s = memory.stats()
                print(f"\n📊 {s['conversations']} conversations, {s['knowledge']} knowledge")
                continue
            elif cmd == "ideas":
                results = memory.search_knowledge("idea plan build", n=5)
                if results:
                    print("\n💡 Recent ideas:")
                    for r in results: print(f"  • {r['content'][:100]}")
                else:
                    print("No ideas stored yet")
                continue
            elif cmd and cmd != "":
                text = cmd
            else:
                print("🎙 Listening...")
                heard = await listen(seconds=5, gain=15)
                if not heard.get("success") or not heard.get("text"):
                    print("Didn't catch that"); continue
                text = heard["text"]
            print(f"\nYou: {text}")
            print("🤔 Thinking...")
            response = await think(text)
            if not response: continue
            history.append({"role": "user", "content": text})
            history.append({"role": "assistant", "content": response})
            await remember(text, response)
            print(f"\nBee: {response}")
            await speak(response)
        except KeyboardInterrupt:
            print("\n\n🐝 Goodbye!")
            await speak("Goodbye Toby!")
            break
        except Exception as e:
            print(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(voice_loop())
VOICECHATPY

log "Writing helper scripts..."
cat > ~/worker-bee/learn.sh << 'LEARNSH'
#!/bin/zsh
cd ~/worker-bee
source .venv/bin/activate
export OLLAMA_HOST=http://localhost:11434
python3 -c "
import asyncio
from agent.tools.memory import MemoryTool
from agent.tools.learner import learn_session
memory = MemoryTool(tab_id='auto-learner')
asyncio.run(learn_session(memory=memory))
"
echo "Learning complete: $(date)"
LEARNSH
chmod +x ~/worker-bee/learn.sh

cat > ~/worker-bee/warm_models.sh << WARMSH
#!/bin/zsh
echo "🐝 Warming models..."
curl -s http://localhost:11434/api/generate -d '{"model":"${PRIMARY}","prompt":"hi","keep_alive":"24h"}' > /dev/null &
curl -s http://localhost:11434/api/generate -d '{"model":"${CODING}","prompt":"hi","keep_alive":"24h"}' > /dev/null &
curl -s http://localhost:11434/api/generate -d '{"model":"llava:latest","prompt":"hi","keep_alive":"24h"}' > /dev/null &
wait
echo "✅ Models warmed"
WARMSH
chmod +x ~/worker-bee/warm_models.sh

log "Writing .env..."
cat > ~/worker-bee/.env << ENVEOF
OLLAMA_HOST=http://localhost:11434
DEFAULT_MODEL=${PRIMARY}
CODING_MODEL=${CODING}
REASON_MODEL=${REASON}
AGENT_PORT=8000
SAFE_ROOT=${HOME}/worker-bee/projects
GITHUB_TOKEN=
GITHUB_REPO_OWNER=
GITHUB_REPO_NAME=
VISION_REPO_OWNER=
VISION_REPO_NAME=worker-bee-vision
ANTHROPIC_API_KEY=
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
ok "Playwright ready"

hdr "9 / 10  PULLING AI MODELS"
log "Pulling $CODING..."
ollama pull "$CODING"
ok "$CODING ready"

log "Pulling $PRIMARY..."
ollama pull "$PRIMARY"
ok "$PRIMARY ready"

log "Pulling llava..."
ollama pull llava
ok "llava ready"

log "Pulling $REASON (large — may take 20-40 min first time)..."
ollama pull "$REASON"
ok "$REASON ready"

log "Pulling phi4 (fast architect)..."
ollama pull phi4
ok "phi4 ready"

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
  <key>WorkingDirectory</key><string>/Users/${USER}/worker-bee</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/workerbee.log</string>
  <key>StandardErrorPath</key><string>/tmp/workerbee-error.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key><string>http://localhost:11434</string>
    <key>DEFAULT_MODEL</key><string>${PRIMARY}</string>
    <key>CODING_MODEL</key><string>${CODING}</string>
    <key>REASON_MODEL</key><string>${REASON}</string>
    <key>PATH</key><string>/Users/${USER}/worker-bee/.venv/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
launchctl load ~/Library/LaunchAgents/com.workerbee.agent.plist 2>/dev/null || true

grep -q "alias wb=" ~/.zshrc 2>/dev/null || \
echo 'alias wb="cd ~/worker-bee && source .venv/bin/activate && export OLLAMA_HOST=http://localhost:11434 && uvicorn main:app --reload --host 0.0.0.0 --port 8000 --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem"' >> ~/.zshrc

(crontab -l 2>/dev/null; echo "0 2 * * * /bin/zsh -l ~/worker-bee/learn.sh >> /tmp/workerbee-learn.log 2>&1") | crontab - 2>/dev/null || true

source ~/.zshrc 2>/dev/null || true
ok "Auto-start, wb alias, nightly learner configured"

clear
echo -e "${GRN}${BLD}"
echo "  🐝  WORKER BEE v3.2 IS READY"
echo -e "${NC}"
echo -e "  ${GRN}[OK]${NC} Agent        https://localhost:8000"
echo -e "  ${GRN}[OK]${NC} Models       $PRIMARY | $CODING | $REASON | llava | phi4"
echo -e "  ${GRN}[OK]${NC} Memory       ChromaDB persistent"
echo -e "  ${GRN}[OK]${NC} Voice        Whisper + macOS say"
echo -e "  ${GRN}[OK]${NC} Builder      Claude/deepseek architect + qwen"
echo -e "  ${GRN}[OK]${NC} Vision       llava + GitHub push"
echo -e "  ${GRN}[OK]${NC} Planner      autonomous multi-step tasks"
echo -e "  ${GRN}[OK]${NC} GitHub       code reader/writer"
echo -e "  ${GRN}[OK]${NC} Site Index   crawl and screenshot entire sites"
echo -e "  ${GRN}[OK]${NC} Learner      nightly 2am web learning"
echo -e "  ${GRN}[OK]${NC} Auto-start   starts on every login"
echo ""
echo -e "  ${AMB}NEXT STEPS:${NC}"
echo -e "  1. Visit https://localhost:8000/health in Safari"
echo -e "     Click through the security warning (one time)"
echo -e "  2. Open https://worker-bee.lovable.app"
echo -e "  3. Add your keys to ~/worker-bee/.env:"
echo -e "     nano ~/worker-bee/.env"
echo -e "     GITHUB_TOKEN=your_token"
echo -e "     ANTHROPIC_API_KEY=your_key"
echo -e "     VISION_REPO_OWNER=your_github_username"
echo ""
echo -e "  ${AMB}DAILY:${NC}   type 'wb' in any terminal"
echo -e "  ${AMB}VOICE:${NC}   python3 ~/worker-bee/voice_chat.py"
echo -e "  ${AMB}WARM:${NC}    zsh ~/worker-bee/warm_models.sh"
echo -e "  ${AMB}LOGS:${NC}    tail -f /tmp/workerbee.log"
echo ""
echo -e "${GRN}Starting Worker Bee...${NC}"
echo ""
cd ~/worker-bee && source .venv/bin/activate
export OLLAMA_HOST=http://localhost:11434
uvicorn main:app --reload --host 0.0.0.0 --port 8000 \
    --ssl-keyfile ~/.ssl/key.pem --ssl-certfile ~/.ssl/cert.pem
