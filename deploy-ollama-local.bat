@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: OLLAMA LOCAL SSL DEPLOYMENT — Self-Contained Edition
:: ============================================================

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Run as Administrator.
    pause
    exit /b 1
)

set "BASEDIR=%~dp0"
if "%BASEDIR:~-1%"=="\" set "BASEDIR=%BASEDIR:~0,-1%"
cd /d "%BASEDIR%"

:: ============================================================
:: STEP 0 — Self-init: generate any missing dependency files
:: ============================================================
echo [0/7] Checking dependencies...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%~f0'; $raw=Get-Content -LiteralPath $f -Raw; $m=[regex]::Match($raw,'(?ms)::__PS1_INIT_BEGIN__\r?\n(.*?)::__PS1_INIT_END__'); if($m.Success){$s=($m.Groups[1].Value -split '\r?\n' | ForEach-Object{$_ -replace '^::',''})-join [Environment]::NewLine; $t=[IO.Path]::GetTempFileName()+'.ps1'; [IO.File]::WriteAllText($t,$s,[Text.Encoding]::UTF8); & $t '%BASEDIR%'; Remove-Item $t -EA 0}else{Write-Host '[WARN] Embedded init section not found.' -ForegroundColor Yellow}"

:: ============================================================
:: MODE SELECTION
:: ============================================================
echo.
echo =========================================================
echo  OLLAMA DEPLOYMENT SELECTOR
echo =========================================================
echo  1. HYBRID    : Ollama (Docker) + Caddy SSL Proxy
echo  2. CADDY ONLY: SSL Proxy only (native Ollama / AMD / Silicon
echo =========================================================
set /p CHOICE="Enter choice (1-2): "
if "%CHOICE%"=="" set CHOICE=1

:: ============================================================
:: DOCKER CHECK
:: ============================================================
docker info >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Docker is NOT running. Start Docker Desktop and retry.
    pause
    exit /b 1
)

:: ============================================================
:: STEP 1 — Setup docker-compose.yml
:: ============================================================
if "%CHOICE%"=="2" (
    echo [1/7] CADDY ONLY mode...
    copy /y "config\docker-compose.caddy-only.yml" "docker-compose.yml" >nul
) else (
    echo [1/7] HYBRID mode -- detecting GPU...
    if exist "tools\detect-gpu.ps1" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools\detect-gpu.ps1"
    )
    if not exist "docker-compose.yml" (
        copy /y "config\docker-compose.hybrid.yml" "docker-compose.yml" >nul
    )
)

:: ============================================================
:: STEP 1B — Configure CORS origins (OLLAMA_ORIGINS)
:: ============================================================
echo.
echo CORS origin policy (OLLAMA_ORIGINS)
echo   1. Allow all origins (*)
echo   2. Allow specific origin(s) (comma-separated)
set /p ORIGIN_CHOICE="Enter choice (1-2) [default 1]: "
if "%ORIGIN_CHOICE%"=="" set ORIGIN_CHOICE=1
if "%ORIGIN_CHOICE%"=="2" (
    set /p ORIGINS_VALUE="Enter origin(s), e.g. https://app.local,https://portal.local: "
) else (
    set "ORIGINS_VALUE=*"
)
if "!ORIGINS_VALUE!"=="" set "ORIGINS_VALUE=*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%BASEDIR%\.env'; $k='OLLAMA_ORIGINS'; $v='!ORIGINS_VALUE!'; if(Test-Path $p){$c=Get-Content -LiteralPath $p; if($c -match ('^'+[regex]::Escape($k)+'=')){ $c = $c -replace ('^'+[regex]::Escape($k)+'.*'), ($k+'='+$v); Set-Content -LiteralPath $p -Value $c -Encoding UTF8 } else { Add-Content -LiteralPath $p -Value ($k+'='+$v) }} else { Set-Content -LiteralPath $p -Value @('OLLAMA_API_KEY=changeme','OLLAMA_TIMEOUT=10m',($k+'='+$v)) -Encoding UTF8 }"
echo [1.5/7] OLLAMA_ORIGINS configured as: !ORIGINS_VALUE!

:: ============================================================
:: STEP 2 — Kill native Ollama
:: ============================================================
echo [2/7] Stopping native Ollama (if running)...
taskkill /IM "Ollama.exe" /F >nul 2>&1
taskkill /IM "ollama_llama_server.exe" /F >nul 2>&1

:: ============================================================
:: STEP 3 — Restart containers (NO -v: preserves Caddy CA volume)
::          Using -v destroys caddy_data and generates a new CA,
::          causing SEC_ERROR_BAD_SIGNATURE in Firefox every run.
:: ============================================================
echo [3/7] Restarting containers (keeping SSL volume)...
docker compose down
docker compose up -d --force-recreate

:: ============================================================
:: STEP 4 — Container status
:: ============================================================
echo [4/7] Container status:
docker ps --filter "name=caddy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

:: ============================================================
:: STEP 5 — Optional model pull
:: ============================================================
echo.
echo [5/7] Select a model to pull (or skip):
echo.
echo   1. deepseek-r1:1.5b   ^| CPU / embedded GPU   ^| ~1 GB
echo   2. gemma4:e4b         ^| GPU ^> 8 GB          ^| ~5 GB
echo   3. gpt-oss:20b        ^| GPU ^> 14 GB         ^| ~12 GB
echo   4. Custom model name
echo   0. Skip
echo.
set /p MODEL_CHOICE="   Choice (0-4): "

set MODEL_NAME=
if "!MODEL_CHOICE!"=="1" set MODEL_NAME=deepseek-r1:1.5b
if "!MODEL_CHOICE!"=="2" set MODEL_NAME=gemma4:e4b
if "!MODEL_CHOICE!"=="3" set MODEL_NAME=gpt-oss:20b
if "!MODEL_CHOICE!"=="4" (
    set /p MODEL_NAME="   Model name: "
)

if not "!MODEL_NAME!"=="" (
    echo Pulling: !MODEL_NAME!
    docker exec ollama ollama pull !MODEL_NAME!
) else (
    echo Skipping model pull.
)

:: ============================================================
:: STEP 7 — Extract cert + install in Windows store + Firefox
:: ============================================================
echo [6/7] Refreshing SSL certificate...
if exist root.crt del /q root.crt
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > root.crt 2>nul

if not exist root.crt (
    echo [WARN] root.crt not found -- Caddy may still be initializing.
    goto :CERT_DONE
)

