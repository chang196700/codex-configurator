[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory)][string[]]$Destination
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Visual C++ runtime bundling requires Windows.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Installer vswhere.exe was not found.' }
$installations = & $vswhere -products '*' -property installationPath
if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed.' }
$candidates = foreach ($installation in $installations) {
    $redist = Join-Path $installation 'VC/Redist/MSVC'
    if (Test-Path -LiteralPath $redist) {
        foreach ($version in Get-ChildItem -LiteralPath $redist -Directory) {
            if ($version.Name -match '^\d+\.\d+\.\d+$') {
                $archRoot = Join-Path $version.FullName $Architecture
                if (Test-Path -LiteralPath $archRoot) {
                    foreach ($crt in Get-ChildItem -LiteralPath $archRoot -Directory -Filter 'Microsoft.VC*.CRT') {
                        [pscustomobject]@{ Version = [version]$version.Name; Path = $crt.FullName }
                    }
                }
            }
        }
    }
}
$runtime = $candidates | Sort-Object Version -Descending | Select-Object -First 1
if (-not $runtime) { throw "No redistributable Visual C++ CRT found for $Architecture. Install the matching Visual Studio C++ components." }
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtime.Path $required))) { throw "Incomplete redistributable CRT: $required" }
}
foreach ($directory in $Destination) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Build output directory does not exist: $directory" }
    Get-ChildItem -LiteralPath $runtime.Path -Filter '*.dll' -File | Copy-Item -Destination $directory
}
Write-Output "Bundled Visual C++ $($runtime.Version) $Architecture redistributable DLLs."
