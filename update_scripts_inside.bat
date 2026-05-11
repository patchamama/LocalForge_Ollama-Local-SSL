@echo off
setlocal
set "BASEDIR=%~dp0"
if "%BASEDIR:~-1%"=="\" set "BASEDIR=%BASEDIR:~0,-1%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$base = '%BASEDIR%'; ^
$shFile = Join-Path $base 'deploy-ollama-local.sh'; ^
$batFile = Join-Path $base 'deploy-ollama-local.bat'; ^
function Replace-ShHeredoc([string]$marker,[string]$src){ ^
  $content = Get-Content -LiteralPath $shFile -Raw; ^
  $srcText = Get-Content -LiteralPath $src -Raw; ^
  $pattern = '(?ms)(<< ''{0}''\r?\n)(.*?)(\r?\n{0})' -f [regex]::Escape($marker); ^
  $new = [regex]::Replace($content,$pattern, { param($m) $m.Groups[1].Value + $srcText.TrimEnd("`r","`n") + $m.Groups[3].Value }, 1); ^
  if($new -eq $content){ throw 'Marker not found: ' + $marker } ^
  Set-Content -LiteralPath $shFile -Value $new -Encoding UTF8; ^
} ^
function Prefix-DoubleColon([string]$s){ (($s -split "`r?`n") | ForEach-Object { '::' + $_ }) -join "`r`n" } ^
function Replace-BatRegion([string]$region,[string]$src){ ^
  $content = Get-Content -LiteralPath $batFile -Raw; ^
  $srcText = Prefix-DoubleColon((Get-Content -LiteralPath $src -Raw).TrimEnd("`r","`n")); ^
  $pattern = '(?ms)(::#region ' + [regex]::Escape($region) + '.*?::\s*Set-Content -Path \$f -Encoding UTF8 -Value @''\r?\n)(.*?)(\r?\n::''@.*?::#endregion)'; ^
  $new = [regex]::Replace($content,$pattern, { param($m) $m.Groups[1].Value + $srcText + $m.Groups[3].Value }, 1); ^
  if($new -eq $content){ throw 'Region not found: ' + $region } ^
  Set-Content -LiteralPath $batFile -Value $new -Encoding UTF8; ^
} ^
Replace-ShHeredoc 'CADDYFILE_EOF' (Join-Path $base 'config/Caddyfile'); ^
Replace-ShHeredoc 'HYBRID_EOF' (Join-Path $base 'config/docker-compose.hybrid.yml'); ^
Replace-ShHeredoc 'CADDYONLY_EOF' (Join-Path $base 'config/docker-compose.caddy-only.yml'); ^
Replace-ShHeredoc 'NVIDIA_EOF' (Join-Path $base 'config/docker-compose.nvidia.yml'); ^
Replace-ShHeredoc 'AMD_EOF' (Join-Path $base 'config/docker-compose.amd.yml'); ^
Replace-ShHeredoc 'CPU_EOF' (Join-Path $base 'config/docker-compose.cpu.yml'); ^
Replace-ShHeredoc 'HTML_EOF' (Join-Path $base 'ai-console.html'); ^
Replace-BatRegion 'Caddyfile' (Join-Path $base 'config/Caddyfile'); ^
Replace-BatRegion 'docker-compose.hybrid.yml' (Join-Path $base 'config/docker-compose.hybrid.yml'); ^
Replace-BatRegion 'docker-compose.caddy-only.yml' (Join-Path $base 'config/docker-compose.caddy-only.yml'); ^
Replace-BatRegion 'detect-gpu.ps1' (Join-Path $base 'tools/detect-gpu.ps1'); ^
Replace-BatRegion 'ai-console.html' (Join-Path $base 'ai-console.html'); ^
Write-Host '[OK] Embedded inside blocks updated.'"

if %errorlevel% neq 0 (
  echo [ERROR] update_scripts_inside.bat failed.
  exit /b 1
)

echo [OK] Finished.
exit /b 0
