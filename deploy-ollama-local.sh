#!/usr/bin/env bash
# =============================================================================
# Ollama Local SSL Deployment — macOS / Linux
# Self-contained: generates missing config files on first run.
# =============================================================================

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# -----------------------------------------------------------------------------
# Colours
# -----------------------------------------------------------------------------
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYN}[INFO]${NC} $*"; }
ok()    { echo -e "${GRN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YEL}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*"; }

# =============================================================================
# STEP 0 — Generate missing config / tool files
# =============================================================================
info "Checking dependencies..."

mkdir -p "$BASEDIR/config" "$BASEDIR/tools"

# --- .env (API Key) -----------------------------------------------------------
if [ ! -f "$BASEDIR/.env" ]; then
    info "Generating .env with random API key"
    if command -v openssl > /dev/null 2>&1; then
        GENERATED_KEY=$(openssl rand -hex 32)
    else
        GENERATED_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '=/+\n' | head -c 32)
    fi
    printf 'OLLAMA_API_KEY=%s\nOLLAMA_TIMEOUT=10m\n' "$GENERATED_KEY" > "$BASEDIR/.env"
    ok ".env created. Use this key in ELO DMS: $GENERATED_KEY"
else
    info ".env already exists, skipping key generation."
fi

# --- Caddyfile ----------------------------------------------------------------
if [ ! -f "$BASEDIR/config/Caddyfile" ]; then
    info "Generating config/Caddyfile"
    cat > "$BASEDIR/config/Caddyfile" << 'CADDYFILE_EOF'
{
    admin off
}

