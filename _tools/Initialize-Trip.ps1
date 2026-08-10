[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TripName,
    [string]$SourceHtml
)

$ErrorActionPreference = 'Stop'
$script:FinalVerdict = 'TRIP_INITIALIZE_FAIL'

function Stop-WithVerdict {
    param(
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][string]$Message
    )
    $script:FinalVerdict = $Verdict
    throw $Message
}

function Invoke-InitGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $script:RepoRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $($exitCode): $($output -join ' ')" }
    return $output
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-InitHtml {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'index.html is empty.' }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch '(?i)<html' -or $text -notmatch '(?i)</html>') { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'index.html is not complete HTML.' }
    if ($text -match '(?i)(ghp_|github_pat_|sk-|-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----|api[_-]?key\s*[:=]|password\s*[:=])') { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'index.html contains an obvious secret pattern.' }
}

try {
    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $rootFull = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\')
    $gitTop = ((Invoke-InitGit @('rev-parse', '--show-toplevel')) -join '').Trim()
    if ([System.IO.Path]::GetFullPath($gitTop).TrimEnd('\') -ne $rootFull) { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' "Git top-level is '$gitTop', expected '$script:RepoRoot'." }

    $raw = $TripName.Trim().ToLowerInvariant()
    $slug = [regex]::Replace($raw, '[^a-z0-9-]+', '-')
    $slug = [regex]::Replace($slug, '-+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'TripName does not produce a URL-safe slug.' }
    $tripPath = Join-Path $script:RepoRoot $slug
    if (Test-Path -LiteralPath $tripPath) { Stop-WithVerdict 'REMOTE_LOCAL_CONFLICT' "Refusing to overwrite existing trip folder: $tripPath" }
    New-Item -ItemType Directory -Path $tripPath | Out-Null

    $indexPath = Join-Path $tripPath 'index.html'
    if (-not [string]::IsNullOrWhiteSpace($SourceHtml)) {
        $sourcePath = (Resolve-Path -LiteralPath $SourceHtml -ErrorAction Stop).Path
        [System.IO.File]::Copy($sourcePath, $indexPath, $false)
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $workingHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        if ($sourceHash -ne $workingHash) { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'SourceHtml and new index.html SHA256 hashes differ.' }
    }
    else {
        Write-Utf8File -Path $indexPath -Content @'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>New Trip Placeholder</title></head>
<body><main><h1>New trip placeholder</h1><p>Replace this placeholder with the authoritative trip HTML.</p></main></body>
</html>
'@
    }
    Test-InitHtml -Path $indexPath

    Write-Utf8File -Path (Join-Path $tripPath 'PUBLISH.cmd') -Content "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\_tools\Publish-Trip.ps1`" -TripName `"$slug`"`r`npause`r`n"
    Write-Utf8File -Path (Join-Path $tripPath 'AGENTS.md') -Content @'
# Trip folder instructions

- This folder is a normal subfolder of the `Desktop\Trips` monorepo; it must not contain `.git`.
- `index.html` is the authoritative working HTML for this trip.
- Preserve the travel template unless explicitly asked to change it.
- Use the shared `PUBLISH.cmd` after review; never force push.
'@
    Write-Utf8File -Path (Join-Path $tripPath 'README.md') -Content @"
# $slug

Trip folder in the `Gary-py/trips` monorepo.

- Working HTML: `index.html`
- One-click publish: `PUBLISH.cmd`
- Shared publisher: `..\_tools\Publish-Trip.ps1`

Review the generated files, then run `PUBLISH.cmd` to publish only this trip.
"@

    $rootIndexPath = Join-Path $script:RepoRoot 'index.html'
    if (-not (Test-Path -LiteralPath $rootIndexPath -PathType Leaf)) { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'Root library index.html is missing.' }
    $rootIndex = [System.IO.File]::ReadAllText($rootIndexPath)
    if ($rootIndex -notmatch '(?i)</ul>') { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'Root library index.html has no trip list.' }
    if ($rootIndex -notmatch [regex]::Escape("./$slug/")) {
        $entry = "    <li><a href=`"./$slug/`">$slug</a></li>"
        $rootIndex = [regex]::Replace($rootIndex, '(?i)</ul>', "$entry`r`n</ul>", 1)
        Write-Utf8File -Path $rootIndexPath -Content $rootIndex
    }

    $childGit = @(Get-ChildItem -LiteralPath $tripPath -Directory -Recurse -Force | Where-Object { $_.Name -eq '.git' })
    if ($childGit.Count -gt 0) { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'Initializer created a nested .git unexpectedly.' }
    Write-Output "TRIP_NAME=$slug"
    Write-Output "TRIP_PATH=$tripPath"
    Write-Output 'GITHUB_REPOSITORY_CREATED=false'
    Write-Output 'REVIEW_BEFORE_PUBLISH=true'
    $script:FinalVerdict = 'TRIP_INITIALIZE_PASS'
    Write-Output "FINAL_VERDICT=$script:FinalVerdict"
}
catch {
    Write-Error $_.Exception.Message
    Write-Output "FINAL_VERDICT=$script:FinalVerdict"
    throw
}
