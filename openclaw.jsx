import { useState, useEffect, useRef, useCallback } from "react";

// ── Palette & constants ──────────────────────────────────────────────────────
const TOOLS = [
  { id: "web_search",   icon: "🌐", name: "Web Search",       desc: "DuckDuckGo / Brave search API integration",  cmd: "pip install duckduckgo-search" },
  { id: "code_exec",    icon: "⚡", name: "Code Executor",    desc: "Sandboxed Python & JS execution environment", cmd: "pip install jupyter_client" },
  { id: "file_ops",     icon: "📁", name: "File System",      desc: "Read / write / watch local directories",      cmd: "pip install watchdog" },
  { id: "vision",       icon: "👁",  name: "Vision",           desc: "Image analysis via LLaVA / Moondream",        cmd: "ollama pull llava" },
  { id: "vector_db",   icon: "🧠", name: "Vector Memory",    desc: "ChromaDB persistent embedding store",         cmd: "pip install chromadb" },
  { id: "shell",        icon: "🐚", name: "Shell Runner",     desc: "Execute safe bash commands with approval",    cmd: "built-in" },
  { id: "git",          icon: "🌿", name: "Git Tools",        desc: "Clone, diff, commit via GitPython",           cmd: "pip install gitpython" },
  { id: "scraper",      icon: "🕷",  name: "Web Scraper",      desc: "Playwright headless browser scraping",        cmd: "pip install playwright && playwright install" },
  { id: "pdf_reader",   icon: "📄", name: "PDF Reader",       desc: "Extract and chunk PDFs with pypdf",           cmd: "pip install pypdf" },
  { id: "sql_tools",    icon: "🗄",  name: "SQL Agent",        desc: "Query SQLite / Postgres databases",           cmd: "pip install sqlalchemy" },
];

const DEFAULT_ENDPOINT = "http://localhost:11434";

// ── Helpers ──────────────────────────────────────────────────────────────────
function ts() {
  return new Date().toLocaleTimeString("en-US", { hour12: false });
}

// ── Sub-components ───────────────────────────────────────────────────────────

function Claw({ grabbing }) {
  return (
    <svg width="54" height="64" viewBox="0 0 54 64" fill="none"
      style={{ filter: grabbing ? "drop-shadow(0 0 8px #39ff14)" : "drop-shadow(0 0 4px #ff6b00)", transition: "all .4s" }}>
      {/* cable */}
      <rect x="25" y="0" width="4" height="18" rx="2" fill={grabbing ? "#39ff14" : "#ff6b00"} />
      {/* head */}
      <rect x="16" y="18" width="22" height="8" rx="3" fill={grabbing ? "#39ff14" : "#ff6b00"} />
      {/* left claw */}
      <path d={grabbing ? "M20 26 Q8 38 14 52" : "M20 26 Q4 44 6 58"} stroke={grabbing ? "#39ff14" : "#ff6b00"} strokeWidth="3.5" strokeLinecap="round" fill="none" />
      {/* mid claw */}
      <path d={grabbing ? "M27 26 Q27 40 27 52" : "M27 26 Q27 46 27 60"} stroke={grabbing ? "#39ff14" : "#ff6b00"} strokeWidth="3.5" strokeLinecap="round" fill="none" />
      {/* right claw */}
      <path d={grabbing ? "M34 26 Q46 38 40 52" : "M34 26 Q50 44 48 58"} stroke={grabbing ? "#39ff14" : "#ff6b00"} strokeWidth="3.5" strokeLinecap="round" fill="none" />
    </svg>
  );
}

function StatusDot({ ok }) {
  return (
    <span style={{
      display: "inline-block", width: 9, height: 9, borderRadius: "50%",
      background: ok ? "#39ff14" : "#ff3b3b",
      boxShadow: ok ? "0 0 6px #39ff14" : "0 0 6px #ff3b3b",
      marginRight: 6, flexShrink: 0,
    }} />
  );
}

