param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'outputs' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

# Source-only allowlist. In particular, server/data, runtime, work, captures,
# credentials and node_modules are deliberately not walked or archived.
$directories = @('ios', 'server/src', 'server/test', 'server/tools', 'docs', 'deploy', 'scripts')
$files = @('.gitignore', 'AGENTS.md', 'README.md', 'package.json', 'Dockerfile',
           'server/index.mjs', 'server/admin.mjs', 'server/package.json',
           'server/package-lock.json', 'server/README.md')
$sourceFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($relative in $directories) {
    $absolute = Join-Path $projectRoot $relative
    if (Test-Path -LiteralPath $absolute -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $absolute -Recurse -File) {
            if ($item.FullName -match '[\\/]xcuserdata[\\/]' -or
                $item.Name -eq '.DS_Store' -or $item.Name -like '*.xcuserstate') { continue }
            $sourceFiles.Add($item)
        }
    }
}
foreach ($relative in $files) {
    $absolute = Join-Path $projectRoot $relative
    if (Test-Path -LiteralPath $absolute -PathType Leaf) {
        $sourceFiles.Add((Get-Item -LiteralPath $absolute))
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$archivePath = Join-Path $OutputDirectory "shijing-native-ios-source-$stamp.zip"
$archive = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in $sourceFiles) {
        $prefix = $projectRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $item.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to archive a file outside the project root: $($item.FullName)"
        }
        $entry = $item.FullName.Substring($prefix.Length).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $item.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
}
Write-Output $archivePath
Write-Output "Source files: $($sourceFiles.Count). No user capture media or server credentials included."
