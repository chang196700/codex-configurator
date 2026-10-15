[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('windows', 'linux', 'macos')][string]$Platform,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [string]$Version = '0.1.0'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$archPrefix = if ($Architecture -eq 'x64') { 'x86_64' } else { 'aarch64' }
$suffix = switch ($Platform) { 'windows' { 'pc-windows-msvc' } 'linux' { 'unknown-linux-gnu' } 'macos' { 'apple-darwin' } }
$extension = if ($Platform -eq 'windows') { '.exe' } else { '' }
$cliPath = Join-Path $repoRoot "target/$archPrefix-$suffix/release/codex-configurator$extension"
$bundlePath = switch ($Platform) {
    'windows' { Join-Path $repoRoot "apps/gui/build/windows/$Architecture/runner/Release" }
    'linux' { Join-Path $repoRoot "apps/gui/build/linux/$Architecture/release/bundle" }
    'macos' { Join-Path $repoRoot 'apps/gui/build/macos/Build/Products/Release/codex_configurator.app' }
}
if (-not (Test-Path -LiteralPath $cliPath)) { throw "Missing CLI: $cliPath" }
if (-not (Test-Path -LiteralPath $bundlePath)) { throw "Missing GUI bundle: $bundlePath" }
$name = "codex-configurator-$Version-$Platform-$Architecture"
$stage = Join-Path $repoRoot "dist/$name"
if (Test-Path -LiteralPath $stage) { throw "Package staging directory already exists: $stage. Choose a new version or remove that exact directory before repackaging." }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath $cliPath -Destination $stage
if ($Platform -eq 'windows') {
    Get-ChildItem -LiteralPath (Split-Path -Parent $cliPath) -File |
        Where-Object Name -Match '^(msvcp|vcruntime|concrt).*\.dll$' |
        Copy-Item -Destination $stage
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'vcruntime140.dll'))) {
        throw 'Missing Windows app-local runtime. Run scripts/build.ps1 before packaging.'
    }
}
foreach ($document in @('LICENSE-MIT', 'LICENSE-APACHE', 'THIRD_PARTY_NOTICES.md', 'README.md', 'README.en.md', 'tool-versions.json')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $document) -Destination $stage
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs') -Destination $stage -Recurse
& (Join-Path $PSScriptRoot 'collect-rust-licenses.ps1') -Target "$archPrefix-$suffix" -Destination (Join-Path $stage 'licenses/rust')
if ($Platform -eq 'macos') {
    Copy-Item -LiteralPath $bundlePath -Destination $stage -Recurse
} else {
    $guiStage = Join-Path $stage 'gui'
    New-Item -ItemType Directory -Path $guiStage | Out-Null
    Get-ChildItem -LiteralPath $bundlePath | Copy-Item -Destination $guiStage -Recurse
}
Push-Location (Join-Path $repoRoot 'dist')
try {
    $archiveName = if ($Platform -eq 'windows') { "$name.zip" } else { "$name.tar.gz" }
    if ($Platform -eq 'windows') {
        Compress-Archive -LiteralPath $stage -DestinationPath $archiveName
    } else {
        & tar -czf $archiveName $name
        if ($LASTEXITCODE -ne 0) { throw 'tar failed.' }
    }
    $hash = (Get-FileHash -LiteralPath $archiveName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $archiveName" | Set-Content -LiteralPath "$archiveName.sha256" -Encoding utf8NoBOM
    Write-Output (Join-Path (Get-Location) $archiveName)
} finally { Pop-Location }
