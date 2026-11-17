$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pidPath = Join-Path $projectRoot 'runtime\backend-process.json'
if (-not (Test-Path -LiteralPath $pidPath)) { Write-Host 'No managed PocketWorld backend process.'; exit 0 }
$record = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json
$process = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
if ($process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $record.startTime) {
    $command = (Get-CimInstance Win32_Process -Filter "ProcessId = $($record.pid)").CommandLine
    $expected = Join-Path $projectRoot 'server\index.mjs'
    if (-not $command.Contains($expected)) { throw 'PID does not belong to this project; refusing to stop it.' }
    Stop-Process -Id $record.pid
    Write-Host "Stopped PocketWorld backend (PID $($record.pid))."
} else { Write-Host 'Recorded backend has already stopped.' }
Remove-Item -LiteralPath $pidPath

