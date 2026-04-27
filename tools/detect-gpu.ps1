function Get-GPUDetection {
    $gpus = Get-CimInstance Win32_VideoController
    $foundNvidia = $false
    $foundAMD = $false

    foreach ($gpu in $gpus) {
        $name = $gpu.Name.ToLower()
        if ($name -like "*nvidia*") { $foundNvidia = $true }
        if ($name -like "*amd*" -or $name -like "*radeon*") { $foundAMD = $true }
    }

    if ($foundNvidia) { 
        Write-Host "Nvidia GPU detected. Supported in Docker!" -ForegroundColor Green
        return "nvidia" 
    }
    if ($foundAMD) { 
        Write-Host "AMD GPU detected, but Docker on Windows requires advanced WSL2 config for ROCm." -ForegroundColor Yellow
        Write-Host "Falling back to CPU mode for stability." -ForegroundColor Gray
        return "cpu" 
    }
    return "cpu"
}

$type = Get-GPUDetection
Write-Host "Detected GPU Type: $type" -ForegroundColor Cyan

$sourceFile = "config\docker-compose.$type.yml"
if (Test-Path $sourceFile) {
    Copy-Item $sourceFile "docker-compose.yml" -Force
    Write-Host "Success: docker-compose.yml updated for $type" -ForegroundColor Green
} else {
    Write-Host "[WARN] Template $sourceFile not found. Using hybrid as fallback." -ForegroundColor Yellow
    $fallback = "config\docker-compose.hybrid.yml"
    if (Test-Path $fallback) {
        Copy-Item $fallback "docker-compose.yml" -Force
        Write-Host "docker-compose.yml set for hybrid (fallback)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] No fallback template found. docker-compose.yml unchanged." -ForegroundColor Yellow
    }
}