# Puerto 11443 externo → 11434 interno Caddy (Ollama Docker)
https://localhost:11434, https://127.0.0.1:11434 {

    root * /usr/share/caddy
    log {
        output stdout
        format console
    }

    @preflight method OPTIONS
    handle @preflight {
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
        respond "" 204
    }

    @unauthorized {
        not header Authorization "Bearer {env.OLLAMA_API_KEY}"
        path /v1/*
    }
    handle @unauthorized {
        header Content-Type "application/json"
        header Access-Control-Allow-Origin "*"
        respond `{"error":{"message":"Incorrect API key provided. Verify the key used matches the configured OLLAMA_API_KEY.","type":"invalid_api_key","param":null,"code":"invalid_api_key"}}` 401
    }

    handle /api/* {
        reverse_proxy ollama:11434 {
            header_down -Access-Control-Allow-Origin
            transport http {
                response_header_timeout {$OLLAMA_TIMEOUT}
                dial_timeout 30s
            }
        }
    }

    handle /v1/* {
        reverse_proxy ollama:11434 {
            header_down -Access-Control-Allow-Origin
            transport http {
                response_header_timeout {$OLLAMA_TIMEOUT}
                dial_timeout 30s
            }
        }
    }

    handle {
        templates
        file_server
    }

    header {
        Access-Control-Allow-Origin "*"
        Access-Control-Allow-Methods "GET, POST, OPTIONS"
        Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
    }

    tls internal
}

# Puerto 11444 externo → 11435 interno Caddy (Ollama nativo via proxy)
https://localhost:11435, https://127.0.0.1:11435 {

    root * /usr/share/caddy
    log {
        output stdout
        format console
    }

    @preflight method OPTIONS
    handle @preflight {
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
        respond "" 204
    }

    @unauthorized {
        not header Authorization "Bearer {env.OLLAMA_API_KEY}"
        path /v1/*
    }
    handle @unauthorized {
        header Content-Type "application/json"
        header Access-Control-Allow-Origin "*"
        respond `{"error":{"message":"Incorrect API key provided. Verify the key used matches the configured OLLAMA_API_KEY.","type":"invalid_api_key","param":null,"code":"invalid_api_key"}}` 401
    }

    handle /api/* {
        reverse_proxy host.docker.internal:11434 {
            header_down -Access-Control-Allow-Origin
            transport http {
                response_header_timeout {$OLLAMA_TIMEOUT}
                dial_timeout 30s
            }
        }
    }

    handle /v1/* {
        reverse_proxy host.docker.internal:11434 {
            header_down -Access-Control-Allow-Origin
            transport http {
                response_header_timeout {$OLLAMA_TIMEOUT}
                dial_timeout 30s
            }
        }
    }

    handle {
        templates
        file_server
    }

    header {
        Access-Control-Allow-Origin "*"
        Access-Control-Allow-Methods "GET, POST, OPTIONS"
        Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
    }

    tls internal
}
CADDYFILE_EOF
fi

# --- docker-compose.hybrid.yml -----------------------------------------------
if [ ! -f "$BASEDIR/config/docker-compose.hybrid.yml" ]; then
    info "Generating config/docker-compose.hybrid.yml"
    cat > "$BASEDIR/config/docker-compose.hybrid.yml" << 'HYBRID_EOF'
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "11443:11434"
      - "11444:11435"
    environment:
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
      - OLLAMA_TIMEOUT=${OLLAMA_TIMEOUT:-10m}
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile
      - .:/usr/share/caddy
      - caddy_data:/data
    depends_on:
      - ollama

  ollama:
    image: ollama/ollama
    container_name: ollama
    restart: always
    volumes:
      - ollama_data:/root/.ollama

volumes:
  ollama_data:
  caddy_data:
HYBRID_EOF
fi

# --- docker-compose.caddy-only.yml -------------------------------------------
if [ ! -f "$BASEDIR/config/docker-compose.caddy-only.yml" ]; then
    info "Generating config/docker-compose.caddy-only.yml"
    cat > "$BASEDIR/config/docker-compose.caddy-only.yml" << 'CADDYONLY_EOF'
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "11443:11434"
      - "11444:11435"
    environment:
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
      - OLLAMA_TIMEOUT=${OLLAMA_TIMEOUT:-10m}
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile
      - .:/usr/share/caddy
      - caddy_data:/data

volumes:
  caddy_data:
CADDYONLY_EOF
fi

# --- docker-compose.nvidia.yml -----------------------------------------------
if [ ! -f "$BASEDIR/config/docker-compose.nvidia.yml" ]; then
    info "Generating config/docker-compose.nvidia.yml"
    cat > "$BASEDIR/config/docker-compose.nvidia.yml" << 'NVIDIA_EOF'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: always
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    volumes:
      - ollama_data:/root/.ollama

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "11443:11434"
      - "11444:11435"
    environment:
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
      - OLLAMA_TIMEOUT=${OLLAMA_TIMEOUT:-10m}
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile
      - .:/usr/share/caddy
      - caddy_data:/data
    depends_on:
      - ollama

volumes:
  ollama_data:
  caddy_data:
NVIDIA_EOF
fi

# --- docker-compose.amd.yml --------------------------------------------------
if [ ! -f "$BASEDIR/config/docker-compose.amd.yml" ]; then
    info "Generating config/docker-compose.amd.yml"
    cat > "$BASEDIR/config/docker-compose.amd.yml" << 'AMD_EOF'
services:
  ollama:
    image: ollama/ollama:rocm
    container_name: ollama
    restart: always
    devices:
      - "/dev/kfd:/dev/kfd"
      - "/dev/dri:/dev/dri"
    volumes:
      - ollama_data:/root/.ollama

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "11443:11434"
      - "11444:11435"
    environment:
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
      - OLLAMA_TIMEOUT=${OLLAMA_TIMEOUT:-10m}
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile
      - .:/usr/share/caddy
      - caddy_data:/data
    depends_on:
      - ollama

volumes:
  ollama_data:
  caddy_data:
AMD_EOF
fi

# --- docker-compose.cpu.yml --------------------------------------------------
if [ ! -f "$BASEDIR/config/docker-compose.cpu.yml" ]; then
    info "Generating config/docker-compose.cpu.yml"
    cat > "$BASEDIR/config/docker-compose.cpu.yml" << 'CPU_EOF'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: always
    volumes:
      - ollama_data:/root/.ollama

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "11443:11434"
      - "11444:11435"
    environment:
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
      - OLLAMA_TIMEOUT=${OLLAMA_TIMEOUT:-10m}
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile
      - .:/usr/share/caddy
      - caddy_data:/data
    depends_on:
      - ollama

volumes:
  ollama_data:
  caddy_data:
CPU_EOF
fi

# --- ai-console.html ---------------------------------------------------------
if [ ! -f "$BASEDIR/ai-console.html" ]; then
    info "Generating ai-console.html"
    cat > "$BASEDIR/ai-console.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Universal AI Console - SSL Aware</title>
    <script>window.__OLLAMA_API_KEY__ = "{{env "OLLAMA_API_KEY"}}";</script>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
    <script src="https://cdn.jsdelivr.net/npm/marked@9/marked.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    <style>
        :root{--bg:#f8f9fa;--card:#fff;--primary:#1a73e8;--gpu:#2ecc71;--cpu:#f39c12;--hybrid:#9b59b6;--text:#202124;--text-sec:#5f6368;}
        body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);margin:0;padding:20px;display:flex;justify-content:center;}
        .container{background:var(--card);padding:2rem;border-radius:16px;box-shadow:0 4px 25px rgba(0,0,0,.1);width:100%;max-width:900px;display:flex;flex-direction:column;gap:1rem;}
        .header{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:1px solid #eee;padding-bottom:1rem;}
        .grid-config{display:grid;grid-template-columns:1fr 1fr;gap:15px;background:#f1f3f4;padding:15px;border-radius:10px;}
        .form-group{display:flex;flex-direction:column;gap:5px;}
        label{font-weight:600;font-size:.85rem;color:var(--text-sec);}
        input,select,textarea{padding:10px;border:1px solid #dadce0;border-radius:6px;font-size:.95rem;}
        .source-bar{display:flex;gap:15px;font-size:.9rem;font-weight:500;}
        .badge{padding:4px 10px;border-radius:4px;color:#fff;font-size:.75rem;font-weight:bold;white-space:nowrap;}
        #response{background:#1e1e1e;color:#d4d4d4;padding:1.5rem;border-radius:8px;min-height:150px;max-height:500px;overflow-y:auto;font-family:'Segoe UI',system-ui,sans-serif;font-size:.92rem;line-height:1.7;}
        #response p{margin:.4em 0;}
        #response h1,#response h2,#response h3,#response h4{color:#e8eaed;margin:.9em 0 .3em;}
        #response h1{font-size:1.3em;border-bottom:1px solid #3c3c3c;padding-bottom:.2em;}
        #response h2{font-size:1.15em;}#response h3{font-size:1em;}
        #response code{background:#2d2d2d;padding:2px 6px;border-radius:3px;font-family:'Fira Code','Consolas',monospace;font-size:.85em;color:#f8f8f2;}
        #response pre{background:#2d2d2d;padding:1em;border-radius:6px;overflow-x:auto;margin:.7em 0;}
        #response pre code{background:none;padding:0;}
        #response ul,#response ol{padding-left:1.6em;margin:.4em 0;}
        #response li{margin:.25em 0;}
        #response blockquote{border-left:3px solid #8ab4f8;margin:.5em 0;padding:.3em 0 .3em 1em;color:#9aa0a6;}
        #response table{border-collapse:collapse;width:100%;margin:.7em 0;font-size:.88em;}
        #response th,#response td{border:1px solid #3c3c3c;padding:6px 10px;text-align:left;}
        #response th{background:#2d2d2d;color:#e8eaed;}
        #response a{color:#8ab4f8;text-decoration:none;}
        #response strong{color:#e8eaed;}
        #response hr{border:none;border-top:1px solid #3c3c3c;margin:1em 0;}
        .reasoning-box{background:#2d2d2d;color:#8ab4f8;padding:10px 14px;border-radius:5px;margin-bottom:10px;font-size:.85rem;border-left:3px solid #8ab4f8;display:none;line-height:1.6;max-height:200px;overflow-y:auto;}
        .reasoning-box p{margin:.3em 0;}
        .reasoning-box code{background:#3c3c3c;padding:1px 4px;border-radius:3px;font-size:.82em;}
        .btn-main{padding:12px;background:var(--primary);color:#fff;border:none;border-radius:6px;font-weight:bold;cursor:pointer;font-size:1rem;}
        .btn-small{padding:5px 10px;background:#5f6368;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:.7rem;margin-top:5px;}
        .btn-main:hover,.btn-small:hover{filter:brightness(.9);}
        .metrics{display:flex;gap:20px;font-size:.75rem;color:var(--text-sec);flex-wrap:wrap;}
        .status-dot{width:10px;height:10px;border-radius:50%;display:inline-block;background:#ccc;}
        .status-online{background:var(--gpu);}
        .auth-status{font-size:.7rem;margin-left:10px;font-weight:bold;}
        .btn-copy{padding:5px 8px;background:#5f6368;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:1rem;flex-shrink:0;line-height:1;transition:background .2s;display:inline-flex;align-items:center;justify-content:center;}
        .btn-copy:hover{background:#4a4f54;}
        .btn-copy.copied{background:#2ecc71;}
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <div>
            <h2 style="margin:0">AI Intelligence Console</h2>
            <div class="source-bar" style="margin-top:10px">
                <label><input type="radio" name="source" value="docker" checked> Docker (SSL)</label>
                <label><input type="radio" name="source" value="native"> Native (SSL)</label>
                <label><input type="radio" name="source" value="direct"> Direct (11434)</label>
                <label><input type="radio" name="source" value="custom"> SaaS / Custom</label>
            </div>
        </div>
        <div style="text-align:right">
            <div id="hwBadge" class="badge" style="background:#95a5a6">Standby</div>
            <div id="reasoningIndicator" style="font-size:10px;color:#1a73e8;font-weight:bold;margin-top:5px;display:none;"><i class="bi bi-cpu"></i> REASONING MODEL</div>
        </div>
    </div>
    <div class="grid-config">
        <div class="form-group" id="presetGroup" style="display:none">
            <label>Provider Preset</label>
            <select id="providerPreset">
                <option value="">-- Select Provider --</option>
                <option value="https://api.openai.com/v1">OpenAI</option>
                <option value="https://api.anthropic.com/v1">Anthropic (Claude)</option>
                <option value="https://generativelanguage.googleapis.com/v1beta">Google Gemini</option>
                <option value="https://api.deepseek.com">DeepSeek Cloud</option>
            </select>
        </div>
        <div class="form-group">
            <label>Endpoint URL</label>
            <input type="text" id="apiUrl" placeholder="https://localhost:11443">
        </div>
        <div class="form-group">
            <label>API Key / Token <button id="testAuthBtn" class="btn-small">Test Auth</button> <span id="authResult" class="auth-status"></span></label>
            <div style="display:flex;gap:5px;align-items:center;">
                <input type="text" id="apiKey" placeholder="Paste API key here" style="flex:1;font-family:'Fira Code','Consolas',monospace;font-size:0.85rem;letter-spacing:0.03em;">
                <button class="btn-copy" onclick="copyToClipboard('apiKey',this)" title="Copy API key"><i class="bi bi-clipboard"></i></button>
            </div>
        </div>
        <div class="form-group">
            <label>Context Length</label>
            <input type="number" id="contextLen" value="4096" step="1024">
        </div>
        <div class="form-group">
            <label>Model Name</label>
            <div style="display:flex;gap:5px;align-items:center;">
                <select id="modelSelect" style="flex:1"><option>Loading...</option></select>
                <button class="btn-copy" id="modelSelectCopyBtn" onclick="copyToClipboard('modelSelect',this)" title="Copy model name"><i class="bi bi-clipboard"></i></button>
                <input type="text" id="modelCustom" placeholder="Manual name" style="flex:1;display:none">
                <button class="btn-copy" id="modelCustomCopyBtn" onclick="copyToClipboard('modelCustom',this)" title="Copy model name" style="display:none"><i class="bi bi-clipboard"></i></button>
            </div>
        </div>
        <div class="form-group" style="flex-direction:row;align-items:center;gap:10px;">
            <label><input type="checkbox" id="enableReasoning"> Enable Reasoning Mode</label>
        </div>
    </div>
    <textarea id="promptInput" rows="4" placeholder="Type your message here..."></textarea>
    <button id="sendBtn" class="btn-main">Execute Inference</button>
    <div class="metrics">
        <span>Status: <span class="status-dot" id="statusDot"></span> <span id="statusText">Ready</span></span>
        <span>Latency: <span id="mTotal">-</span></span>
        <span id="mVram">Memory: -</span>
    </div>
    <div id="reasoningOutput" class="reasoning-box"></div>
    <div id="response"><em style="color:#666">Waiting for query...</em></div>
</div>
<script>
    marked.use({gfm:true,breaks:true});
    function renderMd(t){return t?marked.parse(t):'';}
    function applyHighlight(c){c.querySelectorAll('pre code').forEach(el=>hljs.highlightElement(el));}
    const STORAGE={CONFIG:'ai_console_config',LAST_PROMPT:'ai_console_prompt'};
    const els={radios:document.getElementsByName('source'),apiUrl:document.getElementById('apiUrl'),apiKey:document.getElementById('apiKey'),contextLen:document.getElementById('contextLen'),modelSelect:document.getElementById('modelSelect'),modelCustom:document.getElementById('modelCustom'),presetGroup:document.getElementById('presetGroup'),providerPreset:document.getElementById('providerPreset'),prompt:document.getElementById('promptInput'),btn:document.getElementById('sendBtn'),testAuthBtn:document.getElementById('testAuthBtn'),authResult:document.getElementById('authResult'),resp:document.getElementById('response'),reasoningBox:document.getElementById('reasoningOutput'),reasoningInd:document.getElementById('reasoningIndicator'),enableReasoning:document.getElementById('enableReasoning'),badge:document.getElementById('hwBadge'),mTotal:document.getElementById('mTotal'),mVram:document.getElementById('mVram'),statusText:document.getElementById('statusText'),statusDot:document.getElementById('statusDot')};
    function saveConfig(){localStorage.setItem(STORAGE.CONFIG,JSON.stringify({source:Array.from(els.radios).find(r=>r.checked).value,url:els.apiUrl.value,key:els.apiKey.value,ctx:els.contextLen.value,reasoning:els.enableReasoning.checked}));}
    function loadConfig(){const sk=window.__OLLAMA_API_KEY__||'';const d=localStorage.getItem(STORAGE.CONFIG);if(!d){if(sk)els.apiKey.value=sk;handleSourceChange();return;}const c=JSON.parse(d);const r=Array.from(els.radios).find(x=>x.value===c.source);if(r)r.checked=true;els.apiUrl.value=c.url||'';const s=c.source||'docker';const useServerKey=s==='docker'||s==='native'||s==='direct';els.apiKey.value=useServerKey?sk:(c.key||'');els.contextLen.value=c.ctx||4096;els.enableReasoning.checked=c.reasoning||false;handleSourceChange();}
    function copyToClipboard(id,btn){const el=document.getElementById(id);const text=el.value;if(!text)return;const orig=btn.innerHTML;const finish=()=>{btn.innerHTML='<i class="bi bi-check-lg"></i>';btn.classList.add('copied');setTimeout(()=>{btn.innerHTML=orig;btn.classList.remove('copied');},1500);};navigator.clipboard.writeText(text).then(finish).catch(()=>{const ta=document.createElement('textarea');ta.value=text;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.select();document.execCommand('copy');document.body.removeChild(ta);finish();});}
    function handleSourceChange(){const s=Array.from(els.radios).find(r=>r.checked).value;const h=window.location.hostname;const ic=s==='custom';els.presetGroup.style.display=ic?'block':'none';els.modelCustom.style.display=ic?'block':'none';document.getElementById('modelCustomCopyBtn').style.display=ic?'inline-flex':'none';els.modelSelect.style.display=ic?'none':'block';document.getElementById('modelSelectCopyBtn').style.display=ic?'none':'inline-flex';if(s==='docker')els.apiUrl.value=`https://${h}:11443`;else if(s==='native')els.apiUrl.value=`https://${h}:11444`;else if(s==='direct')els.apiUrl.value=`http://${h}:11434`;loadModels();saveConfig();}
    async function testAuthentication(){const url=els.apiUrl.value;const key=els.apiKey.value;if(!key){els.authResult.innerText='Enter a key first';els.authResult.style.color='orange';return;}els.authResult.innerText='Testing...';els.authResult.style.color='var(--text-sec)';try{const res=await fetch(`${url}/v1/models`,{headers:{'Authorization':`Bearer ${key}`}});if(res.ok){els.authResult.innerText='[OK] Key valid';els.authResult.style.color='var(--gpu)';}else{const d=await res.json().catch(()=>({}));els.authResult.innerText=`[ERR] ${res.status}: ${d.error?.code||'Unauthorized'}`;els.authResult.style.color='red';}}catch(e){els.authResult.innerText='Connection failed';els.authResult.style.color='red';}}
    async function loadModels(){const s=Array.from(els.radios).find(r=>r.checked).value;if(s==='custom')return;try{const res=await fetch(`${els.apiUrl.value}/api/tags`);const d=await res.json();els.modelSelect.innerHTML=d.models.map(m=>`<option value="${m.name}">${m.name}</option>`).join('');els.statusDot.className='status-dot status-online';els.statusText.innerText='Online';checkReasoningCapability();}catch(e){els.statusDot.className='status-dot';els.statusText.innerText='Offline / Error';}}
    function checkReasoningCapability(){const n=els.modelSelect.value.toLowerCase();els.reasoningInd.style.display=(n.includes('r1')||n.includes('o1')||n.includes('reason'))?'block':'none';}
    async function execute(){const s=Array.from(els.radios).find(r=>r.checked).value;const url=els.apiUrl.value;const model=s==='custom'?els.modelCustom.value:els.modelSelect.value;const prompt=els.prompt.value;if(!prompt||!model)return;localStorage.setItem(STORAGE.LAST_PROMPT,prompt);els.btn.disabled=true;els.resp.innerHTML='<em style="color:#666">Thinking...</em>';els.reasoningBox.style.display='none';const start=performance.now();try{const res=await fetch(`${url}/v1/chat/completions`,{method:'POST',headers:{'Content-Type':'application/json','Authorization':els.apiKey.value?`Bearer ${els.apiKey.value}`:'Bearer ollama'},body:JSON.stringify({model,messages:[{role:'user',content:prompt}],max_tokens:parseInt(els.contextLen.value)})});const d=await res.json();const content=d.choices[0].message.content;if(content.includes('<think>')){const parts=content.split('</think>');els.reasoningBox.innerHTML=renderMd(parts[0].replace('<think>','').trim());els.reasoningBox.style.display='block';applyHighlight(els.reasoningBox);els.resp.innerHTML=renderMd(parts[1].trim());}else{els.resp.innerHTML=renderMd(content);}applyHighlight(els.resp);els.mTotal.innerText=`${((performance.now()-start)/1000).toFixed(2)}s`;updateHardwareMetrics();}catch(e){els.resp.innerHTML=`<span style="color:#e74c3c">Error: ${e.message}</span>`;}finally{els.btn.disabled=false;}}
    async function updateHardwareMetrics(){const s=Array.from(els.radios).find(r=>r.checked).value;if(s==='custom')return;try{const res=await fetch(`${els.apiUrl.value}/api/ps`);const d=await res.json();const m=d.models?.find(x=>els.modelSelect.value.startsWith(x.name));if(m){const g=m.size_vram||0;const c=(m.size||0)-g;const p=m.size>0?Math.round((g/m.size)*100):0;const gGB=(g/1e9).toFixed(2);const cGB=(c/1e9).toFixed(2);if(p===100){els.badge.textContent=`GPU | ${gGB} GB`;els.badge.style.background='#2ecc71';els.mVram.textContent=`VRAM: ${gGB} GB`;}else if(p>0){els.badge.textContent='HYBRID';els.badge.style.background='#9b59b6';els.mVram.textContent=`VRAM: ${gGB} GB  RAM: ${cGB} GB`;}else{els.badge.textContent=`CPU | ${cGB} GB`;els.badge.style.background='#f39c12';els.mVram.textContent=`RAM: ${cGB} GB`;}}else{els.badge.textContent='Standby';els.badge.style.background='#95a5a6';els.mVram.textContent='Memory: -';}}catch(e){}}
    els.radios.forEach(r=>r.addEventListener('change',handleSourceChange));
    els.providerPreset.addEventListener('change',()=>{els.apiUrl.value=els.providerPreset.value;saveConfig();});
    els.modelSelect.addEventListener('change',checkReasoningCapability);
    els.btn.addEventListener('click',execute);
    els.testAuthBtn.addEventListener('click',testAuthentication);
    window.onload=()=>{loadConfig();els.prompt.value=localStorage.getItem(STORAGE.LAST_PROMPT)||'';setInterval(updateHardwareMetrics,5000);};
</script>
</body>
</html>
HTML_EOF
fi

ok "Dependency check complete."

# =============================================================================
# SYSTEM CHECK: Docker
# =============================================================================
echo ""
if ! docker info > /dev/null 2>&1; then
    err "Docker is not running. Start Docker Desktop (or the Docker daemon) and retry."
    exit 1
fi
ok "Docker is running."

# =============================================================================
# SYSTEM CHECK: Native Ollama
# =============================================================================
NATIVE_OLLAMA=false
if curl -s --max-time 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
    NATIVE_OLLAMA=true
    ok "Native Ollama API is reachable at http://localhost:11434"
else
    warn "Native Ollama is not running. Caddy-only mode will require it for SSL proxying."
fi

# =============================================================================
# GPU DETECTION
# =============================================================================
GPU_TYPE="cpu"
GPU_VRAM_MB=0
GPU_NAME="CPU only"

detect_gpu() {
    # NVIDIA
    if command -v nvidia-smi > /dev/null 2>&1; then
        local raw
        raw=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
        if [ -n "$raw" ]; then
            GPU_NAME=$(echo "$raw" | cut -d',' -f1 | xargs)
            GPU_VRAM_MB=$(echo "$raw" | grep -oE '[0-9]+' | tail -1)
            GPU_TYPE="nvidia"
            return
        fi
    fi

    # AMD ROCm
    if command -v rocm-smi > /dev/null 2>&1; then
        GPU_TYPE="amd"
        GPU_NAME="AMD GPU (ROCm)"
        local vram_bytes
        vram_bytes=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oE 'Total Memory.*: [0-9]+' | grep -oE '[0-9]+$' | head -1)
        if [ -n "$vram_bytes" ]; then
            GPU_VRAM_MB=$((vram_bytes / 1024 / 1024))
        fi
        return
    fi

    # Apple Silicon (unified memory — treat total RAM as available VRAM)
    if [ "$OS" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
        GPU_TYPE="apple"
        GPU_NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
        local ram_bytes
        ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        GPU_VRAM_MB=$((ram_bytes / 1024 / 1024))
        return
    fi
}

detect_gpu

echo ""
echo "  GPU Type : $GPU_TYPE"
echo "  GPU Name : $GPU_NAME"
if [ "$GPU_VRAM_MB" -gt 0 ] 2>/dev/null; then
    echo "  VRAM     : ${GPU_VRAM_MB} MB"
fi

# Compose file recommendation
RECOMMENDED_COMPOSE="cpu"
if   [ "$GPU_TYPE" = "nvidia" ]; then RECOMMENDED_COMPOSE="nvidia"
elif [ "$GPU_TYPE" = "amd"    ]; then RECOMMENDED_COMPOSE="amd"
elif [ "$GPU_TYPE" = "apple"  ]; then RECOMMENDED_COMPOSE="caddy-only"
fi

# =============================================================================
# MODE SELECTION
# =============================================================================
echo ""
echo "========================================================"
echo " OLLAMA DEPLOYMENT SELECTOR"
echo "========================================================"
echo " 1. HYBRID    : Ollama (Docker) + Caddy SSL Proxy"
if [ "$GPU_TYPE" = "apple" ]; then
    echo "               [Apple Silicon: Caddy Only recommended]"
fi
echo " 2. CADDY ONLY: SSL Proxy only — use native Ollama"
echo "               [recommended for AMD / Apple Silicon]"
echo "========================================================"
printf " Enter choice (1-2) [default: 1]: "
read -r CHOICE
CHOICE="${CHOICE:-1}"

# =============================================================================
# STEP 1 — Select docker-compose.yml
# =============================================================================
cd "$BASEDIR"

if [ "$CHOICE" = "2" ]; then
    info "[1/8] CADDY ONLY mode..."
    cp "config/docker-compose.caddy-only.yml" "docker-compose.yml"
else
    info "[1/8] HYBRID mode (GPU: $GPU_TYPE)..."
    cp "config/docker-compose.${RECOMMENDED_COMPOSE}.yml" "docker-compose.yml" 2>/dev/null \
        || cp "config/docker-compose.hybrid.yml" "docker-compose.yml"
fi
ok "docker-compose.yml configured."

# =============================================================================
# STEP 2 — Stop native Ollama if HYBRID mode
# =============================================================================
if [ "$CHOICE" != "2" ]; then
    info "[2/8] Stopping native Ollama (if running)..."
    if [ "$OS" = "Darwin" ]; then
        pkill -x ollama 2>/dev/null && ok "Native Ollama stopped." || info "Native Ollama was not running."
    else
        systemctl stop ollama 2>/dev/null || pkill -x ollama 2>/dev/null || true
        ok "Native Ollama stop attempted."
    fi
else
    info "[2/8] Caddy-only mode — keeping native Ollama running."
fi

# =============================================================================
# STEP 3 — Restart containers (NO -v: preserves caddy_data and the CA)
# =============================================================================
info "[3/8] Restarting containers (keeping SSL volume)..."
docker compose down
docker compose up -d --force-recreate
ok "Containers started."

# =============================================================================
# STEP 4 — Container status
# =============================================================================
info "[4/8] Container status:"
docker ps --filter "name=caddy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# =============================================================================
# STEP 5 — Optional model pull (with VRAM-aware recommendations)
# =============================================================================
echo ""
echo "[5/8] Select a model to pull (or skip):"
echo ""

# deepseek-r1:1.5b — always compatible
echo "  1. deepseek-r1:1.5b  | CPU / embedded GPU  | ~1 GB    [always compatible]"

# gemma4:e4b — needs 8 GB VRAM
if [ "$GPU_VRAM_MB" -ge 8192 ] 2>/dev/null; then
    compat_gemma="${GRN}compatible — ${GPU_VRAM_MB} MB VRAM${NC}"
else
    compat_gemma="${YEL}may not fit — ${GPU_VRAM_MB} MB VRAM${NC}"
fi
echo -e "  2. gemma4:e4b         | GPU > 8 GB          | ~5 GB    [$compat_gemma]"

# gpt-oss:20b — needs 14 GB VRAM
if [ "$GPU_VRAM_MB" -ge 14336 ] 2>/dev/null; then
    compat_gpt="${GRN}compatible — ${GPU_VRAM_MB} MB VRAM${NC}"
else
    compat_gpt="${YEL}may not fit — ${GPU_VRAM_MB} MB VRAM${NC}"
fi
echo -e "  3. gpt-oss:20b        | GPU > 14 GB         | ~12 GB   [$compat_gpt]"

echo "  4. Custom model name"
echo "  0. Skip"
echo ""
printf "   Choice (0-4): "
read -r MODEL_CHOICE

MODEL_NAME=""
case "$MODEL_CHOICE" in
    1) MODEL_NAME="deepseek-r1:1.5b" ;;
    2) MODEL_NAME="gemma4:e4b" ;;
    3) MODEL_NAME="gpt-oss:20b" ;;
    4) printf "   Model name: "; read -r MODEL_NAME ;;
    *) MODEL_NAME="" ;;
esac

if [ -n "$MODEL_NAME" ]; then
    info "Pulling: $MODEL_NAME"
    docker exec ollama ollama pull "$MODEL_NAME"
else
    info "Skipping model pull."
fi

# =============================================================================
# STEP 6 — Poll until Caddy is ready (up to 5 min)
# =============================================================================
info "[6/8] Waiting for Caddy HTTPS (up to 5 min)..."
CADDY_READY=false
for i in $(seq 1 30); do
    if curl -sk --max-time 5 https://localhost:11443/api/tags > /dev/null 2>&1; then
        CADDY_READY=true
        ok "Caddy is ready."
        break
    fi
    echo "  [$i/30] not ready, retrying in 10s..."
    sleep 10
done

if [ "$CADDY_READY" = false ]; then
    warn "Timeout — Caddy may still be starting. Continuing anyway."
fi

# =============================================================================
# STEP 7 — Extract and install SSL certificate
# =============================================================================
info "[7/8] Refreshing SSL certificate..."
rm -f "$BASEDIR/root.crt"
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > "$BASEDIR/root.crt" 2>/dev/null || true

if [ ! -f "$BASEDIR/root.crt" ]; then
    warn "root.crt not found — Caddy may still be initializing."
else
    # --- macOS ---
    if [ "$OS" = "Darwin" ]; then
        sudo security add-trusted-cert -d -r trustRoot \
            -k /Library/Keychains/System.keychain "$BASEDIR/root.crt" 2>/dev/null \
            && ok "macOS Keychain updated." \
            || warn "Could not update macOS Keychain (run manually if needed)."

    # --- Linux ---
    else
        # Debian / Ubuntu
        if command -v update-ca-certificates > /dev/null 2>&1; then
            sudo cp "$BASEDIR/root.crt" /usr/local/share/ca-certificates/caddy-local.crt
            sudo update-ca-certificates > /dev/null 2>&1
            ok "Linux CA store updated (Debian/Ubuntu)."
        # RHEL / Fedora / CentOS
        elif command -v update-ca-trust > /dev/null 2>&1; then
            sudo cp "$BASEDIR/root.crt" /etc/pki/ca-trust/source/anchors/caddy-local.crt
            sudo update-ca-trust extract
            ok "Linux CA store updated (RHEL/Fedora)."
        else
            warn "Could not detect CA update tool. Install manually: root.crt"
        fi
    fi

    # --- Firefox NSS (macOS + Linux) ---
    CERTUTIL_BIN=""
    if [ "$OS" = "Darwin" ]; then
        CERTUTIL_BIN=$(find "/Applications/Firefox.app" -name "certutil" 2>/dev/null | head -1)
    else
        CERTUTIL_BIN=$(command -v certutil 2>/dev/null || true)
    fi

    if [ -n "$CERTUTIL_BIN" ]; then
        if [ "$OS" = "Darwin" ]; then
            PROFILE_ROOT="$HOME/Library/Application Support/Firefox/Profiles"
        else
            PROFILE_ROOT="$HOME/.mozilla/firefox"
        fi

        if [ -d "$PROFILE_ROOT" ]; then
            while IFS= read -r -d '' profile; do
                if [ -f "$profile/cert9.db" ]; then
                    "$CERTUTIL_BIN" -D -n "Caddy Local CA" -d "sql:$profile" 2>/dev/null || true
                    "$CERTUTIL_BIN" -A -n "Caddy Local CA" -t "CT,C,C" \
                        -i "$BASEDIR/root.crt" -d "sql:$profile" 2>/dev/null \
                        && ok "Firefox profile updated: $(basename "$profile")" \
                        || warn "Could not update Firefox profile: $(basename "$profile")"
                fi
            done < <(find "$PROFILE_ROOT" -maxdepth 1 -type d -print0 2>/dev/null)
        fi
    else
        warn "Firefox certutil not found. Certificate not added to Firefox NSS store."
        if [ "$OS" = "Darwin" ]; then
            info "Install: brew install nss  OR  manually trust root.crt in Firefox > Settings > Certificates"
        else
            info "Install: sudo apt install libnss3-tools  OR  sudo dnf install nss-tools"
        fi
    fi
fi

# =============================================================================
# STEP 8 — Test API + open browser
# =============================================================================
info "[8/8] Testing API (/api/tags)..."
echo "---------------------------------------------------------"
curl -sk --max-time 5 https://localhost:11443/api/tags || warn "Could not reach Caddy API."
echo ""
echo "---------------------------------------------------------"
echo ""

URL="https://localhost:11443/ai-console.html"
info "Opening: $URL"
if [ "$OS" = "Darwin" ]; then
    open "$URL"
elif command -v xdg-open > /dev/null 2>&1; then
    xdg-open "$URL" &
else
    info "Open manually: $URL"
fi

echo ""
ok "Deployment complete."
echo ""
echo "  NOTE: If Firefox shows a certificate error:"
echo "    1. Restart Firefox completely."
echo "    2. If it persists: about:config > security.enterprise_roots.enabled = true"
echo "    3. Never run 'docker compose down -v' — it regenerates the Caddy CA."
echo ""
info "Streaming Caddy logs..."
docker logs -f caddy