certutil -addstore -f "ROOT" root.crt >nul 2>&1
echo   [OK] Windows Root CA store updated.

:: Firefox: trust Windows enterprise roots (takes effect on Firefox restart)
reg add "HKLM\SOFTWARE\Policies\Mozilla\Firefox\Certificates" /v "ImportEnterpriseRoots" /t REG_DWORD /d 1 /f >nul 2>&1
echo   [OK] Firefox enterprise roots policy applied.

:: Firefox: update NSS cert9.db directly (no restart needed for existing profiles)
powershell -NoProfile -Command "$cu=@('C:\Program Files\Mozilla Firefox\certutil.exe','C:\Program Files (x86)\Mozilla Firefox\certutil.exe') | Where-Object{Test-Path $_} | Select-Object -First 1; if(-not $cu){Write-Host '  [INFO] Firefox certutil not found, skipping NSS update.' -ForegroundColor Gray; return}; $pr=Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'; if(-not (Test-Path $pr)){return}; Get-ChildItem $pr -Directory | Where-Object{$_.Name -match '\.(default|default-release)'} | ForEach-Object{if(Test-Path (Join-Path $_.FullName 'cert9.db')){& $cu -D -n 'Caddy Local CA' -d ('sql:'+$_.FullName) 2>&1|Out-Null; & $cu -A -n 'Caddy Local CA' -t 'CT,C,C' -i '%BASEDIR%\root.crt' -d ('sql:'+$_.FullName) 2>&1|Out-Null; Write-Host ('  [OK] Firefox profile updated: '+$_.Name) -ForegroundColor Green}}"

:CERT_DONE

:: ============================================================
:: STEP 8 — Test API + open browser
:: ============================================================
echo [7/7] Testing API (/api/tags)...
echo ---------------------------------------------------------
curl.exe -s -k --ssl-no-revoke https://localhost:11443/api/tags
echo.
echo ---------------------------------------------------------
echo.
echo Opening: https://localhost:11443/ai-console.html
start https://localhost:11443/ai-console.html
echo.
echo [DONE] Deployment complete.
echo.
echo NOTE - If Firefox still shows a cert error:
echo   1. Close Firefox completely and reopen it
echo   2. If that fails: about:config -^> security.enterprise_roots.enabled = true
echo   3. Root cause: never use "docker compose down -v" -- it regenerates the CA
echo.
echo [INFO] Streaming Caddy logs...
docker logs -f caddy
exit /b 0