function TerminalLine({ line }) {
  const color = line.startsWith("[ERR]") ? "#ff3b3b"
    : line.startsWith("[OK]") ? "#39ff14"
    : line.startsWith("[→]") ? "#ff6b00"
    : "#c8c8c8";
  return <div style={{ color, fontFamily: "'JetBrains Mono', monospace", fontSize: 12, lineHeight: 1.6 }}>{line}</div>;
}

function ChatBubble({ msg }) {
  const isUser = msg.role === "user";
  return (
    <div style={{
      display: "flex", justifyContent: isUser ? "flex-end" : "flex-start",
      marginBottom: 14, alignItems: "flex-end", gap: 8,
    }}>
      {!isUser && (
        <div style={{ width: 28, height: 28, borderRadius: "50%", background: "#1a1a1a", border: "1.5px solid #ff6b00", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 13, flexShrink: 0 }}>🦾</div>
      )}
      <div style={{
        maxWidth: "72%", padding: "10px 14px", borderRadius: isUser ? "14px 14px 4px 14px" : "14px 14px 14px 4px",
        background: isUser ? "linear-gradient(135deg,#ff6b00,#ff9500)" : "#161616",
        border: isUser ? "none" : "1px solid #2a2a2a",
        color: isUser ? "#fff" : "#e0e0e0",
        fontFamily: "'IBM Plex Sans', sans-serif", fontSize: 14, lineHeight: 1.65,
        whiteSpace: "pre-wrap", wordBreak: "break-word",
        boxShadow: isUser ? "0 4px 20px rgba(255,107,0,.35)" : "0 2px 12px rgba(0,0,0,.5)",
      }}>
        {msg.content}
        {msg.streaming && <span style={{ opacity: .5, animation: "blink 1s infinite" }}>▋</span>}
      </div>
      {isUser && (
        <div style={{ width: 28, height: 28, borderRadius: "50%", background: "#ff6b00", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 13, flexShrink: 0 }}>👤</div>
      )}
    </div>
  );
}

