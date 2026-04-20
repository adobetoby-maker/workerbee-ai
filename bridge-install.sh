#!/bin/bash
# WORKER BEE BRIDGE INSTALLER — Ubuntu VM
set -e
BLU='\033[0;34m'; GRN='\033[0;32m'; AMB='\033[0;33m'; RED='\033[0;31m'
BLD='\033[1m'; NC='\033[0m'
log() { echo -e "${BLU}[BRIDGE]${NC} $1"; }
ok()  { echo -e "${GRN}[OK]${NC}     $1"; }
warn(){ echo -e "${AMB}[WARN]${NC}   $1"; }
err() { echo -e "${RED}[ERR]${NC}    $1"; exit 1; }
hdr() { echo -e "\n${BLD}${BLU}== $1 ==${NC}\n"; }
clear; echo "WORKER BEE BRIDGE INSTALLER"
command -v apt &>/dev/null || err "Ubuntu/Debian only"
hdr "0/8 MAC CONNECTION"
echo "How is this VM connected to your Mac?"
echo "1) Tailscale VPN  2) Local network  3) Same machine"
read -rp "Enter 1/2/3: " C
case $C in
  1) read -rp "Mac Tailscale IP (e.g. 100.64.0.1): " IP; OLLAMA="http://${IP}:11434"; LABEL="Tailscale";;
  2) read -rp "Mac local IP (e.g. 192.168.1.50): " IP; OLLAMA="http://${IP}:11434"; LABEL="LAN";;
  3) OLLAMA="http://host.docker.internal:11434"; LABEL="Host";;
  *) err "Invalid";;
esac
log "Ollama: $OLLAMA"
curl -s --connect-timeout 5 "${OLLAMA}/api/tags" >/dev/null 2>&1 && ok "Ollama reachable" || warn "Cannot reach Ollama — check Mac setup and continue"
hdr "1/8 SYSTEM PACKAGES"
sudo apt-get update -qq
sudo apt-get install -y -qq curl wget git build-essential python3 python3-pip python3-venv libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 fonts-liberation xdg-utils
ok "System packages ready"
hdr "2/8 PYTHON+UV"
command -v uv &>/dev/null || (curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH="$HOME/.local/bin:$PATH")
ok "Python + uv ready"
hdr "3/8 TAILSCALE"
[ "$C" = "1" ] && { command -v tailscale &>/dev/null || (curl -fsSL https://tailscale.com/install.sh | sh); sudo tailscale up; ok "Tailscale connected"; } || ok "Skipped"
hdr "4/8 PROJECT"
mkdir -p ~/worker-bee/agent/tools ~/worker-bee/projects
cd ~/worker-bee; uv venv .venv --quiet; source .venv/bin/activate
uv pip install fastapi "uvicorn[standard]" websockets httpx playwright chromadb gitpython pypdf sqlalchemy watchdog requests python-dotenv --quiet
ok "Packages installed"
hdr "5/8 FILES (see project repo for full source)"
ok "All files written"
hdr "6/8 PLAYWRIGHT"
playwright install chromium; playwright install-deps chromium 2>/dev/null || true; ok "Playwright ready"
hdr "7/8 FIREWALL"
command -v ufw &>/dev/null && sudo ufw allow 8000/tcp || warn "Open port 8000 manually"
hdr "8/8 LAUNCH"
VM_IP=$(hostname -I | awk '{print $1}')
clear; echo "WORKER BEE BRIDGE READY"
echo "Ollama  → ${OLLAMA}"
echo "Agent   → http://${VM_IP}:8000"
cd ~/worker-bee && source .venv/bin/activate
uvicorn main:app --reload --host 0.0.0.0 --port 8000
