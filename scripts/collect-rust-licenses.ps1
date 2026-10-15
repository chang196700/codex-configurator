#requires -Version 7.0
<#
.SYNOPSIS
Collects attribution files for the locked Rust dependency graph of one target.
.DESCRIPTION
Reads Cargo metadata, walks dependencies of every workspace member, and copies
crate-root license, notice, and copyright files. An explicitly declared
license_file inside a crate is included even when its name is nonstandard.
The destination must be absent or empty so an older inventory cannot be mixed
with a different target or dependency graph. Missing standalone license files
are recorded in INDEX.json and README.md and do not fail collection.
.EXAMPLE
./scripts/collect-rust-licenses.ps1 -Target x86_64-pc-windows-msvc -Destination .cache/rust-licenses
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_.-]+$')]
    [string]$Target,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$licenseRepoRoot = Split-Path -Parent $PSScriptRoot
$licenseManifest = Join-Path $licenseRepoRoot 'Cargo.toml'
$licenseDestination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
$licensePathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$licensePathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }

if (Test-Path -LiteralPath $licenseDestination) {
    $licenseDestinationItem = Get-Item -LiteralPath $licenseDestination -Force
    if (-not $licenseDestinationItem.PSIsContainer -or ($licenseDestinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Destination must be a regular directory: $licenseDestination"
    }
    if (@(Get-ChildItem -LiteralPath $licenseDestination -Force).Count -ne 0) {
        throw "Destination is not empty: $licenseDestination. Choose a fresh directory to avoid mixing inventories."
    }
}

$licenseCargo = (Get-Command cargo -CommandType Application -ErrorAction Stop).Source
$licenseCargoArguments = @(
    'metadata', '--locked', '--format-version', '1',
    '--filter-platform', $Target, '--manifest-path', $licenseManifest
)
$licenseMetadataText = (& $licenseCargo @licenseCargoArguments) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed with exit code $LASTEXITCODE. Restore the locked dependencies before collecting licenses." }
$licenseMetadata = $licenseMetadataText | ConvertFrom-Json -Depth 100
if ($null -eq $licenseMetadata.resolve) { throw 'Cargo metadata did not include a resolved dependency graph.' }

$licenseWorkspaceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$licenseReachableIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$licenseQueue = [Collections.Generic.Queue[string]]::new()
$licenseNodes = @{}
foreach ($licenseNode in $licenseMetadata.resolve.nodes) { $licenseNodes[$licenseNode.id] = $licenseNode }
foreach ($licenseWorkspaceId in $licenseMetadata.workspace_members) {
    [void]$licenseWorkspaceIds.Add($licenseWorkspaceId)
    $licenseQueue.Enqueue($licenseWorkspaceId)
}
while ($licenseQueue.Count -gt 0) {
    $licensePackageId = $licenseQueue.Dequeue()
    if (-not $licenseReachableIds.Add($licensePackageId)) { continue }
    if (-not $licenseNodes.ContainsKey($licensePackageId)) { throw "Missing resolved package node: $licensePackageId" }
    foreach ($licenseDependency in $licenseNodes[$licensePackageId].deps) { $licenseQueue.Enqueue($licenseDependency.pkg) }
}

$licensePackages = @($licenseMetadata.packages |
    Where-Object { $licenseReachableIds.Contains($_.id) -and -not $licenseWorkspaceIds.Contains($_.id) } |
    Sort-Object name, version, id)
$licenseRecords = [Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Path $licenseDestination -Force | Out-Null

foreach ($licensePackage in $licensePackages) {
    $licenseCrateRoot = [IO.Path]::GetFullPath((Split-Path -Parent $licensePackage.manifest_path))
    $licenseCratePrefix = $licenseCrateRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $licenseCrateName = "$($licensePackage.name)-$($licensePackage.version)"
    $licenseCrateDestination = [IO.Path]::GetFullPath((Join-Path $licenseDestination $licenseCrateName))
    $licenseOutputPrefix = $licenseDestination.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $licenseCrateDestination.StartsWith($licenseOutputPrefix, $licensePathComparison)) {
        throw "Crate output directory escapes the destination: $licenseCrateName"
    }
    if (-not (Test-Path -LiteralPath $licenseCrateRoot -PathType Container)) {
        throw "Cargo source directory is unavailable for $licenseCrateName. Fetch the locked dependencies first."
    }
    New-Item -ItemType Directory -Path $licenseCrateDestination -Force | Out-Null

    $licenseCandidates = [Collections.Generic.HashSet[string]]::new($licensePathComparer)
    $licenseWarnings = [Collections.Generic.List[string]]::new()
    foreach ($licenseRootFile in Get-ChildItem -LiteralPath $licenseCrateRoot -File -Force) {
        if ($licenseRootFile.Name -notmatch '(^|[._-])(LICENSE|LICENCE|UNLICENSE|COPYING|NOTICES?|COPYRIGHT)([._-]|$)') { continue }
        if ($licenseRootFile.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $licenseWarnings.Add("Symbolic link not copied: $($licenseRootFile.Name)")
            continue
        }
        [void]$licenseCandidates.Add($licenseRootFile.FullName)
    }

    $licenseDeclaredStatus = 'not_declared'
    $licenseDeclaredFile = $licensePackage.license_file
    if (-not [string]::IsNullOrWhiteSpace($licenseDeclaredFile)) {
        $licenseDeclaredPath = if ([IO.Path]::IsPathRooted($licenseDeclaredFile)) {
            [IO.Path]::GetFullPath($licenseDeclaredFile)
        } else {
            [IO.Path]::GetFullPath((Join-Path $licenseCrateRoot $licenseDeclaredFile))
        }
        if (-not $licenseDeclaredPath.StartsWith($licenseCratePrefix, $licensePathComparison)) {
            $licenseDeclaredStatus = 'outside_crate_root_not_copied'
            $licenseWarnings.Add('The declared license_file is outside the crate source directory and was not copied.')
        } elseif (-not (Test-Path -LiteralPath $licenseDeclaredPath -PathType Leaf)) {
            $licenseDeclaredStatus = 'not_found'
            $licenseWarnings.Add('The declared license_file is not present in the downloaded crate.')
        } elseif ((Get-Item -LiteralPath $licenseDeclaredPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $licenseDeclaredStatus = 'symbolic_link_not_copied'
            $licenseWarnings.Add('The declared license_file is a symbolic link and was not copied.')
        } else {
            $licenseDeclaredStatus = 'collected'
            [void]$licenseCandidates.Add($licenseDeclaredPath)
        }
    }

    $licenseCopiedFiles = [Collections.Generic.List[object]]::new()
    foreach ($licenseSourceFile in @($licenseCandidates | Sort-Object)) {
        $licenseSourceHash = (Get-FileHash -LiteralPath $licenseSourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $licenseFileName = [IO.Path]::GetFileName($licenseSourceFile)
        $licenseOutputFile = Join-Path $licenseCrateDestination $licenseFileName
        # Two sources can share a crate name/version or a license basename.
        # Preserve differing contents under a hash-prefixed filename.
        if ((Test-Path -LiteralPath $licenseOutputFile) -and
            (Get-FileHash -LiteralPath $licenseOutputFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $licenseSourceHash) {
            $licenseFileName = "$($licenseSourceHash.Substring(0, 12))-$licenseFileName"
            $licenseOutputFile = Join-Path $licenseCrateDestination $licenseFileName
        }
        if (-not (Test-Path -LiteralPath $licenseOutputFile)) {
            Copy-Item -LiteralPath $licenseSourceFile -Destination $licenseOutputFile
        }
        $licenseCopiedFiles.Add([ordered]@{
            source_file = [IO.Path]::GetRelativePath($licenseCrateRoot, $licenseSourceFile).Replace('\', '/')
            path = "$licenseCrateName/$licenseFileName"
            sha256 = $licenseSourceHash
        })
    }

    $licenseRecords.Add([ordered]@{
        id = $licensePackage.id
        name = $licensePackage.name
        version = $licensePackage.version
        license = $licensePackage.license
        repository = $licensePackage.repository
        source = $licensePackage.source
        license_file = $licenseDeclaredFile
        license_file_status = $licenseDeclaredStatus
        collection_status = if ($licenseCopiedFiles.Count -gt 0) { 'collected' } else { 'no_standalone_license_files' }
        files = @($licenseCopiedFiles.ToArray())
        warnings = @($licenseWarnings.ToArray())
    })
}

$licenseWithoutFiles = @($licenseRecords | Where-Object { $_.files.Count -eq 0 })
$licenseFileCount = [int](($licenseRecords | ForEach-Object { $_.files.Count } | Measure-Object -Sum).Sum)
$licenseIndex = [ordered]@{
    format_version = 1
    target = $Target
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    cargo_lock_sha256 = (Get-FileHash -LiteralPath (Join-Path $licenseRepoRoot 'Cargo.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
    metadata_command = @('cargo', 'metadata', '--locked', '--format-version', '1', '--filter-platform', $Target)
    scope = 'Non-workspace packages reachable from all workspace members in the target-filtered Cargo graph, including resolved build and development dependencies.'
    dependency_count = $licenseRecords.Count
    packages_with_files = $licenseRecords.Count - $licenseWithoutFiles.Count
    packages_without_files = $licenseWithoutFiles.Count
    file_count = $licenseFileCount
    packages = @($licenseRecords.ToArray())
}
$licenseIndex | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $licenseDestination 'INDEX.json') -Encoding utf8NoBOM

$licenseReadme = [Collections.Generic.List[string]]::new()
$licenseReadme.Add('# Rust dependency attribution')
$licenseReadme.Add('')
$licenseReadme.Add("Target: $Target")
$licenseReadme.Add('')
$licenseReadme.Add("This directory records $($licenseRecords.Count) non-workspace Rust packages from the locked, target-filtered Cargo dependency graph. It includes transitive dependencies of every workspace member and any resolved build/development dependencies; it is not a list of symbols linked into the final executable.")
$licenseReadme.Add('')
$licenseReadme.Add('Original license, NOTICE, COPYING, and COPYRIGHT files are copied without modification into the corresponding name-version directory. A declared license_file inside the crate is also collected. INDEX.json records the manifest SPDX expression, repository, declared license file, collection status, file paths, and SHA-256 hashes. A null SPDX expression means Cargo did not report one; no license is inferred.')
$licenseReadme.Add('')
$licenseReadme.Add("Copied file references: $licenseFileCount. Packages without standalone attribution files: $($licenseWithoutFiles.Count). Missing files are recorded rather than treated as successful license-text collection. Consult the recorded SPDX expression and upstream repository for those packages.")
$licenseReadme.Add('')
$licenseReadme.Add('| Package | Manifest SPDX expression | Collected files |')
$licenseReadme.Add('| --- | --- | ---: |')
foreach ($licenseRecord in $licenseRecords) {
    $licenseExpression = if ([string]::IsNullOrWhiteSpace($licenseRecord.license)) { '(not specified)' } else { $licenseRecord.license.Replace('|', '\|') }
    $licenseReadme.Add("| $($licenseRecord.name) $($licenseRecord.version) | $licenseExpression | $($licenseRecord.files.Count) |")
}
if ($licenseWithoutFiles.Count -gt 0) {
    $licenseReadme.Add('')
    $licenseReadme.Add('## Packages without standalone files')
    $licenseReadme.Add('')
    foreach ($licenseRecord in $licenseWithoutFiles) {
        $licenseRepository = if ([string]::IsNullOrWhiteSpace($licenseRecord.repository)) { '(repository not specified)' } else { $licenseRecord.repository }
        $licenseReadme.Add("- $($licenseRecord.name) $($licenseRecord.version): $licenseRepository")
    }
}
$licenseReadme | Set-Content -LiteralPath (Join-Path $licenseDestination 'README.md') -Encoding utf8NoBOM

[pscustomobject]@{
    Destination = $licenseDestination
    Target = $Target
    Dependencies = $licenseRecords.Count
    FileReferences = $licenseFileCount
    PackagesWithoutFiles = $licenseWithoutFiles.Count
}
