param(
    [string]$Distribution = 'Ubuntu-24.04',
    [string]$LinuxProject = '/home/pocketworld/PocketWorld',
    [string]$HubOrigin = 'http://9.135.79.113:8000',
    [switch]$SkipServerTests
)

$ErrorActionPreference = 'Stop'
Get-Command wsl.exe -ErrorAction Stop | Out-Null

function Invoke-PocketWSL {
    param([string[]]$LinuxArgs)
    $result = & wsl.exe --distribution $Distribution --user pocketworld --exec @LinuxArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ('WSL command failed ({0}): {1}' -f $code, ($result -join "`n")) }
    return $result
}

# Invoking a command starts this registered distro if it was stopped.
Invoke-PocketWSL -LinuxArgs @('true') | Out-Null
$version = (Invoke-PocketWSL -LinuxArgs @('node', '--version') | Out-String).Trim()
if ($version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 24) {
    throw ('Node.js 24 or newer is required inside WSL; found: ' + $version)
}
Write-Output ('WSL distro: ' + $Distribution + '; Node: ' + $version)
$ffmpeg = Invoke-PocketWSL -LinuxArgs @('ffmpeg', '-version')
Write-Output ($ffmpeg | Select-Object -First 1)
Invoke-PocketWSL -LinuxArgs @('test', '-f', ($LinuxProject + '/server/package.json')) | Out-Null

if (-not $SkipServerTests) {
    Invoke-PocketWSL -LinuxArgs @('npm', '--prefix', ($LinuxProject + '/server'), 'test') | Write-Output
}

$healthText = Invoke-PocketWSL -LinuxArgs @('curl', '--fail', '--silent', '--show-error',
    '--connect-timeout', '5', '--max-time', '10', 'http://127.0.0.1:8787/health')
$health = ($healthText -join "`n") | ConvertFrom-Json
if ($health.ok -ne $true) { throw 'The VM backend did not return ok:true.' }
Write-Output ('VM backend health: ok; version=' + $health.version)

$capabilitiesURL = $HubOrigin.TrimEnd('/') + '/api/3dgs/quick-reconstruct/capabilities'
$capabilitiesText = Invoke-PocketWSL -LinuxArgs @('curl', '--fail', '--silent', '--show-error',
    '--connect-timeout', '5', '--max-time', '15', $capabilitiesURL)
$capabilities = ($capabilitiesText -join "`n") | ConvertFrom-Json
if ($capabilities.engine -ne 'worldmirror2' -or $capabilities.available -ne $true) {
    throw 'Hub is reachable but does not report an available WorldMirror2 engine.'
}
Write-Output 'Hub capabilities: available worldmirror2. This does not prove GPU capacity or a successful reconstruction.'
Write-Output 'VM checks completed. No images were uploaded and no GPU task was submitted.'
