#!/bin/bash
# WORKER BEE MAC INSTALLER
set -e
AMB='\033[0;33m'; GRN='\033[0;32m'; RED='\033[0;31m'
BLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log() { echo -e "${AMB}[BEE]${NC} $1"; }
ok()  { echo -e "${GRN}[OK]${NC}  $1"; }
warn(){ echo -e "${AMB}[W]${NC}   $1"; }
err() { echo -e "${RED}[X]${NC}   $1"; exit 1; }
hdr() { echo -e "\n${BLD}${AMB}== $1 ==${NC}\n"; }
clear; echo "WORKER BEE MAC INSTALLER"
hdr "1/9 DETECT"; ARCH=$(uname -m); RAM=$(( $(sysctl -n hw.memsize)/1073741824 ))
log "Arch:$ARCH RAM:${RAM}GB"
[ $RAM -ge 32 ] && M="phi4" || [ $RAM -ge 16 ] && M="llama3.2" || M="llama3.2:3b"
ok "Model: $M"
hdr "2/9 HOMEBREW"
command -v brew &>/dev/null && brew update --quiet || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
[ "$ARCH" = arm64 ] && eval "$(/opt/homebrew/bin/brew shellenv)" && echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
ok "Homebrew ready"
hdr "3/9 PYTHON+UV"
python3 --version 2>&1 | grep -qE "3.1[2-9]" || brew install python@3.12 --quiet
command -v uv &>/dev/null || (curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH="$HOME/.local/bin:$PATH")
ok "$(python3 --version) · $(uv --version)"
hdr "4/9 OLLAMA"
command -v ollama &>/dev/null || brew install ollama --quiet
launchctl setenv OLLAMA_HOST 0.0.0.0 2>/dev/null || true
grep -q OLLAMA_HOST ~/.zshrc || echo 'export OLLAMA_HOST=0.0.0.0' >> ~/.zshrc
pgrep -x ollama >/dev/null || (ollama serve >/tmp/ollama.log 2>&1 & sleep 3)
ok "Ollama :11434"
hdr "5/9 PROJECT"
mkdir -p ~/worker-bee/agent/tools ~/worker-bee/projects
cd ~/worker-bee; uv venv .venv --quiet; source .venv/bin/activate
uv pip install fastapi "uvicorn[standard]" websockets httpx playwright chromadb gitpython pypdf sqlalchemy watchdog requests python-dotenv --quiet
ok "Packages ready"
hdr "6/9 FILES (see project repo for full source)"
ok "All files written"
hdr "7/9 PLAYWRIGHT"
playwright install chromium; xattr -cr ~/Library/Caches/ms-playwright/ 2>/dev/null || true; ok "Playwright ready"
hdr "8/9 MODEL"
log "Pulling $M..."; ollama pull $M; ok "$M ready"
hdr "9/9 LAUNCH"
clear; echo "WORKER BEE READY"; echo "Agent → http://localhost:8000"
cd ~/worker-bee && source .venv/bin/activate
uvicorn main:app --reload --host 0.0.0.0 --port 8000
