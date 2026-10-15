[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('windows', 'linux', 'macos')][string]$Platform,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$archPrefix = if ($Architecture -eq 'x64') { 'x86_64' } else { 'aarch64' }
$suffix = switch ($Platform) { 'windows' { 'pc-windows-msvc' } 'linux' { 'unknown-linux-gnu' } 'macos' { 'apple-darwin' } }
$exeSuffix = if ($Platform -eq 'windows') { '.exe' } else { '' }
$cli = Join-Path $repoRoot "target/$archPrefix-$suffix/release/codex-configurator$exeSuffix"
& $cli --version
if ($LASTEXITCODE -ne 0) { throw 'CLI startup failed.' }
$guiRoot = switch ($Platform) {
    'windows' { Join-Path $repoRoot "apps/gui/build/windows/$Architecture/runner/Release" }
    'linux' { Join-Path $repoRoot "apps/gui/build/linux/$Architecture/release/bundle" }
    'macos' { Join-Path $repoRoot 'apps/gui/build/macos/Build/Products/Release/codex_configurator.app' }
}
$nativeFiles = @($cli)
if ($Platform -eq 'windows') {
    $nativeFiles += Get-ChildItem $guiRoot -File | Where-Object Extension -In '.exe', '.dll' | Select-Object -ExpandProperty FullName
} elseif ($Platform -eq 'linux') {
    $nativeFiles += Join-Path $guiRoot 'codex_configurator'
    $nativeFiles += Get-ChildItem (Join-Path $guiRoot 'lib') -Filter '*.so' -File | Select-Object -ExpandProperty FullName
} else {
    $nativeFiles += Join-Path $guiRoot 'Contents/MacOS/codex_configurator'
    $nativeFiles += Get-ChildItem $guiRoot -Filter '*.dylib' -Recurse -File | Select-Object -ExpandProperty FullName
}
foreach ($nativeFile in $nativeFiles) {
    if ($Platform -eq 'macos') {
        $reported = & lipo -archs $nativeFile
        $expected = if ($Architecture -eq 'x64') { 'x86_64' } else { 'arm64' }
        if ($LASTEXITCODE -ne 0 -or $reported -notmatch "\b$expected\b") { throw "Unexpected architecture for $nativeFile : $reported" }
    } else {
        $bytes = [IO.File]::ReadAllBytes($nativeFile)
        if ($Platform -eq 'windows') {
            $header = [BitConverter]::ToInt32($bytes, 0x3c)
            $machine = [BitConverter]::ToUInt16($bytes, $header + 4)
            $expected = if ($Architecture -eq 'x64') { 0x8664 } else { 0xaa64 }
        } else {
            if ($bytes[0] -ne 0x7f -or $bytes[1] -ne 0x45 -or $bytes[5] -ne 1) { throw "Unexpected ELF header: $nativeFile" }
            $machine = [BitConverter]::ToUInt16($bytes, 18)
            $expected = if ($Architecture -eq 'x64') { 62 } else { 183 }
        }
        if ($machine -ne $expected) { throw "Unexpected architecture $machine in $nativeFile; expected $expected." }
    }
}
Write-Output "Verified $($nativeFiles.Count) native $Platform/$Architecture artifacts."
