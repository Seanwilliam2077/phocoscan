param(
  [ValidateSet('Open','Login','Status','Preview')][string]$Action='Open',
  [string]$AppId='',
  [string]$DevToolsPath='D:\WeChatDevTools'
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$cliPath=Join-Path $DevToolsPath 'cli.bat'
if(-not (Test-Path -LiteralPath $cliPath)) {
  throw "WeChat DevTools not found at $DevToolsPath. Install the official Windows tool, or pass -DevToolsPath."
}
if($AppId) {
  & node (Join-Path $PSScriptRoot 'Set-WeChatAppId.mjs') $AppId
  if($LASTEXITCODE -ne 0) { throw 'Invalid AppID.' }
}
$runtimePath=Join-Path $projectRoot 'runtime'
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
switch($Action) {
  'Open' { & $cliPath open --project $projectRoot --lang zh }
  'Login' {
    Write-Host 'Scan with your own WeChat. This is a DevTools LOGIN QR, not the game preview.'
    & $cliPath login --qr-format image --qr-output (Join-Path $runtimePath 'wechat-login.png') --result-output (Join-Path $runtimePath 'wechat-login-result.json') --lang zh
  }
  'Status' { & $cliPath islogin --lang zh }
  'Preview' {
    $cfg=Get-Content -LiteralPath (Join-Path $projectRoot 'project.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($cfg.appid -notmatch '^wx[0-9a-fA-F]{16}$') {
      throw 'A real mini-program/test AppID is required. Get one at https://mp.weixin.qq.com/wxamp/sandbox?doc=1 and pass -AppId. touristappid is not a phone preview.'
    }
    $startedAt=[DateTime]::UtcNow
    $qrPath=Join-Path $runtimePath 'wechat-preview.png'
    & $cliPath preview --project $projectRoot --qr-format image --qr-output $qrPath --info-output (Join-Path $runtimePath 'wechat-preview-info.json') --lang zh
    $qr=Get-Item -LiteralPath $qrPath -ErrorAction SilentlyContinue
    if(-not $qr -or $qr.LastWriteTimeUtc -lt $startedAt -or $qr.Length -lt 100) {
      throw 'No fresh preview QR was generated. Complete real AppID/developer login and follow the DevTools error. Existing files are not proof of this run.'
    }
    Write-Host "Fresh preview QR: $qrPath"
  }
}
if($LASTEXITCODE -ne 0) {
  throw 'WeChat CLI did not complete. Follow its output; login / enabling the service port in DevTools Settings > Security may require your action. Do not treat an old QR file as a newly generated preview.'
}
