# Ollama Local SSL

A deployment toolkit that wraps Ollama with a Caddy reverse proxy to provide HTTPS, CORS headers, and a mock authentication endpoint. The goal is to make a local Ollama instance behave like a cloud API provider — enabling direct integration with tools that require SSL and API key authentication.

---

## Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start — Windows](#quick-start--windows)
- [Quick Start — macOS / Linux](#quick-start--macos--linux)
- [Manual Deployment](#manual-deployment)
- [Deployment Modes](#deployment-modes)
- [SSL Certificate Management](#ssl-certificate-management)
- [Model Reference](#model-reference)
- [Project Structure](#project-structure)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
Browser / AI Tool
      |
      | HTTPS :11443
      v
  Caddy (Docker)           <- TLS termination, CORS, mock auth
      |
      | HTTP :11434
      v
  Ollama (Docker or native) <- inference engine
```

Caddy generates a self-signed local CA via its internal PKI. The deployment scripts extract that CA certificate and install it in the system trust store so that browsers and tools accept the connection without warnings.

Port mapping:

| External port | Internal target | Source         |
|---------------|-----------------|----------------|
| `:11443`      | Ollama (Docker) | `https://localhost:11443` |
| `:11444`      | Ollama (native) | `https://localhost:11444` |

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- [Ollama](https://ollama.com/download) installed natively (required for Caddy-only mode; recommended for AMD / Apple Silicon)
- Administrator / sudo access (required for certificate installation)

---

## Quick Start — Windows

Run as Administrator:

```
deploy-ollama-local.bat
```

The script will:
1. Generate any missing config files automatically
2. Detect the GPU type and select the appropriate Docker Compose profile
3. Start containers (preserving existing SSL volumes)
4. Install the Caddy CA certificate in the Windows trust store and Firefox NSS database
5. Open the AI console at `https://localhost:11443/ai-console.html`

---

## Quick Start — macOS / Linux

```bash
chmod +x deploy-ollama-local.sh
./deploy-ollama-local.sh
```

The script performs the same steps as the Windows version, adapted for the platform:
- Detects NVIDIA (nvidia-smi), AMD ROCm (rocm-smi), or Apple Silicon
- Displays VRAM-aware model compatibility in the model selection menu
- Installs the CA certificate via `security add-trusted-cert` (macOS) or `update-ca-certificates` / `update-ca-trust` (Linux)
- Updates the Firefox NSS database directly when Firefox's `certutil` is available

---

## Manual Deployment

The following steps reproduce what the deployment scripts do, without automation.

### 1. Select a Docker Compose profile

Copy the appropriate template to `docker-compose.yml`:

```bash
# Nvidia GPU (Docker with GPU passthrough)
cp config/docker-compose.nvidia.yml docker-compose.yml

# AMD GPU (Docker with ROCm)
cp config/docker-compose.amd.yml docker-compose.yml

# CPU only
cp config/docker-compose.cpu.yml docker-compose.yml

# Caddy proxy only (connect to native Ollama)
cp config/docker-compose.caddy-only.yml docker-compose.yml
```

### 2. Start containers

```bash
# Important: do NOT use -v (that would destroy the Caddy CA and break SSL)
docker compose down
docker compose up -d --force-recreate
```

### 3. Verify containers are running

```bash
docker ps --filter "name=caddy"
docker ps --filter "name=ollama"
```

### 4. Pull a model

```bash
docker exec ollama ollama pull deepseek-r1:1.5b
```

### 5. Wait for Caddy to be ready

Caddy generates its internal CA on the first start. Poll until the API responds:

```bash
until curl -sk https://localhost:11443/api/tags > /dev/null 2>&1; do
    echo "Waiting for Caddy..."
    sleep 5
done
echo "Caddy ready."
```

### 6. Extract the CA certificate

```bash
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > root.crt
```

### 7. Install the CA certificate

**Windows (run as Administrator):**
```cmd
certutil -addstore -f "ROOT" root.crt
```

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root.crt
```

**Linux (Debian / Ubuntu):**
```bash
sudo cp root.crt /usr/local/share/ca-certificates/caddy-local.crt
sudo update-ca-certificates
```

**Linux (RHEL / Fedora / CentOS):**
```bash
sudo cp root.crt /etc/pki/ca-trust/source/anchors/caddy-local.crt
sudo update-ca-trust extract
```

### 8. Test the connection

```bash
curl -sk https://localhost:11443/api/tags
```

A JSON response listing installed models confirms the stack is working.

### 9. Open the console

Open `https://localhost:11443/ai-console.html` in a browser.

---

## Deployment Modes

### Hybrid mode (default)

Ollama runs inside Docker alongside Caddy. Use this when:
- You have an Nvidia GPU (Docker supports CUDA passthrough on Linux and Windows WSL2)
- You want a fully containerised stack with no local Ollama installation required

GPU passthrough limitations:
- **AMD ROCm on Docker / Windows**: unstable; use Caddy-only mode instead
- **Apple Silicon**: Docker cannot access Metal; use Caddy-only mode instead

### Caddy-only mode

Only the Caddy proxy runs in Docker. Ollama runs natively on the host OS, accessed via `host.docker.internal:11434`. Use this when:
- You have an AMD GPU and want ROCm acceleration
- You are on macOS with Apple Silicon and want Metal acceleration
- You want to manage the Ollama process yourself (service, launchd, systemd)

---

## SSL Certificate Management

Caddy generates a local CA and signs a certificate for `localhost` on first start. The CA is stored in the `caddy_data` Docker volume.

### Critical rule

**Never run `docker compose down -v`.**

The `-v` flag removes named volumes, including `caddy_data`. This forces Caddy to generate a new CA on the next start. Any previously installed `root.crt` becomes invalid, and browsers will show `SEC_ERROR_BAD_SIGNATURE` or similar errors until the new certificate is installed.

To reset containers without destroying the CA:

```bash
docker compose down       # no -v
docker compose up -d
```

To do a full reset intentionally (destroys stored models and CA):

```bash
docker compose down -v    # only when you want a clean slate
```

### Firefox

Firefox does not use the operating system trust store by default. Two options:

**Option A — Enterprise roots policy (recommended):**

Windows (run as Administrator):
```cmd
reg add "HKLM\SOFTWARE\Policies\Mozilla\Firefox\Certificates" /v "ImportEnterpriseRoots" /t REG_DWORD /d 1 /f
```

Linux / macOS — create or edit `distribution/policies.json` inside the Firefox installation directory:
```json
{
  "policies": {
    "Certificates": {
      "ImportEnterpriseRoots": true
    }
  }
}
```

Restart Firefox after applying.

**Option B — Direct NSS database update:**

Requires `certutil` from `libnss3-tools` (Linux) or from the Firefox application bundle (macOS/Windows):

```bash
# Linux
certutil -D -n "Caddy Local CA" -d "sql:$HOME/.mozilla/firefox/<profile>" 2>/dev/null
certutil -A -n "Caddy Local CA" -t "CT,C,C" -i root.crt -d "sql:$HOME/.mozilla/firefox/<profile>"

# macOS
/Applications/Firefox.app/Contents/MacOS/certutil -A -n "Caddy Local CA" -t "CT,C,C" \
    -i root.crt -d "sql:$HOME/Library/Application Support/Firefox/Profiles/<profile>"
```

**Option C — about:config:**

Go to `about:config` in Firefox and set `security.enterprise_roots.enabled` to `true`. Restart Firefox.

---

## Model Reference

| Model | Min VRAM | Disk | Notes |
|-------|----------|------|-------|
| `deepseek-r1:1.5b` | CPU / 2 GB | ~1 GB | Reasoning model; works on any hardware |
| `gemma4:e4b` | 8 GB | ~5 GB | Google Gemma 4, embedded quantisation |
| `gpt-oss:20b` | 14 GB | ~12 GB | Large model; Nvidia recommended |

Pull a model after the stack is running:

```bash
# Via Docker exec (Hybrid mode)
docker exec ollama ollama pull deepseek-r1:1.5b

# Via native Ollama CLI (Caddy-only mode)
ollama pull deepseek-r1:1.5b
```

---

## Project Structure

```
.
├── deploy-ollama-local.bat    Windows deployment script (self-contained)
├── deploy-ollama-local.sh     macOS / Linux deployment script (self-contained)
├── ai-console.html            Web console (served by Caddy)
├── root.crt                   Extracted Caddy CA certificate (generated at runtime)
├── docker-compose.yml         Active compose file (copied from config/ at runtime)
├── config/
│   ├── Caddyfile
│   ├── docker-compose.hybrid.yml
│   ├── docker-compose.caddy-only.yml
│   ├── docker-compose.nvidia.yml
│   ├── docker-compose.amd.yml
│   └── docker-compose.cpu.yml
└── tools/
    └── detect-gpu.ps1         Windows GPU detection (PowerShell)
```

Both deployment scripts are self-contained: if the `config/` or `tools/` directories are missing, the scripts regenerate all required files from embedded templates before proceeding.

---

## Troubleshooting

**`SEC_ERROR_BAD_SIGNATURE` in Firefox**
The Caddy CA was regenerated (likely due to `docker compose down -v`). Re-run the deployment script to extract and install the new certificate, then restart Firefox.

**`curl: (60) SSL certificate problem`**
The CA is not trusted in the system store. Re-run the deployment script, or install `root.crt` manually (see SSL Certificate Management above). Use `-k` as a temporary workaround for testing only.

**Caddy container exits immediately**
Check for a `Caddyfile` syntax error:
```bash
docker logs caddy
```

**`docker exec ollama` fails**
The Ollama container is not running. Check:
```bash
docker logs ollama
```
If you are in Caddy-only mode, the Ollama container is not started by design.

**Models not listed in the console**
The console fetches `/api/tags` on load. If Caddy or Ollama is still starting, click the source radio button again to refresh, or reload the page after a few seconds.
