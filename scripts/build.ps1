[CmdletBinding()]
param(
    [ValidateSet('windows', 'linux', 'macos')][string]$Platform,
    [ValidateSet('x64', 'arm64')][string]$Architecture,
    [switch]$CliOnly,
    [switch]$SkipGenerate
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Platform) {
    $Platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
}
if (-not $Architecture) {
    $Architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
}
$hostPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
$hostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($Platform -ne $hostPlatform -or $Architecture -ne $hostArchitecture) {
    throw "Desktop builds require a native $Platform/$Architecture host; current host is $hostPlatform/$hostArchitecture."
}
$archPrefix = if ($Architecture -eq 'x64') { 'x86_64' } else { 'aarch64' }
$targetSuffix = switch ($Platform) {
    'windows' { 'pc-windows-msvc' }
    'linux' { 'unknown-linux-gnu' }
    'macos' { 'apple-darwin' }
}
$target = "$archPrefix-$targetSuffix"
$versions = Get-Content (Join-Path $repoRoot 'tool-versions.json') -Raw | ConvertFrom-Json
$previousRustToolchain = $env:RUSTUP_TOOLCHAIN
$env:RUSTUP_TOOLCHAIN = $versions.rust
$localFlutter = Join-Path $repoRoot '.tools/flutter/bin'
if (Test-Path -LiteralPath $localFlutter) { $env:PATH = "$localFlutter$([IO.Path]::PathSeparator)$env:PATH" }
$localCodegen = Join-Path $repoRoot '.tools/frb'
if (Test-Path -LiteralPath $localCodegen) { $env:PATH = "$localCodegen$([IO.Path]::PathSeparator)$env:PATH" }

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE." }
}

Push-Location $repoRoot
try {
    Invoke-Checked 'rustup' @('target', 'add', $target)
    Invoke-Checked 'cargo' @('build', '--locked', '--release', '--target', $target, '-p', 'codex-configurator')
    if (-not $CliOnly) {
        Push-Location (Join-Path $repoRoot 'apps/gui')
        try {
            Invoke-Checked 'flutter' @('pub', 'get', '--enforce-lockfile')
            if (-not $SkipGenerate) {
                $generatorVersion = & flutter_rust_bridge_codegen --version
                if ($generatorVersion -notmatch [regex]::Escape($versions.flutter_rust_bridge)) {
                    throw "Install flutter_rust_bridge_codegen $($versions.flutter_rust_bridge) before regenerating bindings."
                }
                Invoke-Checked 'flutter_rust_bridge_codegen' @('generate')
            }
            Invoke-Checked 'flutter' @('analyze')
            if ($Platform -eq 'windows') {
                # Flutter's Windows asset stamp does not track app.dill; refresh icon subsets after Dart changes.
                $flutterBuildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'apps/gui/.dart_tool/flutter_build'))
                if (Test-Path -LiteralPath $flutterBuildRoot -PathType Container) {
                    if ((Get-Item -LiteralPath $flutterBuildRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        throw "Refusing to clear asset stamps through a linked build directory: $flutterBuildRoot"
                    }
                    $flutterBuildPrefix = $flutterBuildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                    $assetStampName = "release_bundle_windows-${Architecture}_assets.stamp"
                    foreach ($buildDirectory in Get-ChildItem -LiteralPath $flutterBuildRoot -Directory) {
                        if ($buildDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                        $assetStampPath = [IO.Path]::GetFullPath((Join-Path $buildDirectory.FullName $assetStampName))
                        if (-not $assetStampPath.StartsWith($flutterBuildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                            throw "Asset stamp is outside the Flutter build cache: $assetStampPath"
                        }
                        if (Test-Path -LiteralPath $assetStampPath -PathType Leaf) {
                            if ((Get-Item -LiteralPath $assetStampPath).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                                throw "Refusing to clear a linked asset stamp: $assetStampPath"
                            }
                            Remove-Item -LiteralPath $assetStampPath -Force
                        }
                    }
                }
            }
            Invoke-Checked 'flutter' @('build', $Platform, '--release')
        } finally { Pop-Location }
    }
    if ($Platform -eq 'windows') {
        $destinations = @((Join-Path $repoRoot "target/$target/release"))
        if (-not $CliOnly) { $destinations += Join-Path $repoRoot "apps/gui/build/windows/$Architecture/runner/Release" }
        & (Join-Path $PSScriptRoot 'bundle-windows-runtime.ps1') -Architecture $Architecture -Destination $destinations
    }
} finally {
    Pop-Location
    $env:RUSTUP_TOOLCHAIN = $previousRustToolchain
}
