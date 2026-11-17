param([switch]$Lan, [int]$Port = 8787)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimePath = Join-Path $projectRoot 'runtime'
$pidPath = Join-Path $runtimePath 'backend-process.json'
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
if (Test-Path -LiteralPath $pidPath) {
    $existing = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json
    $process = Get-Process -Id $existing.pid -ErrorAction SilentlyContinue
    if ($process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $existing.startTime) {
        Write-Host "PocketWorld backend is running (PID $($existing.pid)); $($existing.healthUrl)"
        Write-Host 'Use scripts\Stop-Backend.ps1 before changing the port or LAN mode.'
        exit 0
    }
}
$nodePath = (Get-Command node -ErrorAction Stop).Source
$serverPath = Join-Path $projectRoot 'server\index.mjs'
if (-not (Test-Path -LiteralPath $serverPath)) { throw 'server/index.mjs is not present.' }
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'server\node_modules\busboy\package.json'))) {
    throw 'Install locked server dependencies first: npm.cmd --prefix server ci'
}
$bindAddress = if ($Lan) { '0.0.0.0' } else { '127.0.0.1' }
$previousHost = $env:HOST
$previousPort = $env:PORT
try {
    $env:HOST = $bindAddress
    $env:PORT = "$Port"
    $process = Start-Process -FilePath $nodePath -ArgumentList @('"' + $serverPath + '"') -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runtimePath 'backend.stdout.log') -RedirectStandardError (Join-Path $runtimePath 'backend.stderr.log') -PassThru
} finally {
    $env:HOST = $previousHost
    $env:PORT = $previousPort
}
$healthUrl = "http://127.0.0.1:$Port/health"
$healthy = $false
for ($attempt=0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Milliseconds 250
    if ($process.HasExited) { break }
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
        if ($health.ok -eq $true) { $healthy = $true; break }
    } catch { }
}
if (-not $healthy) {
    if (-not $process.HasExited) { $process.Kill() }
    throw "Backend failed to start. Inspect $runtimePath\backend.stderr.log"
}
@{pid=$process.Id;startTime=$process.StartTime.ToUniversalTime().ToString('o');healthUrl=$healthUrl;bind=$bindAddress;port=$Port} | ConvertTo-Json | Set-Content -LiteralPath $pidPath -Encoding utf8
Write-Host "PocketWorld backend started: $healthUrl (PID $($process.Id))"
if ($Lan) {
    Write-Host 'iPhone WeChat development previews on the same trusted Wi-Fi can use one of these addresses (phone debug mode and a Windows firewall rule may still be needed):'
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { Write-Host "  http://$($_.IPAddress):$Port" }
} else {
    Write-Host 'Loopback-only. To test a phone later: stop, then Start-Backend.ps1 -Lan.'
}

