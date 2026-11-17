param([string]$Distribution = 'Ubuntu-24.04')

$ErrorActionPreference = 'Stop'
# Start-Process joins native arguments on Windows. Every variable passed to its
# ArgumentList is restricted to a whitespace-free distro identifier.
if ($Distribution -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw 'Distribution must contain only letters, digits, dots, underscores and hyphens.'
}
$wslExecutable = (Get-Command wsl.exe -ErrorAction Stop).Source
$keepaliveLock = '/home/pocketworld/PocketWorld/work/backend-keepalive.lock'
$lockConflictCode = 75

function Test-BackendKeepalive {
    & $wslExecutable --distribution $Distribution --user pocketworld --exec /usr/bin/flock -n -E $lockConflictCode $keepaliveLock /usr/bin/true | Out-Null
    $probeExit = $LASTEXITCODE
    if ($probeExit -eq $lockConflictCode) { return $true }
    if ($probeExit -eq 0) { return $false }
    throw ('Could not inspect the WSL backend keepalive lock; exit code ' + $probeExit)
}

# systemd services do not keep a WSL distro alive after its foreground Windows
# clients exit. Hold one explicit WSL command open while this test server is used.
# flock makes concurrent/repeated invocations share one keeper; a losing process
# exits with 75 instead of leaving a second sleep process behind.
if (-not (Test-BackendKeepalive)) {
    $keeper = Start-Process -FilePath $wslExecutable -ArgumentList @(
        '--distribution', $Distribution, '--user', 'pocketworld', '--exec',
        '/usr/bin/flock', '-n', '-E', '75', $keepaliveLock, '/bin/sleep', 'infinity'
    ) -WindowStyle Hidden -PassThru
}
$keeperReady = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    if (Test-BackendKeepalive) { $keeperReady = $true; break }
    Start-Sleep -Milliseconds 250
}
if (-not $keeperReady) { throw 'The hidden WSL keepalive did not acquire its lock.' }

& wsl.exe --distribution $Distribution --user root --exec systemctl start pocketworld-backend.service
if ($LASTEXITCODE -ne 0) { throw 'Could not start pocketworld-backend.service in WSL.' }
& wsl.exe --distribution $Distribution --user root --exec systemctl is-active pocketworld-backend.service
if ($LASTEXITCODE -ne 0) { throw 'The backend service is not active.' }

$ready = $false
for ($attempt = 0; $attempt -lt 10; $attempt++) {
    $response = & wsl.exe --distribution $Distribution --user pocketworld --exec curl --fail --silent --connect-timeout 1 --max-time 2 http://127.0.0.1:8787/health 2>$null
    if ($LASTEXITCODE -eq 0) {
        try { $ready = (($response -join "`n") | ConvertFrom-Json).ok -eq $true } catch { $ready = $false }
        if ($ready) { break }
    }
    Start-Sleep -Milliseconds 500
}
if (-not $ready) { throw 'Service started but VM health did not become ready; inspect journalctl -u pocketworld-backend.service in WSL.' }
if (-not (Test-BackendKeepalive)) { throw 'The WSL keepalive stopped before the backend became ready.' }
Write-Output 'VM backend ready at http://127.0.0.1:8787 inside Ubuntu; a hidden WSL process keeps the test VM running.'
Write-Output ('After a Windows restart, run this script again. To stop the dedicated test VM: wsl --terminate ' + $Distribution)
Write-Output 'The FF GPU worker is not started by this command.'
