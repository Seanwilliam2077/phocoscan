#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)][string]$FramesDirectory,
    [string]$OutputDirectory,
    [string]$ColmapBat
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ColmapBat) { $ColmapBat = Join-Path $projectRoot 'work/tools/colmap-4.2.1/COLMAP.bat' }
$ColmapBat = (Resolve-Path -LiteralPath $ColmapBat -ErrorAction Stop).Path
$frames = (Resolve-Path -LiteralPath $FramesDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $frames -PathType Container)) { throw 'FramesDirectory must be a directory.' }
$images = @(Get-ChildItem -LiteralPath $frames -File |
    Where-Object { $_.Extension.ToLowerInvariant() -in @('.jpg', '.jpeg', '.png') } |
    Sort-Object Name)
if ($images.Count -lt 2 -or $images.Count -gt 1000) { throw 'Expected 2 to 1000 JPEG/PNG frames.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Split-Path $frames -Parent) 'sfm-colmap-cpu' }
$out = [System.IO.Path]::GetFullPath($OutputDirectory)
$prefix = $frames.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($out.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must not be inside FramesDirectory.'
}
if (Test-Path -LiteralPath $out) { throw "OutputDirectory already exists; refusing to overwrite: $out" }

$inputHashes = @($images | ForEach-Object {
    [pscustomobject]@{ file = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$sourceManifestPath = Join-Path (Split-Path $frames -Parent) 'manifest.json'
if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
    throw 'T0 preparation manifest.json is required beside the frames directory.'
}
$sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
if ($sourceManifest.provenance -ne 'external_rgb_video' -or
    @($sourceManifest.frames).Count -ne $inputHashes.Count) {
    throw 'T0 frame manifest provenance or frame count does not match.'
}
foreach ($item in $inputHashes) {
    $match = @($sourceManifest.frames | Where-Object { $_.file -eq $item.file })
    if ($match.Count -ne 1 -or $match[0].sha256 -ne $item.sha256) {
        throw "T0 frame hash does not match its manifest: $($item.file)"
    }
}
$sourceManifestHash = (Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
New-Item -ItemType Directory -Path $out | Out-Null
$logs = New-Item -ItemType Directory -Path (Join-Path $out 'logs')
$sparse = New-Item -ItemType Directory -Path (Join-Path $out 'sparse')
$database = Join-Path $out 'database.db'
$started = (Get-Date).ToUniversalTime().ToString('o')
$versionLog = Join-Path $logs.FullName 'version.log'
& $ColmapBat version *> $versionLog
if ($LASTEXITCODE -ne 0) { throw "COLMAP version check failed; see $versionLog" }
$version = (Get-Content -LiteralPath $versionLog -TotalCount 1)

function Invoke-ColmapStage {
    param([string]$Name, [string[]]$Arguments)
    $log = Join-Path $logs.FullName "$Name.log"
    & $ColmapBat @Arguments *> $log
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $tail = (Get-Content -LiteralPath $log -Tail 12) -join [Environment]::NewLine
        throw "COLMAP $Name failed (exit $code). Log: $log`n$tail"
    }
    return $log
}

$status = 'failed'
$failure = $null
$models = @()
try {
    Invoke-ColmapStage -Name 'feature_extractor' -Arguments @(
        'feature_extractor', '--database_path', $database, '--image_path', $frames,
        '--ImageReader.single_camera', '1', '--ImageReader.camera_model', 'SIMPLE_RADIAL',
        '--FeatureExtraction.use_gpu', '0', '--FeatureExtraction.num_threads', '1',
        '--FeatureExtraction.max_image_size', '1600'
    ) | Out-Null
    Invoke-ColmapStage -Name 'exhaustive_matcher' -Arguments @(
        'exhaustive_matcher', '--database_path', $database,
        '--FeatureMatching.use_gpu', '0', '--FeatureMatching.num_threads', '1',
        '--TwoViewGeometry.random_seed', '0'
    ) | Out-Null
    $mapperLog = Join-Path $logs.FullName 'mapper.log'
    & $ColmapBat 'mapper' '--database_path' $database '--image_path' $frames `
        '--output_path' $sparse.FullName '--Mapper.min_model_size' '3' `
        '--Mapper.num_threads' '1' '--Mapper.random_seed' '0' *> $mapperLog
    $mapperExit = $LASTEXITCODE
    if ($mapperExit -ne 0 -and -not ((Get-Content -LiteralPath $mapperLog -Raw) -match 'Failed to create any sparse model')) {
        $tail = (Get-Content -LiteralPath $mapperLog -Tail 12) -join [Environment]::NewLine
        throw "COLMAP mapper failed (exit $mapperExit). Log: $mapperLog`n$tail"
    }
    $modelDirectories = @(Get-ChildItem -LiteralPath $sparse.FullName -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'cameras.bin') })
    foreach ($model in $modelDirectories) {
        $name = 'model_' + $model.Name
        $analysis = Invoke-ColmapStage -Name $name -Arguments @('model_analyzer', '--path', $model.FullName)
        $analysisText = Get-Content -LiteralPath $analysis -Raw
        $registered = [regex]::Match($analysisText, 'Registered images:\s*(\d+)')
        $points = [regex]::Match($analysisText, 'Points:\s*(\d+)')
        $reprojection = [regex]::Match($analysisText, 'Mean reprojection error:\s*([0-9.]+)px')
        $models += [pscustomobject]@{
            directory = $model.FullName
            analysisLog = $analysis
            registeredImages = if ($registered.Success) { [int]$registered.Groups[1].Value } else { $null }
            points3D = if ($points.Success) { [int]$points.Groups[1].Value } else { $null }
            meanReprojectionErrorPx = if ($reprojection.Success) {
                [double]::Parse($reprojection.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
            } else { $null }
        }
    }
    $status = if ($models.Count -gt 0) { 'sparse_model_created' } else { 'no_sparse_model' }
} catch {
    $failure = $_.Exception.Message
} finally {
    $summary = [pscustomobject]@{
        schemaVersion = 1
        source = 'external_rgb_video_extracted_frames'
        algorithm = 'COLMAP CPU sparse SfM'
        colmapVersion = $version
        framesDirectory = $frames
        frameCount = $images.Count
        inputHashes = $inputHashes
        sourceManifestSHA256 = $sourceManifestHash
        originalVideoSHA256 = $sourceManifest.source.sha256
        startedAtUTC = $started
        completedAtUTC = (Get-Date).ToUniversalTime().ToString('o')
        status = $status
        failure = $failure
        models = $models
        limitations = @('Sparse geometry only; no metric scale or collision mesh verified.',
                        'Stock iPhone Camera video has no synchronized ARKit pose, intrinsics or LiDAR depth.')
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding utf8
}
if ($failure) { throw $failure }
Write-Output "COLMAP status: $status; models: $($models.Count); summary: $(Join-Path $out 'summary.json')"