function ToolCard({ tool, installed, installing, onInstall, onToggle, enabled }) {
  return (
    <div style={{
      background: "#0e0e0e", border: `1px solid ${enabled ? "#ff6b00" : "#222"}`,
      borderRadius: 10, padding: "12px 14px", marginBottom: 8,
      transition: "all .25s", boxShadow: enabled ? "0 0 12px rgba(255,107,0,.15)" : "none",
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span style={{ fontSize: 20 }}>{tool.icon}</span>
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <span style={{ color: "#f0f0f0", fontFamily: "'JetBrains Mono',monospace", fontWeight: 700, fontSize: 13 }}>{tool.name}</span>
            {installed && <span style={{ background: "#39ff1420", color: "#39ff14", fontSize: 10, padding: "1px 6px", borderRadius: 4, border: "1px solid #39ff1440" }}>INSTALLED</span>}
          </div>
          <div style={{ color: "#666", fontSize: 11, marginTop: 2, fontFamily: "'IBM Plex Sans',sans-serif" }}>{tool.desc}</div>
        </div>
        <div style={{ display: "flex", gap: 6 }}>
          {!installed ? (
            <button onClick={() => onInstall(tool)} disabled={installing}
              style={{ background: installing ? "#222" : "#ff6b00", color: "#fff", border: "none", borderRadius: 6, padding: "5px 12px", fontFamily: "'JetBrains Mono',monospace", fontSize: 11, cursor: installing ? "wait" : "pointer", transition: "all .2s" }}>
              {installing ? "…" : "INSTALL"}
            </button>
          ) : (
            <button onClick={() => onToggle(tool.id)}
              style={{ background: enabled ? "#39ff1420" : "#1a1a1a", color: enabled ? "#39ff14" : "#666", border: `1px solid ${enabled ? "#39ff14" : "#333"}`, borderRadius: 6, padding: "5px 12px", fontFamily: "'JetBrains Mono',monospace", fontSize: 11, cursor: "pointer", transition: "all .2s" }}>
              {enabled ? "ON" : "OFF"}
            </button>
          )}
        </div>
      </div>
      {tool.cmd !== "built-in" && (
        <div style={{ marginTop: 8, background: "#080808", borderRadius: 6, padding: "5px 10px", fontFamily: "'JetBrains Mono',monospace", fontSize: 10, color: "#555", border: "1px solid #1a1a1a" }}>
          $ {tool.cmd}
        </div>
      )}
    </div>
  );
}

// ── Main App ─────────────────────────────────────────────────────────────────
export default function OpenClaw() {
  // Connection
  const [endpoint, setEndpoint] = useState(DEFAULT_ENDPOINT);
  const [connected, setConnected] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [models, setModels] = useState([]);
  const [selectedModel, setSelectedModel] = useState("");
  const [connMode, setConnMode] = useState("localhost"); // localhost | tailscale

  // Chat
  const [messages, setMessages] = useState([
    { role: "assistant", content: "⚡ OpenClaw online. Connect to your Ollama endpoint and select a model to begin. I can install tools to extend my capabilities on demand." }
  ]);
  const [input, setInput] = useState("");
  const [streaming, setStreaming] = useState(false);
  const [grabbing, setGrabbing] = useState(false);

  // Tools
  const [installed, setInstalled] = useState({ shell: true });
  const [enabled, setEnabled] = useState({ shell: true });
  const [installingId, setInstallingId] = useState(null);
  const [termLines, setTermLines] = useState([
    "[OK] OpenClaw agent runtime v0.1.0 started",
    "[OK] Shell tool loaded (built-in)",
    "[→] Connect to Ollama to continue...",
  ]);

  // UI
  const [activePanel, setActivePanel] = useState("chat"); // chat | tools | config
  const chatEndRef = useRef(null);
  const inputRef = useRef(null);

  // ── Auto-scroll ────────────────────────────────────────────────────────────
  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // ── Endpoint auto-fill ─────────────────────────────────────────────────────
  useEffect(() => {
    if (connMode === "localhost") setEndpoint("http://localhost:11434");
    else setEndpoint("http://100.x.x.x:11434"); // user replaces with tailscale IP
  }, [connMode]);

  // ── Connect to Ollama ──────────────────────────────────────────────────────
  const connect = useCallback(async () => {
    setConnecting(true);
    addTerm(`[→] Connecting to ${endpoint} …`);
    try {
      const res = await fetch(`${endpoint}/api/tags`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const list = (data.models || []).map(m => m.name);
      setModels(list);
      setSelectedModel(list[0] || "");
      setConnected(true);
      addTerm(`[OK] Ollama connected — ${list.length} model(s) available`);
      list.forEach(m => addTerm(`[OK] Model: ${m}`));
    } catch (e) {
      addTerm(`[ERR] Connection failed: ${e.message}`);
      addTerm(`[→] Check Ollama is running: ollama serve`);
      setConnected(false);
    }
    setConnecting(false);
  }, [endpoint]);

  // ── Terminal helper ────────────────────────────────────────────────────────
  function addTerm(line) {
    setTermLines(prev => [...prev.slice(-200), `[${ts()}] ${line}`]);
  }

  // ── Send message ───────────────────────────────────────────────────────────
  const sendMessage = useCallback(async () => {
    if (!input.trim() || !connected || streaming) return;
    const userMsg = { role: "user", content: input.trim() };
    const newMsgs = [...messages, userMsg];
    setMessages(newMsgs);
    setInput("");
    setStreaming(true);
    setGrabbing(true);

    const enabledToolNames = TOOLS.filter(t => enabled[t.id]).map(t => t.name);
    const systemPrompt = `You are OpenClaw, a powerful AI assistant running via Ollama on a local or Tailscale-connected machine. You are direct, technical, and capable. Available tools: ${enabledToolNames.join(", ") || "none"}. When asked to install a tool, explain the process clearly. Keep responses focused and useful.`;

    const payload = {
      model: selectedModel,
      messages: [{ role: "system", content: systemPrompt }, ...newMsgs.map(m => ({ role: m.role, content: m.content }))],
      stream: true,
    };

    const assistantMsg = { role: "assistant", content: "", streaming: true };
    setMessages(prev => [...prev, assistantMsg]);

    try {
      const res = await fetch(`${endpoint}/api/chat`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let full = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = dec.decode(value);
        for (const line of chunk.split("\n")) {
          if (!line.trim()) continue;
          try {
            const j = JSON.parse(line);
            if (j.message?.content) {
              full += j.message.content;
              setMessages(prev => {
                const copy = [...prev];
                copy[copy.length - 1] = { role: "assistant", content: full, streaming: true };
                return copy;
              });
            }
          } catch {}
        }
      }
      setMessages(prev => {
        const copy = [...prev];
        copy[copy.length - 1] = { role: "assistant", content: full, streaming: false };
        return copy;
      });
      addTerm(`[OK] Response complete (${full.length} chars)`);
    } catch (e) {
      setMessages(prev => {
        const copy = [...prev];
        copy[copy.length - 1] = { role: "assistant", content: `⚠ Error: ${e.message}`, streaming: false };
        return copy;
      });
      addTerm(`[ERR] Stream error: ${e.message}`);
    }
    setStreaming(false);
    setGrabbing(false);
    inputRef.current?.focus();
  }, [input, connected, streaming, messages, selectedModel, endpoint, enabled]);

  // ── Install tool (simulated) ───────────────────────────────────────────────
  const installTool = useCallback(async (tool) => {
    setInstallingId(tool.id);
    addTerm(`[→] Installing ${tool.name}…`);
    addTerm(`[→] $ ${tool.cmd}`);
    await new Promise(r => setTimeout(r, 600));
    addTerm(`[→] Resolving dependencies…`);
    await new Promise(r => setTimeout(r, 800));
    addTerm(`[OK] ${tool.name} installed successfully`);
    setInstalled(prev => ({ ...prev, [tool.id]: true }));
    setEnabled(prev => ({ ...prev, [tool.id]: true }));
    setInstallingId(null);
  }, []);

  const toggleTool = (id) => setEnabled(prev => ({ ...prev, [id]: !prev[id] }));

  // ── Keyboard ───────────────────────────────────────────────────────────────
  const onKey = (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendMessage(); }
  };

  // ── Styles ─────────────────────────────────────────────────────────────────
  const panelBtn = (id) => ({
    background: activePanel === id ? "#ff6b00" : "transparent",
    color: activePanel === id ? "#fff" : "#666",
    border: "none", borderRadius: 8, padding: "7px 16px",
    fontFamily: "'JetBrains Mono',monospace", fontSize: 12, cursor: "pointer",
    transition: "all .2s", letterSpacing: "0.05em",
  });

  return (
    <div style={{
      minHeight: "100vh", background: "#080808", color: "#e0e0e0",
      fontFamily: "'IBM Plex Sans', sans-serif",
      display: "flex", flexDirection: "column",
    }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@300;400;500;600&family=JetBrains+Mono:wght@400;700&display=swap');
        * { box-sizing: border-box; margin: 0; padding: 0; }
        ::-webkit-scrollbar { width: 4px; }
        ::-webkit-scrollbar-track { background: #0a0a0a; }
        ::-webkit-scrollbar-thumb { background: #2a2a2a; border-radius: 2px; }
        @keyframes blink { 0%,100%{opacity:1} 50%{opacity:0} }
        @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.4} }
        @keyframes slideDown { from{opacity:0;transform:translateY(-10px)} to{opacity:1;transform:translateY(0)} }
        @keyframes swingClaw { 0%,100%{transform:translateY(0)} 50%{transform:translateY(12px)} }
        .claw-animate { animation: swingClaw 1.8s ease-in-out infinite; }
        textarea:focus { outline: none; }
        button:active { transform: scale(.97); }
        .panel-enter { animation: slideDown .25s ease; }
      `}</style>

      {/* ── Header ── */}
      <header style={{
        background: "#0c0c0c", borderBottom: "1px solid #1a1a1a",
        padding: "0 24px", height: 58, display: "flex", alignItems: "center", gap: 16,
        position: "sticky", top: 0, zIndex: 100,
      }}>
        {/* Logo */}
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <div className={grabbing ? "claw-animate" : ""}>
            <Claw grabbing={grabbing} />
          </div>
          <div>
            <div style={{ fontFamily: "'JetBrains Mono',monospace", fontWeight: 700, fontSize: 18, color: "#ff6b00", letterSpacing: "0.04em" }}>
              OPEN<span style={{ color: "#39ff14" }}>CLAW</span>
            </div>
            <div style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 10, color: "#444", letterSpacing: "0.1em" }}>OLLAMA AGENT INTERFACE</div>
          </div>
        </div>

        <div style={{ flex: 1 }} />

        {/* Connection status */}
        <div style={{ display: "flex", alignItems: "center", gap: 8, background: "#111", border: "1px solid #222", borderRadius: 8, padding: "6px 12px" }}>
          <StatusDot ok={connected} />
          <span style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 11, color: connected ? "#39ff14" : "#ff3b3b" }}>
            {connected ? "OLLAMA LIVE" : "DISCONNECTED"}
          </span>
        </div>

        {/* Model badge */}
        {connected && selectedModel && (
          <div style={{ background: "#ff6b0015", border: "1px solid #ff6b0040", borderRadius: 8, padding: "6px 12px" }}>
            <span style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 11, color: "#ff6b00" }}>⚙ {selectedModel}</span>
          </div>
        )}

        {/* Tool count */}
        <div style={{ background: "#39ff1410", border: "1px solid #39ff1430", borderRadius: 8, padding: "6px 12px" }}>
          <span style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 11, color: "#39ff14" }}>
            🔧 {Object.values(enabled).filter(Boolean).length} tools active
          </span>
        </div>
      </header>

      {/* ── Body ── */}
      <div style={{ flex: 1, display: "flex", overflow: "hidden", height: "calc(100vh - 58px)" }}>

        {/* ── Left sidebar: nav + terminal ── */}
        <div style={{ width: 240, background: "#0a0a0a", borderRight: "1px solid #1a1a1a", display: "flex", flexDirection: "column", flexShrink: 0 }}>

          {/* Nav */}
          <div style={{ padding: "14px 12px", borderBottom: "1px solid #151515" }}>
            {[
              { id: "chat",   icon: "💬", label: "CHAT" },
              { id: "tools",  icon: "🔧", label: "TOOLS" },
              { id: "config", icon: "⚙",  label: "CONFIG" },
            ].map(p => (
              <button key={p.id} onClick={() => setActivePanel(p.id)}
                style={{ ...panelBtn(p.id), display: "flex", alignItems: "center", gap: 8, width: "100%", marginBottom: 4, textAlign: "left" }}>
                <span>{p.icon}</span> {p.label}
              </button>
            ))}
          </div>

          {/* Terminal */}
          <div style={{ flex: 1, overflow: "auto", padding: 12 }}>
            <div style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 10, color: "#444", letterSpacing: "0.1em", marginBottom: 8 }}>── AGENT LOG ──</div>
            {termLines.map((l, i) => <TerminalLine key={i} line={l} />)}
          </div>
        </div>

        {/* ── Main panel ── */}
        <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>

          {/* CHAT panel */}
          {activePanel === "chat" && (
            <div className="panel-enter" style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
              {/* Messages */}
              <div style={{ flex: 1, overflowY: "auto", padding: "20px 24px" }}>
                {messages.map((m, i) => <ChatBubble key={i} msg={m} />)}
                <div ref={chatEndRef} />
              </div>

              {/* Input */}
              <div style={{ borderTop: "1px solid #151515", padding: "14px 20px", background: "#0a0a0a" }}>
                {!connected && (
                  <div style={{ textAlign: "center", color: "#555", fontFamily: "'JetBrains Mono',monospace", fontSize: 12, marginBottom: 10 }}>
                    ⚠ Connect to Ollama in CONFIG to start chatting
                  </div>
                )}
                <div style={{ display: "flex", gap: 10, alignItems: "flex-end" }}>
                  <textarea ref={inputRef} value={input} onChange={e => setInput(e.target.value)} onKeyDown={onKey}
                    disabled={!connected || streaming}
                    placeholder={connected ? `Message ${selectedModel || "model"}… (Enter to send)` : "Not connected"}
                    rows={3}
                    style={{
                      flex: 1, background: "#111", border: "1px solid #222", borderRadius: 12, padding: "12px 14px",
                      color: "#e0e0e0", fontFamily: "'IBM Plex Sans',sans-serif", fontSize: 14, resize: "none",
                      transition: "border-color .2s",
                    }}
                    onFocus={e => e.target.style.borderColor = "#ff6b00"}
                    onBlur={e => e.target.style.borderColor = "#222"}
                  />
                  <button onClick={sendMessage} disabled={!connected || streaming || !input.trim()}
                    style={{
                      background: connected && !streaming && input.trim() ? "linear-gradient(135deg,#ff6b00,#ff9500)" : "#1a1a1a",
                      color: "#fff", border: "none", borderRadius: 12, padding: "12px 20px",
                      fontFamily: "'JetBrains Mono',monospace", fontSize: 13, cursor: connected ? "pointer" : "not-allowed",
                      transition: "all .2s", height: 80,
                    }}>
                    {streaming ? <span style={{ animation: "pulse 1s infinite" }}>◼</span> : "SEND ↑"}
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* TOOLS panel */}
          {activePanel === "tools" && (
            <div className="panel-enter" style={{ flex: 1, overflowY: "auto", padding: "20px 24px" }}>
              <div style={{ marginBottom: 20 }}>
                <div style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 18, fontWeight: 700, color: "#ff6b00", marginBottom: 6 }}>🔧 TOOL ARSENAL</div>
                <div style={{ color: "#555", fontSize: 13 }}>Install capabilities to expand what the agent can do. Enabled tools are injected into the system prompt.</div>
              </div>
              <div style={{ display: "grid", gap: 0 }}>
                {TOOLS.map(t => (
                  <ToolCard key={t.id} tool={t}
                    installed={!!installed[t.id]}
                    installing={installingId === t.id}
                    enabled={!!enabled[t.id]}
                    onInstall={installTool}
                    onToggle={toggleTool}
                  />
                ))}
              </div>
            </div>
          )}

          {/* CONFIG panel */}
          {activePanel === "config" && (
            <div className="panel-enter" style={{ flex: 1, overflowY: "auto", padding: "20px 24px" }}>
              <div style={{ maxWidth: 560 }}>
                <div style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 18, fontWeight: 700, color: "#ff6b00", marginBottom: 20 }}>⚙ CONNECTION CONFIG</div>

                {/* Mode selector */}
                <div style={{ marginBottom: 20 }}>
                  <label style={{ display: "block", color: "#888", fontSize: 12, fontFamily: "'JetBrains Mono',monospace", letterSpacing: "0.1em", marginBottom: 8 }}>CONNECTION MODE</label>
                  <div style={{ display: "flex", gap: 8 }}>
                    {[
                      { id: "localhost", icon: "🖥", label: "Localhost" },
                      { id: "tailscale", icon: "🔒", label: "Tailscale VPN" },
                      { id: "custom",    icon: "✏",  label: "Custom" },
                    ].map(m => (
                      <button key={m.id} onClick={() => setConnMode(m.id)}
                        style={{
                          flex: 1, padding: "10px 8px", border: `1px solid ${connMode === m.id ? "#ff6b00" : "#222"}`,
                          background: connMode === m.id ? "#ff6b0015" : "#111", borderRadius: 8, cursor: "pointer",
                          fontFamily: "'JetBrains Mono',monospace", fontSize: 11, color: connMode === m.id ? "#ff6b00" : "#555",
                          transition: "all .2s",
                        }}>
                        {m.icon} {m.label}
                      </button>
                    ))}
                  </div>
                </div>

                {/* Endpoint */}
                <div style={{ marginBottom: 16 }}>
                  <label style={{ display: "block", color: "#888", fontSize: 12, fontFamily: "'JetBrains Mono',monospace", letterSpacing: "0.1em", marginBottom: 8 }}>OLLAMA ENDPOINT</label>
                  <input value={endpoint} onChange={e => setEndpoint(e.target.value)}
                    style={{ width: "100%", background: "#111", border: "1px solid #2a2a2a", borderRadius: 8, padding: "11px 14px", color: "#e0e0e0", fontFamily: "'JetBrains Mono',monospace", fontSize: 13 }}
                    onFocus={e => { e.target.style.borderColor = "#ff6b00"; setConnMode("custom"); }}
                    onBlur={e => e.target.style.borderColor = "#2a2a2a"}
                  />
                </div>

                {connMode === "tailscale" && (
                  <div style={{ background: "#0d1a0d", border: "1px solid #39ff1420", borderRadius: 8, padding: 14, marginBottom: 16, fontSize: 12, color: "#39ff1499", fontFamily: "'JetBrains Mono',monospace", lineHeight: 1.7 }}>
                    💡 Replace <strong style={{color:"#39ff14"}}>100.x.x.x</strong> with your Mac's Tailscale IP<br/>
                    Run: <strong style={{color:"#39ff14"}}>tailscale ip -4</strong> on the Mac<br/>
                    Ensure Ollama allows remote: <strong style={{color:"#39ff14"}}>OLLAMA_HOST=0.0.0.0 ollama serve</strong>
                  </div>
                )}

                {connMode === "localhost" && (
                  <div style={{ background: "#0d0d1a", border: "1px solid #4444ff30", borderRadius: 8, padding: 14, marginBottom: 16, fontSize: 12, color: "#8888ff", fontFamily: "'JetBrains Mono',monospace", lineHeight: 1.7 }}>
                    💡 Requires Ollama running on the same machine<br/>
                    Start: <strong>ollama serve</strong><br/>
                    Install model: <strong>ollama pull llama3.2</strong>
                  </div>
                )}

                {/* Connect button */}
                <button onClick={connect} disabled={connecting}
                  style={{
                    width: "100%", background: connecting ? "#1a1a1a" : "linear-gradient(135deg,#ff6b00,#ff9500)",
                    color: "#fff", border: "none", borderRadius: 10, padding: "13px",
                    fontFamily: "'JetBrains Mono',monospace", fontSize: 14, fontWeight: 700, cursor: connecting ? "wait" : "pointer",
                    letterSpacing: "0.06em", transition: "all .2s", marginBottom: 20,
                  }}>
                  {connecting ? "CONNECTING…" : connected ? "✓ RECONNECT" : "CONNECT TO OLLAMA"}
                </button>

                {/* Model selector */}
                {connected && models.length > 0 && (
                  <div style={{ marginBottom: 20 }}>
                    <label style={{ display: "block", color: "#888", fontSize: 12, fontFamily: "'JetBrains Mono',monospace", letterSpacing: "0.1em", marginBottom: 8 }}>ACTIVE MODEL</label>
                    <select value={selectedModel} onChange={e => setSelectedModel(e.target.value)}
                      style={{ width: "100%", background: "#111", border: "1px solid #2a2a2a", borderRadius: 8, padding: "11px 14px", color: "#e0e0e0", fontFamily: "'JetBrains Mono',monospace", fontSize: 13 }}>
                      {models.map(m => <option key={m} value={m}>{m}</option>)}
                    </select>
                  </div>
                )}

                {/* Pull new model */}
                <div style={{ background: "#111", border: "1px solid #1a1a1a", borderRadius: 10, padding: 16 }}>
                  <div style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 12, color: "#666", marginBottom: 10 }}>QUICK PULL POPULAR MODELS</div>
                  {["llama3.2", "mistral", "gemma3", "phi4", "deepseek-r1", "llava"].map(m => (
                    <div key={m} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "6px 0", borderBottom: "1px solid #161616" }}>
                      <span style={{ fontFamily: "'JetBrains Mono',monospace", fontSize: 12, color: "#aaa" }}>{m}</span>
                      <code style={{ fontSize: 10, color: "#555", background: "#0a0a0a", padding: "2px 8px", borderRadius: 4 }}>ollama pull {m}</code>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