::============================================================
:: EMBEDDED POWERSHELL INIT SCRIPT
:: Each line prefixed with :: so CMD ignores it entirely.
:: Step 0 extracts this section, strips :: prefix, runs it.
::============================================================
::__PS1_INIT_BEGIN__
::param([string]$BasePath)
::
::function Write-Init([string]$msg) { Write-Host "[INIT] $msg" -ForegroundColor Yellow }
::
::foreach ($d in @("$BasePath\config", "$BasePath\tools")) {
::    if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory | Out-Null; Write-Init "Created: $d" }
::}
::
::#region .env (API Key)
::$envFile = "$BasePath\.env"
::if (-not (Test-Path $envFile)) {
::    Write-Init "Generating .env with random API key"
::    $bytes = New-Object byte[] 32
::    [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($bytes)
::    $key = [System.BitConverter]::ToString($bytes).Replace('-','').ToLower()
::    Set-Content -Path $envFile -Encoding UTF8 -Value @("OLLAMA_API_KEY=$key", "OLLAMA_TIMEOUT=10m")
::    Write-Host "[INIT] .env created. Use this key in ELO DMS: $key" -ForegroundColor Green
::} else {
::    Write-Init ".env already exists, skipping key generation."
::}
::#endregion
::
::#region Caddyfile
::$f = "$BasePath\config\Caddyfile"
::if (-not (Test-Path $f)) {
::    Write-Init "Generating config\Caddyfile"
::    Set-Content -Path $f -Encoding UTF8 -Value @'
::{
::    admin off
::}
::
::# Puerto 11443 externo → 11434 interno Caddy (Ollama Docker)
::https://localhost:11434, https://127.0.0.1:11434 {
::
::    root * /usr/share/caddy
::    log {
::        output stdout
::        format console
::    }
::
::    # CORS preflight — sin auth
::    @preflight method OPTIONS
::    handle @preflight {
::        header Access-Control-Allow-Origin "{env.OLLAMA_ORIGINS}"
::        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
::        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
::        respond "" 204
::    }
::
::    # Bearer auth para /v1/* (OpenAI-compatible endpoints)
::    @unauthorized {
::        not header Authorization "Bearer {env.OLLAMA_API_KEY}"
::        path /v1/*
::    }
::    handle @unauthorized {
::        header Content-Type "application/json"
::        header Access-Control-Allow-Origin "{env.OLLAMA_ORIGINS}"
::        respond `{"error":{"message":"Incorrect API key provided. Verify the key used matches the configured OLLAMA_API_KEY.","type":"invalid_api_key","param":null,"code":"invalid_api_key"}}` 401
::    }
::
::    handle /api/* {
::        reverse_proxy ollama:11434 {
::            header_down -Access-Control-Allow-Origin
::            transport http {
::                response_header_timeout {$OLLAMA_TIMEOUT}
::                dial_timeout 30s
::            }
::        }
::    }
::
::    handle /v1/* {
::        reverse_proxy ollama:11434 {
::            header_down -Access-Control-Allow-Origin
::            transport http {
::                response_header_timeout {$OLLAMA_TIMEOUT}
::                dial_timeout 30s
::            }
::        }
::    }
::
::    handle {
::        templates
::        file_server
::    }
::
::    header {
::        Access-Control-Allow-Origin "{env.OLLAMA_ORIGINS}"
::        Access-Control-Allow-Methods "GET, POST, OPTIONS"
::        Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
::    }
::
::    tls internal
::}
::
::# Puerto 11444 externo → 11435 interno Caddy (Ollama nativo via proxy)
::https://localhost:11435, https://127.0.0.1:11435 {
::
::    root * /usr/share/caddy
::    log {
::        output stdout
::        format console
::    }
::
::    @preflight method OPTIONS
::    handle @preflight {
::        header Access-Control-Allow-Origin "{env.OLLAMA_ORIGINS}"
::        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
::        header Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
::        respond "" 204
::    }
::
::    @unauthorized {
::        not header Authorization "Bearer {env.OLLAMA_API_KEY}"
::        path /v1/*
::    }
::    handle @unauthorized {
::        header Content-Type "application/json"
::        header Access-Control-Allow-Origin "{env.OLLAMA_ORIGINS}"
::        respond `{"error":{"message":"Incorrect API key provided. Verify the key used matches the configured OLLAMA_API_KEY.","type":"invalid_api_key","param":null,"code":"invalid_api_key"}}` 401
::    }
::
::    handle /api/* {
::        reverse_proxy host.docker.internal:11434 {
::            header_down -Access-Control-Allow-Origin
::            transport http {
::                response_header_timeout {$OLLAMA_TIMEOUT}
::                dial_timeout 30s
::            }
::        }
::    }
::
::    handle /v1/* {
::        reverse_proxy host.docker.internal:11434 {
::            header_down -Access-Control-Allow-Origin
::            transport http {
::                response_header_timeout {$OLLAMA_TIMEOUT}
::                dial_timeout 30s
::            }
::        }
::    }
::
::    handle {
::        templates
::        file_server
::    }
::
::    header {
::        Access-Control-Allow-Origin "{env.OLLAMA_ORIGINS}"
::        Access-Control-Allow-Methods "GET, POST, OPTIONS"
::        Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
::    }
::
::    tls internal
::}
::'@
::}
::#endregion
::
::#region docker-compose.hybrid.yml
::$f = "$BasePath\config\docker-compose.hybrid.yml"
::if (-not (Test-Path $f)) {
::    Write-Init "Generating config\docker-compose.hybrid.yml"
::    Set-Content -Path $f -Encoding UTF8 -Value @'
::services:
::  caddy:
::    image: caddy:latest
::    container_name: caddy
::    restart: always
::    extra_hosts:
::      - "host.docker.internal:host-gateway"
::    ports:
::      - "11443:11434"
::      - "11444:11435"
::    environment:
::      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
::      - OLLAMA_TIMEOUT=${OLLAMA_TIMEOUT:-10m}
::      - OLLAMA_ORIGINS=${OLLAMA_ORIGINS:-*}
::    volumes:
::      - ./config/Caddyfile:/etc/caddy/Caddyfile
::      - .:/usr/share/caddy
::      - caddy_data:/data
::    depends_on:
::      - ollama
::
::  ollama:
::    image: ollama/ollama
::    container_name: ollama
::    restart: always
::    volumes:
::      - ollama_data:/root/.ollama
::
::volumes:
::  ollama_data:
::  caddy_data:
::'@
::}
::#endregion
::
::#region docker-compose.caddy-only.yml
::$f = "$BasePath\config\docker-compose.caddy-only.yml"
::if (-not (Test-Path $f)) {
::    Write-Init "Generating config\docker-compose.caddy-only.yml"
::    Set-Content -Path $f -Encoding UTF8 -Value @'
::services:
::  caddy:
::    image: caddy:latest
::    container_name: caddy
::    restart: always
::    extra_hosts:
::      - "host.docker.internal:host-gateway"
::    ports:
::      - "11443:11434"
::      - "11444:11435"
::    environment:
::      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
::      - OLLAMA_TIMEOUT=${OLLAMA_TIMEOUT:-10m}
::      - OLLAMA_ORIGINS=${OLLAMA_ORIGINS:-*}
::    volumes:
::      - ./config/Caddyfile:/etc/caddy/Caddyfile
::      - .:/usr/share/caddy
::      - caddy_data:/data
::
::volumes:
::  caddy_data:
::'@
::}
::#endregion
::
::#region detect-gpu.ps1
::$f = "$BasePath\tools\detect-gpu.ps1"
::if (-not (Test-Path $f)) {
::    Write-Init "Generating tools\detect-gpu.ps1"
::    Set-Content -Path $f -Encoding UTF8 -Value @'
::function Get-GPUDetection {
::    $gpus = Get-CimInstance Win32_VideoController
::    $foundNvidia = $false
::    $foundAMD = $false
::
::    foreach ($gpu in $gpus) {
::        $name = $gpu.Name.ToLower()
::        if ($name -like "*nvidia*") { $foundNvidia = $true }
::        if ($name -like "*amd*" -or $name -like "*radeon*") { $foundAMD = $true }
::    }
::
::    if ($foundNvidia) { 
::        Write-Host "Nvidia GPU detected. Supported in Docker!" -ForegroundColor Green
::        return "nvidia" 
::    }
::    if ($foundAMD) { 
::        Write-Host "AMD GPU detected, but Docker on Windows requires advanced WSL2 config for ROCm." -ForegroundColor Yellow
::        Write-Host "Falling back to CPU mode for stability." -ForegroundColor Gray
::        return "cpu" 
::    }
::    return "cpu"
::}
::
::$type = Get-GPUDetection
::Write-Host "Detected GPU Type: $type" -ForegroundColor Cyan
::
::$sourceFile = "config\docker-compose.$type.yml"
::if (Test-Path $sourceFile) {
::    Copy-Item $sourceFile "docker-compose.yml" -Force
::    Write-Host "Success: docker-compose.yml updated for $type" -ForegroundColor Green
::} else {
::    Write-Host "[WARN] Template $sourceFile not found. Using hybrid as fallback." -ForegroundColor Yellow
::    $fallback = "config\docker-compose.hybrid.yml"
::    if (Test-Path $fallback) {
::        Copy-Item $fallback "docker-compose.yml" -Force
::        Write-Host "docker-compose.yml set for hybrid (fallback)" -ForegroundColor Green
::    } else {
::        Write-Host "[WARN] No fallback template found. docker-compose.yml unchanged." -ForegroundColor Yellow
::    }
::}
::'@
::}
::#endregion
::
::#region ai-console.html
::$f = "$BasePath\ai-console.html"
::if (-not (Test-Path $f)) {
::    Write-Init "Generating ai-console.html"
::    Set-Content -Path $f -Encoding UTF8 -Value @'
::<!DOCTYPE html>
::<html lang="en">
::<head>
::    <meta charset="UTF-8">
::    <meta name="viewport" content="width=device-width, initial-scale=1.0">
::    <title>Universal AI Console - SSL Aware</title>
::    <script>window.__OLLAMA_API_KEY__ = "{{env "OLLAMA_API_KEY"}}";</script>
::    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
::    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
::    <script src="https://cdn.jsdelivr.net/npm/marked@9/marked.min.js"></script>
::    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
::    <style>
::        :root {
::            --bg: #f8f9fa; --card: #ffffff; --primary: #1a73e8;
::            --gpu: #2ecc71; --cpu: #f39c12; --hybrid: #9b59b6;
::            --text: #202124; --text-sec: #5f6368;
::        }
::        body { font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 20px; display: flex; justify-content: center; }
::        .container { background: var(--card); padding: 2rem; border-radius: 16px; box-shadow: 0 4px 25px rgba(0,0,0,0.1); width: 100%; max-width: 900px; display: flex; flex-direction: column; gap: 1rem; }
::        .header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 1px solid #eee; padding-bottom: 1rem; }
::        .grid-config { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; background: #f1f3f4; padding: 15px; border-radius: 10px; }
::        .form-group { display: flex; flex-direction: column; gap: 5px; }
::        label { font-weight: 600; font-size: 0.85rem; color: var(--text-sec); }
::        input, select, textarea { padding: 10px; border: 1px solid #dadce0; border-radius: 6px; font-size: 0.95rem; }
::        .source-bar { display: flex; gap: 15px; font-size: 0.9rem; font-weight: 500; }
::        .badge { padding: 4px 10px; border-radius: 4px; color: white; font-size: 0.75rem; font-weight: bold; white-space: nowrap; }
::
::        #response {
::            background: #1e1e1e; color: #d4d4d4; padding: 1.5rem; border-radius: 8px;
::            min-height: 150px; max-height: 500px; overflow-y: auto;
::            font-family: 'Segoe UI', system-ui, sans-serif; font-size: 0.92rem; line-height: 1.7;
::        }
::        #response p { margin: 0.4em 0; }
::        #response h1, #response h2, #response h3, #response h4 { color: #e8eaed; margin: 0.9em 0 0.3em; }
::        #response h1 { font-size: 1.3em; border-bottom: 1px solid #3c3c3c; padding-bottom: 0.2em; }
::        #response h2 { font-size: 1.15em; }
::        #response h3 { font-size: 1em; }
::        #response code { background: #2d2d2d; padding: 2px 6px; border-radius: 3px; font-family: 'Fira Code', 'Consolas', monospace; font-size: 0.85em; color: #f8f8f2; }
::        #response pre { background: #2d2d2d; padding: 1em; border-radius: 6px; overflow-x: auto; margin: 0.7em 0; }
::        #response pre code { background: none; padding: 0; font-size: 0.85em; }
::        #response ul, #response ol { padding-left: 1.6em; margin: 0.4em 0; }
::        #response li { margin: 0.25em 0; }
::        #response blockquote { border-left: 3px solid #8ab4f8; margin: 0.5em 0; padding: 0.3em 0 0.3em 1em; color: #9aa0a6; }
::        #response table { border-collapse: collapse; width: 100%; margin: 0.7em 0; font-size: 0.88em; }
::        #response th, #response td { border: 1px solid #3c3c3c; padding: 6px 10px; text-align: left; }
::        #response th { background: #2d2d2d; color: #e8eaed; }
::        #response a { color: #8ab4f8; text-decoration: none; }
::        #response a:hover { text-decoration: underline; }
::        #response strong { color: #e8eaed; }
::        #response hr { border: none; border-top: 1px solid #3c3c3c; margin: 1em 0; }
::
::        .reasoning-box {
::            background: #2d2d2d; color: #8ab4f8; padding: 10px 14px; border-radius: 5px;
::            margin-bottom: 10px; font-size: 0.85rem; border-left: 3px solid #8ab4f8; display: none;
::            line-height: 1.6; max-height: 200px; overflow-y: auto;
::        }
::        .reasoning-box p { margin: 0.3em 0; }
::        .reasoning-box code { background: #3c3c3c; padding: 1px 4px; border-radius: 3px; font-size: 0.82em; }
::
::        .btn-main { padding: 12px; background: var(--primary); color: white; border: none; border-radius: 6px; font-weight: bold; cursor: pointer; font-size: 1rem; }
::        .btn-small { padding: 5px 10px; background: #5f6368; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 0.7rem; margin-top: 5px; }
::        .btn-main:hover, .btn-small:hover { filter: brightness(0.9); }
::        .metrics { display: flex; gap: 20px; font-size: 0.75rem; color: var(--text-sec); flex-wrap: wrap; }
::        .status-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; background: #ccc; }
::        .status-online { background: var(--gpu); }
::        .auth-status { font-size: 0.7rem; margin-left: 10px; font-weight: bold; }
::        .btn-copy { padding: 5px 8px; background: #5f6368; color: #fff; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; flex-shrink: 0; line-height: 1; transition: background 0.2s; display: inline-flex; align-items: center; justify-content: center; }
::        .btn-copy:hover { background: #4a4f54; }
::        .btn-copy.copied { background: #2ecc71; }
::        .tester-wrap { margin-top: 8px; border-top: 1px solid #e5e7eb; padding-top: 12px; }
::        .tester-tabs { display: flex; gap: 8px; flex-wrap: wrap; }
::        .tester-tab-btn { padding: 8px 12px; border: 1px solid #cbd5e1; border-radius: 7px; background: #eef2ff; color: #1e3a8a; font-weight: 700; cursor: pointer; }
::        .tester-tab-btn.active { background: #dbeafe; border-color: #93c5fd; }
::        .tester-panel { display: none; margin-top: 10px; }
::        .tester-panel.active { display: block; }
::        .tester-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
::        .btn-row { display: flex; gap: 8px; margin-top: 8px; flex-wrap: wrap; }
::        .btn-alt { padding: 10px 12px; border: none; border-radius: 6px; font-weight: 700; cursor: pointer; color: #fff; background: #374151; }
::        .mono { font-family: 'Fira Code', 'Consolas', monospace; }
::        .tester-response {
::            background: #111827; color: #e5e7eb; border-radius: 8px; border: 1px solid #0f172a;
::            min-height: 130px; max-height: 380px; overflow: auto; padding: 12px; white-space: pre-wrap;
::            font-family: 'Fira Code', 'Consolas', monospace; font-size: 0.84rem;
::        }
::        @media (max-width: 900px) { .tester-grid { grid-template-columns: 1fr; } }
::    </style>
::</head>
::<body>
::<div class="container">
::    <div class="header">
::        <div>
::            <h2 style="margin:0">AI Intelligence Console</h2>
::            <div class="source-bar" style="margin-top:10px">
::                <label><input type="radio" name="source" value="docker" checked> Docker (SSL)</label>
::                <label><input type="radio" name="source" value="native"> Native (SSL)</label>
::                <label><input type="radio" name="source" value="direct"> Direct (11434)</label>
::                <label><input type="radio" name="source" value="custom"> SaaS / Custom</label>
::            </div>
::        </div>
::        <div style="text-align: right">
::            <div id="hwBadge" class="badge" style="background: #95a5a6">Standby</div>
::            <div id="reasoningIndicator" style="font-size: 10px; color: #1a73e8; font-weight: bold; margin-top: 5px; display: none;"><i class="bi bi-cpu"></i> REASONING MODEL</div>
::        </div>
::    </div>
::    <div class="grid-config">
::        <div class="form-group" id="presetGroup" style="display:none">
::            <label>Provider Preset</label>
::            <select id="providerPreset">
::                <option value="">-- Select Provider --</option>
::                <option value="https://api.openai.com/v1">OpenAI</option>
::                <option value="https://api.anthropic.com/v1">Anthropic (Claude)</option>
::                <option value="https://generativelanguage.googleapis.com/v1beta">Google Gemini</option>
::                <option value="https://api.deepseek.com">DeepSeek Cloud</option>
::            </select>
::        </div>
::        <div class="form-group">
::            <label>Endpoint URL</label>
::            <input type="text" id="apiUrl" placeholder="https://localhost:11443">
::        </div>
::        <div class="form-group">
::            <label>API Key / Token
::                <button id="testAuthBtn" class="btn-small">Test Auth</button>
::                <span id="authResult" class="auth-status"></span>
::            </label>
::            <div style="display:flex;gap:5px;align-items:center;">
::                <input type="text" id="apiKey" placeholder="Paste API key here" style="flex:1;font-family:'Fira Code','Consolas',monospace;font-size:0.85rem;letter-spacing:0.03em;">
::                <button class="btn-copy" onclick="copyToClipboard('apiKey',this)" title="Copy API key"><i class="bi bi-clipboard"></i></button>
::            </div>
::        </div>
::        <div class="form-group">
::            <label>Context Length</label>
::            <input type="number" id="contextLen" value="4096" step="1024">
::        </div>
::        <div class="form-group">
::            <label>Model Name</label>
::            <div style="display:flex;gap:5px;align-items:center;">
::                <select id="modelSelect" style="flex:1"><option>Loading...</option></select>
::                <button class="btn-copy" id="modelSelectCopyBtn" onclick="copyToClipboard('modelSelect',this)" title="Copy model name"><i class="bi bi-clipboard"></i></button>
::                <input type="text" id="modelCustom" placeholder="Manual name" style="flex:1;display:none">
::                <button class="btn-copy" id="modelCustomCopyBtn" onclick="copyToClipboard('modelCustom',this)" title="Copy model name" style="display:none"><i class="bi bi-clipboard"></i></button>
::            </div>
::        </div>
::        <div class="form-group" style="flex-direction: row; align-items: center; gap: 10px;">
::            <label><input type="checkbox" id="enableReasoning"> Enable Reasoning Mode</label>
::        </div>
::    </div>
::    <textarea id="promptInput" rows="4" placeholder="Type your message here..."></textarea>
::    <button id="sendBtn" class="btn-main">Execute Inference</button>
::    <div class="metrics">
::        <span>Status: <span class="status-dot" id="statusDot"></span> <span id="statusText">Ready</span></span>
::        <span>Latency: <span id="mTotal">-</span></span>
::        <span id="mVram">Memory: -</span>
::    </div>
::    <div id="reasoningOutput" class="reasoning-box"></div>
::    <div id="response"><em style="color:#666">Waiting for query...</em></div>
::
::    <div class="tester-wrap">
::        <h3 style="margin:0 0 6px 0">API Testing Tabs</h3>
::        <div class="tester-tabs">
::            <button class="tester-tab-btn active" data-tester-tab="endpointPanel">Endpoint Tester</button>
::            <button class="tester-tab-btn" data-tester-tab="jsonPanel">JSON Request Tester</button>
::        </div>
::
::        <div class="tester-panel active" id="endpointPanel">
::            <div class="tester-grid">
::                <div class="form-group">
::                    <label>Quick Endpoint</label>
::                    <select id="endpointSelect">
::                        <option value="/v1/models|GET">/v1/models (GET)</option>
::                        <option value="/api/tags|GET">/api/tags (GET)</option>
::                        <option value="/api/ps|GET">/api/ps (GET)</option>
::                        <option value="/api/version|GET">/api/version (GET)</option>
::                        <option value="/api/show|POST">/api/show (POST)</option>
::                        <option value="/v1/chat/completions|POST">/v1/chat/completions (POST)</option>
::                    </select>
::                </div>
::                <div class="form-group">
::                    <label>HTTP Method</label>
::                    <select id="endpointMethod">
::                        <option value="GET">GET</option>
::                        <option value="POST">POST</option>
::                        <option value="OPTIONS">OPTIONS</option>
::                    </select>
::                </div>
::            </div>
::            <div class="tester-grid">
::                <div class="form-group">
::                    <label>Path Override (optional)</label>
::                    <input type="text" id="endpointPathOverride" placeholder="/api/tags">
::                </div>
::                <div class="form-group">
::                    <label>Origin Header for CORS test (optional)</label>
::                    <input type="text" id="corsOriginInput" placeholder="https://myapp.local">
::                </div>
::            </div>
::            <div class="form-group">
::                <label>Body JSON (used for POST/OPTIONS when provided)</label>
::                <textarea id="endpointBodyInput" class="mono" rows="7"></textarea>
::            </div>
::            <div class="btn-row">
::                <button class="btn-main" id="runEndpointBtn">Run Endpoint Request</button>
::                <button class="btn-alt" id="copyEndpointCurlBtn">Copy curl</button>
::            </div>
::            <div class="form-group">
::                <label>Generated curl</label>
::                <textarea id="endpointCurlOutput" class="mono" rows="4" readonly></textarea>
::            </div>
::            <div class="form-group">
::                <label>Endpoint Response</label>
::                <div id="endpointResponse" class="tester-response">Waiting for request...</div>
::            </div>
::        </div>
::
::        <div class="tester-panel" id="jsonPanel">
::            <div class="form-group">
::                <label>JSON Request Template</label>
::                <select id="jsonTemplateSelect">
::                    <option value="models">Template: /v1/models</option>
::                    <option value="tags">Template: /api/tags</option>
::                    <option value="ps">Template: /api/ps</option>
::                    <option value="show">Template: /api/show</option>
::                    <option value="completions">Template: /v1/chat/completions</option>
::                </select>
::            </div>
::            <div class="form-group">
::                <label>Editable JSON Request</label>
::                <textarea id="jsonRequestInput" class="mono" rows="14"></textarea>
::            </div>
::            <div class="btn-row">
::                <button class="btn-main" id="runJsonRequestBtn">Run JSON Request</button>
::                <button class="btn-alt" id="copyJsonCurlBtn">Copy curl</button>
::            </div>
::            <div class="form-group">
::                <label>Generated curl</label>
::                <textarea id="jsonCurlOutput" class="mono" rows="4" readonly></textarea>
::            </div>
::            <div class="form-group">
::                <label>JSON Tester Response</label>
::                <div id="jsonResponse" class="tester-response">Waiting for request...</div>
::            </div>
::        </div>
::    </div>
::</div>
::
::<script>
::    marked.use({ gfm: true, breaks: true });
::
::    function renderMd(text) {
::        if (!text) return '';
::        return marked.parse(text);
::    }
::
::    function applyHighlight(container) {
::        container.querySelectorAll('pre code').forEach(el => hljs.highlightElement(el));
::    }
::
::    const STORAGE = { CONFIG: 'ai_console_config', LAST_PROMPT: 'ai_console_prompt' };
::    const API_TESTER_EXAMPLES = {
::        models: { path: '/v1/models', method: 'GET' },
::        tags: { path: '/api/tags', method: 'GET' },
::        ps: { path: '/api/ps', method: 'GET' },
::        show: { path: '/api/show', method: 'POST', body: { model: 'llama3.2' } },
::        completions: {
::            path: '/v1/chat/completions',
::            method: 'POST',
::            body: {
::                model: 'llama3.2',
::                messages: [{ role: 'user', content: 'Hello from API tester' }],
::                max_tokens: 256
::            }
::        }
::    };
::    const els = {
::        radios: document.getElementsByName('source'),
::        apiUrl: document.getElementById('apiUrl'),
::        apiKey: document.getElementById('apiKey'),
::        contextLen: document.getElementById('contextLen'),
::        modelSelect: document.getElementById('modelSelect'),
::        modelCustom: document.getElementById('modelCustom'),
::        presetGroup: document.getElementById('presetGroup'),
::        providerPreset: document.getElementById('providerPreset'),
::        prompt: document.getElementById('promptInput'),
::        btn: document.getElementById('sendBtn'),
::        testAuthBtn: document.getElementById('testAuthBtn'),
::        authResult: document.getElementById('authResult'),
::        resp: document.getElementById('response'),
::        reasoningBox: document.getElementById('reasoningOutput'),
::        reasoningInd: document.getElementById('reasoningIndicator'),
::        enableReasoning: document.getElementById('enableReasoning'),
::        badge: document.getElementById('hwBadge'),
::        mTotal: document.getElementById('mTotal'),
::        mVram: document.getElementById('mVram'),
::        statusText: document.getElementById('statusText'),
::        statusDot: document.getElementById('statusDot'),
::        testerTabs: document.querySelectorAll('.tester-tab-btn'),
::        testerPanels: document.querySelectorAll('.tester-panel'),
::        endpointSelect: document.getElementById('endpointSelect'),
::        endpointMethod: document.getElementById('endpointMethod'),
::        endpointPathOverride: document.getElementById('endpointPathOverride'),
::        corsOriginInput: document.getElementById('corsOriginInput'),
::        endpointBodyInput: document.getElementById('endpointBodyInput'),
::        runEndpointBtn: document.getElementById('runEndpointBtn'),
::        copyEndpointCurlBtn: document.getElementById('copyEndpointCurlBtn'),
::        endpointCurlOutput: document.getElementById('endpointCurlOutput'),
::        endpointResponse: document.getElementById('endpointResponse'),
::        jsonTemplateSelect: document.getElementById('jsonTemplateSelect'),
::        jsonRequestInput: document.getElementById('jsonRequestInput'),
::        runJsonRequestBtn: document.getElementById('runJsonRequestBtn'),
::        copyJsonCurlBtn: document.getElementById('copyJsonCurlBtn'),
::        jsonCurlOutput: document.getElementById('jsonCurlOutput'),
::        jsonResponse: document.getElementById('jsonResponse')
::    };
::
::    function toPrettyJson(value) {
::        return JSON.stringify(value, null, 2);
::    }
::
::    function shellEscapeSingle(value) {
::        return `'${String(value).replace(/'/g, `'\\''`)}'`;
::    }
::
::    function buildCurl(url, method, headers, body) {
::        const cmd = ['curl -k -sS'];
::        cmd.push(`-X ${method}`);
::        Object.entries(headers).forEach(([k, v]) => cmd.push(`-H ${shellEscapeSingle(`${k}: ${v}`)}`));
::        if (body !== undefined && body !== null && method !== 'GET') {
::            const bodyText = typeof body === 'string' ? body : JSON.stringify(body);
::            cmd.push(`--data ${shellEscapeSingle(bodyText)}`);
::        }
::        cmd.push(shellEscapeSingle(url));
::        return cmd.join(' ');
::    }
::
::    function renderApiResponse(container, payload) {
::        if (typeof payload === 'string') {
::            container.textContent = payload;
::            return;
::        }
::        container.textContent = toPrettyJson(payload);
::    }
::
::    async function runApiRequest(path, method, body, origin, responseContainer, curlContainer) {
::        const url = `${els.apiUrl.value}${path}`;
::        const headers = {};
::        if (els.apiKey.value) headers.Authorization = `Bearer ${els.apiKey.value}`;
::        if (origin) headers.Origin = origin;
::        if (body !== undefined && body !== null) headers['Content-Type'] = 'application/json';
::
::        const curlCmd = buildCurl(url, method, headers, body);
::        if (curlContainer) curlContainer.value = curlCmd;
::        responseContainer.textContent = 'Waiting for response...';
::
::        const options = { method, headers };
::        if (body !== undefined && body !== null && method !== 'GET' && method !== 'OPTIONS') {
::            options.body = typeof body === 'string' ? body : JSON.stringify(body);
::        }
::
::        try {
::            const response = await fetch(url, options);
::            const text = await response.text();
::            let data;
::            try { data = JSON.parse(text); } catch { data = text; }
::            renderApiResponse(responseContainer, {
::                status: response.status,
::                status_text: response.statusText,
::                path,
::                method,
::                data
::            });
::        } catch (error) {
::            renderApiResponse(responseContainer, { error: error.message, path, method });
::        }
::    }
::
::    function applyEndpointPreset() {
::        const [path, forcedMethod] = els.endpointSelect.value.split('|');
::        if (forcedMethod === 'POST') els.endpointMethod.value = 'POST';
::        if (path === '/api/show') {
::            els.endpointBodyInput.value = toPrettyJson(API_TESTER_EXAMPLES.show.body);
::        } else if (path === '/v1/chat/completions') {
::            const model = els.modelSelect.value || 'llama3.2';
::            const sample = { ...API_TESTER_EXAMPLES.completions.body, model };
::            els.endpointBodyInput.value = toPrettyJson(sample);
::        } else {
::            els.endpointBodyInput.value = '';
::        }
::    }
::
::    function loadJsonTemplate() {
::        const key = els.jsonTemplateSelect.value;
::        const template = API_TESTER_EXAMPLES[key];
::        const model = els.modelSelect.value || 'llama3.2';
::        const payload = { path: template.path, method: template.method };
::        if (template.body) {
::            payload.body = JSON.parse(JSON.stringify(template.body));
::            if (payload.body.model) payload.body.model = model;
::        }
::        els.jsonRequestInput.value = toPrettyJson(payload);
::    }
::
::    function saveConfig() {
::        localStorage.setItem(STORAGE.CONFIG, JSON.stringify({
::            source: Array.from(els.radios).find(r => r.checked).value,
::            url: els.apiUrl.value, key: els.apiKey.value,
::            ctx: els.contextLen.value, reasoning: els.enableReasoning.checked
::        }));
::    }
::
::    function loadConfig() {
::        const serverKey = window.__OLLAMA_API_KEY__ || '';
::        const data = localStorage.getItem(STORAGE.CONFIG);
::        if (!data) {
::            if (serverKey) els.apiKey.value = serverKey;
::            handleSourceChange();
::            return;
::        }
::        const c = JSON.parse(data);
::        const r = Array.from(els.radios).find(rad => rad.value === c.source);
::        if (r) r.checked = true;
::        els.apiUrl.value = c.url || '';
::        const source = c.source || 'docker';
::        const useServerKey = source === 'docker' || source === 'native' || source === 'direct';
::        els.apiKey.value = useServerKey ? serverKey : (c.key || '');
::        els.contextLen.value = c.ctx || 4096;
::        els.enableReasoning.checked = c.reasoning || false;
::        handleSourceChange();
::    }
::
::    function handleSourceChange() {
::        const source = Array.from(els.radios).find(r => r.checked).value;
::        const host = window.location.hostname;
::        const isCustom = source === 'custom';
::        els.presetGroup.style.display = isCustom ? 'block' : 'none';
::        els.modelCustom.style.display = isCustom ? 'block' : 'none';
::        document.getElementById('modelCustomCopyBtn').style.display = isCustom ? 'inline-flex' : 'none';
::        els.modelSelect.style.display = isCustom ? 'none' : 'block';
::        document.getElementById('modelSelectCopyBtn').style.display = isCustom ? 'none' : 'inline-flex';
::        if (source === 'docker') els.apiUrl.value = `https://${host}:11443`;
::        else if (source === 'native') els.apiUrl.value = `https://${host}:11444`;
::        else if (source === 'direct') els.apiUrl.value = `http://${host}:11434`;
::        loadModels();
::        saveConfig();
::    }
::
::    function copyToClipboard(id, btn) {
::        const el = document.getElementById(id);
::        const text = el.value;
::        if (!text) return;
::        const origHTML = btn.innerHTML;
::        const finish = () => {
::            btn.innerHTML = '<i class="bi bi-check-lg"></i>';
::            btn.classList.add('copied');
::            setTimeout(() => { btn.innerHTML = origHTML; btn.classList.remove('copied'); }, 1500);
::        };
::        navigator.clipboard.writeText(text).then(finish).catch(() => {
::            const ta = document.createElement('textarea');
::            ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
::            document.body.appendChild(ta); ta.select(); document.execCommand('copy');
::            document.body.removeChild(ta); finish();
::        });
::    }
::
::    async function testAuthentication() {
::        const url = els.apiUrl.value;
::        const key = els.apiKey.value;
::        if (!key) { els.authResult.innerText = 'Enter a key first'; els.authResult.style.color = 'orange'; return; }
::        els.authResult.innerText = 'Testing...';
::        els.authResult.style.color = 'var(--text-sec)';
::        try {
::            const res = await fetch(`${url}/v1/models`, { headers: { 'Authorization': `Bearer ${key}` } });
::            if (res.ok) {
::                els.authResult.innerText = '[OK] Key valid';
::                els.authResult.style.color = 'var(--gpu)';
::            } else {
::                const data = await res.json().catch(() => ({}));
::                els.authResult.innerText = `[ERR] ${res.status}: ${data.error?.code || 'Unauthorized'}`;
::                els.authResult.style.color = 'red';
::            }
::        } catch (e) {
::            els.authResult.innerText = 'Connection failed';
::            els.authResult.style.color = 'red';
::        }
::    }
::
::    async function loadModels() {
::        const source = Array.from(els.radios).find(r => r.checked).value;
::        if (source === 'custom') return;
::        try {
::            const res = await fetch(`${els.apiUrl.value}/api/tags`);
::            const data = await res.json();
::            els.modelSelect.innerHTML = data.models.map(m => `<option value="${m.name}">${m.name}</option>`).join('');
::            els.statusDot.className = 'status-dot status-online';
::            els.statusText.innerText = 'Online';
::            checkReasoningCapability();
::        } catch (e) {
::            els.statusDot.className = 'status-dot';
::            els.statusText.innerText = 'Offline / Error';
::        }
::    }
::
::    function checkReasoningCapability() {
::        const name = els.modelSelect.value.toLowerCase();
::        const isReasoning = name.includes('r1') || name.includes('o1') || name.includes('reason');
::        els.reasoningInd.style.display = isReasoning ? 'block' : 'none';
::    }
::
::    async function execute() {
::        const source = Array.from(els.radios).find(r => r.checked).value;
::        const url = els.apiUrl.value;
::        const model = source === 'custom' ? els.modelCustom.value : els.modelSelect.value;
::        const prompt = els.prompt.value;
::        if (!prompt || !model) return;
::        localStorage.setItem(STORAGE.LAST_PROMPT, prompt);
::        els.btn.disabled = true;
::        els.resp.innerHTML = '<em style="color:#666">Thinking...</em>';
::        els.reasoningBox.style.display = 'none';
::        const start = performance.now();
::        try {
::            const res = await fetch(`${url}/v1/chat/completions`, {
::                method: 'POST',
::                headers: {
::                    'Content-Type': 'application/json',
::                    'Authorization': els.apiKey.value ? `Bearer ${els.apiKey.value}` : 'Bearer ollama'
::                },
::                body: JSON.stringify({
::                    model,
::                    messages: [{ role: 'user', content: prompt }],
::                    max_tokens: parseInt(els.contextLen.value)
::                })
::            });
::            const data = await res.json();
::            const content = data.choices[0].message.content;
::
::            if (content.includes('<think>')) {
::                const parts = content.split('</think>');
::                const thinking = parts[0].replace('<think>', '').trim();
::                const answer = parts[1].trim();
::                els.reasoningBox.innerHTML = renderMd(thinking);
::                els.reasoningBox.style.display = 'block';
::                applyHighlight(els.reasoningBox);
::                els.resp.innerHTML = renderMd(answer);
::            } else {
::                els.resp.innerHTML = renderMd(content);
::            }
::
::            applyHighlight(els.resp);
::            els.mTotal.innerText = `${((performance.now() - start) / 1000).toFixed(2)}s`;
::            updateHardwareMetrics();
::        } catch (e) {
::            els.resp.innerHTML = `<span style="color:#e74c3c">Error: ${e.message}</span>`;
::        } finally {
::            els.btn.disabled = false;
::        }
::    }
::
::    async function updateHardwareMetrics() {
::        const source = Array.from(els.radios).find(r => r.checked).value;
::        if (source === 'custom') return;
::        try {
::            const res = await fetch(`${els.apiUrl.value}/api/ps`);
::            const data = await res.json();
::            const model = data.models?.find(m => els.modelSelect.value.startsWith(m.name));
::            if (model) {
::                const gpuBytes = model.size_vram || 0;
::                const cpuBytes = (model.size || 0) - gpuBytes;
::                const gpuPct = model.size > 0 ? Math.round((gpuBytes / model.size) * 100) : 0;
::                const gpuGB = (gpuBytes / 1e9).toFixed(2);
::                const cpuGB = (cpuBytes / 1e9).toFixed(2);
::                if (gpuPct === 100) {
::                    els.badge.textContent = `GPU | ${gpuGB} GB`;
::                    els.badge.style.background = '#2ecc71';
::                    els.mVram.textContent = `VRAM: ${gpuGB} GB`;
::                } else if (gpuPct > 0) {
::                    els.badge.textContent = 'HYBRID';
::                    els.badge.style.background = '#9b59b6';
::                    els.mVram.textContent = `VRAM: ${gpuGB} GB  RAM: ${cpuGB} GB`;
::                } else {
::                    els.badge.textContent = `CPU | ${cpuGB} GB`;
::                    els.badge.style.background = '#f39c12';
::                    els.mVram.textContent = `RAM: ${cpuGB} GB`;
::                }
::            } else {
::                els.badge.textContent = 'Standby';
::                els.badge.style.background = '#95a5a6';
::                els.mVram.textContent = 'Memory: -';
::            }
::        } catch (e) {}
::    }
::
::    els.radios.forEach(r => r.addEventListener('change', handleSourceChange));
::    els.providerPreset.addEventListener('change', () => { els.apiUrl.value = els.providerPreset.value; saveConfig(); });
::    els.modelSelect.addEventListener('change', checkReasoningCapability);
::    els.endpointSelect.addEventListener('change', applyEndpointPreset);
::    els.jsonTemplateSelect.addEventListener('change', loadJsonTemplate);
::    els.btn.addEventListener('click', execute);
::    els.testAuthBtn.addEventListener('click', testAuthentication);
::
::    els.testerTabs.forEach(tab => {
::        tab.addEventListener('click', () => {
::            els.testerTabs.forEach(t => t.classList.remove('active'));
::            els.testerPanels.forEach(p => p.classList.remove('active'));
::            tab.classList.add('active');
::            const panel = document.getElementById(tab.dataset.testerTab);
::            panel.classList.add('active');
::            if (tab.dataset.testerTab === 'endpointPanel' && !els.endpointResponse.textContent.trim()) {
::                els.endpointResponse.textContent = 'Waiting for request...';
::            }
::            if (tab.dataset.testerTab === 'jsonPanel' && !els.jsonResponse.textContent.trim()) {
::                els.jsonResponse.textContent = 'Waiting for request...';
::            }
::        });
::    });
::
::    els.runEndpointBtn.addEventListener('click', async () => {
::        const [selectedPath, forcedMethod] = els.endpointSelect.value.split('|');
::        const path = (els.endpointPathOverride.value || '').trim() || selectedPath;
::        let method = els.endpointMethod.value;
::        if (forcedMethod === 'POST') method = 'POST';
::        let body;
::        const raw = els.endpointBodyInput.value.trim();
::        if (raw) {
::            try { body = JSON.parse(raw); }
::            catch { els.endpointResponse.textContent = 'Invalid JSON body.'; return; }
::        }
::        await runApiRequest(path, method, body, (els.corsOriginInput.value || '').trim(), els.endpointResponse, els.endpointCurlOutput);
::    });
::
::    els.copyEndpointCurlBtn.addEventListener('click', () => navigator.clipboard.writeText(els.endpointCurlOutput.value || ''));
::
::    els.runJsonRequestBtn.addEventListener('click', async () => {
::        let request;
::        try { request = JSON.parse(els.jsonRequestInput.value); }
::        catch { els.jsonResponse.textContent = 'Invalid JSON request template.'; return; }
::        const path = request.path || '/api/tags';
::        let method = (request.method || 'GET').toUpperCase();
::        if (path === '/v1/chat/completions' || path === '/api/show') method = 'POST';
::        await runApiRequest(path, method, request.body, (request.origin || '').trim(), els.jsonResponse, els.jsonCurlOutput);
::    });
::
::    els.copyJsonCurlBtn.addEventListener('click', () => navigator.clipboard.writeText(els.jsonCurlOutput.value || ''));
::
::    window.onload = () => {
::        loadConfig();
::        els.prompt.value = localStorage.getItem(STORAGE.LAST_PROMPT) || '';
::        applyEndpointPreset();
::        loadJsonTemplate();
::        els.endpointResponse.textContent = 'Waiting for request...';
::        els.jsonResponse.textContent = 'Waiting for request...';
::        setInterval(updateHardwareMetrics, 5000);
::    };
::</script>
::</body>
::</html>
::'@
::}
::#endregion
::__PS1_INIT_END__
