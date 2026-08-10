[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TripName
)

$ErrorActionPreference = 'Stop'
$script:FinalVerdict = 'TRIP_PUBLISH_FAIL'

function Stop-WithVerdict {
    param(
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][string]$Message
    )
    $script:FinalVerdict = $Verdict
    throw $Message
}

function Invoke-TripGit {
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
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $($exitCode): $($output -join ' ')"
    }
    return $output
}

function Invoke-TripGhJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& gh @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne 0) {
        throw "gh $($Arguments -join ' ') failed with exit code $($exitCode): $($output -join ' ')"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Get-OptionalTripGhJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& gh @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -eq 0) {
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    $message = $output -join ' '
    if ($message -match '(?i)(HTTP 404|Not Found|404)') {
        return $null
    }
    throw "gh $($Arguments -join ' ') failed with exit code $($exitCode): $message"
}

function Test-TripAncestor {
    param(
        [Parameter(Mandatory)][string]$Ancestor,
        [Parameter(Mandatory)][string]$Descendant
    )
    & git -C $script:RepoRoot merge-base --is-ancestor $Ancestor $Descendant 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-TripDirtyPaths {
    param([Parameter(Mandatory)][object[]]$StatusLines)
    $paths = @()
    foreach ($lineObject in $StatusLines) {
        $line = [string]$lineObject
        if ($line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim()
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $paths += $path.Replace('/', '\')
    }
    return $paths
}

function Test-TripIndex {
    if (-not (Test-Path -LiteralPath $script:IndexPath -PathType Leaf)) {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' "Missing $script:IndexPath."
    }
    $bytes = [System.IO.File]::ReadAllBytes($script:IndexPath)
    if ($bytes.Length -eq 0) {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'Target index.html is empty.'
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch '(?i)<html' -or $text -notmatch '(?i)</html>') {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'Target index.html is not complete HTML.'
    }
    if ($text -match '(?i)(ghp_|github_pat_|sk-|-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----|api[_-]?key\s*[:=]|password\s*[:=])') {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'Target index.html contains an obvious secret pattern.'
    }
}

function Enable-TripPages {
    param([Parameter(Mandatory)][string]$Repository)
    $endpoint = "repos/$Repository/pages"
    $pages = Get-OptionalTripGhJson @('api', $endpoint)
    if ($null -eq $pages) {
        $body = '{"source":{"branch":"main","path":"/"}}'
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @($body | & gh api --method POST $endpoint --input - 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($exitCode -ne 0) {
            throw "Unable to enable GitHub Pages for $($Repository): $($output -join ' ')"
        }
        $pages = (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    return $pages
}

function Test-TripLivePages {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$PagesUrl,
        [Parameter(Mandatory)][datetime]$Deadline
    )
    $pageStatus = 'unknown'
    $buildStatus = 'unknown'
    while ((Get-Date) -lt $Deadline) {
        $pages = Get-OptionalTripGhJson @('api', "repos/$Repository/pages")
        $build = Get-OptionalTripGhJson @('api', "repos/$Repository/pages/builds/latest")
        $pageStatus = if ($null -ne $pages) { [string]$pages.status } else { 'unknown' }
        $buildStatus = if ($null -ne $build) { [string]$build.status } else { 'unknown' }
        if ($pageStatus -eq 'errored' -or $buildStatus -eq 'errored') {
            Stop-WithVerdict 'TRIP_PUBLISH_FAIL' "GitHub Pages deployment errored (pages=$pageStatus, build=$buildStatus)."
        }
        if ($pageStatus -eq 'built' -or $buildStatus -eq 'built') {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri $PagesUrl -MaximumRedirection 5 -TimeoutSec 30
                $statusCode = [int]$response.StatusCode
                if ($statusCode -ge 200 -and $statusCode -lt 400 -and $response.Content -match '(?i)<html') {
                    return [pscustomobject]@{ StatusCode = $statusCode; PageStatus = $pageStatus; BuildStatus = $buildStatus }
                }
            }
            catch {
                if ((Get-Date) -ge $Deadline) { throw }
            }
        }
        Start-Sleep -Seconds 5
    }
    Stop-WithVerdict 'TRIP_PUBLISH_FAIL' "Timed out waiting for Pages/live success (pages=$pageStatus, build=$buildStatus)."
}

try {
    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $rootFull = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\')
    $gitTop = ((Invoke-TripGit @('rev-parse', '--show-toplevel')) -join '').Trim()
    if ([System.IO.Path]::GetFullPath($gitTop).TrimEnd('\') -ne $rootFull) {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' "Git top-level is '$gitTop', expected '$script:RepoRoot'."
    }

    $name = $TripName.Trim()
    $reserved = @('_tools', '_archive', '_Travel-Template')
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\\/]' -or $name -match '(^|[.])[.](?:$|[\\/])' -or [System.IO.Path]::GetFileName($name) -ne $name -or $reserved -contains $name) {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' 'TripName must be a non-empty direct-child trip folder name.'
    }
    $tripPath = Join-Path $script:RepoRoot $name
    if (-not (Test-Path -LiteralPath $tripPath -PathType Container)) {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' "Trip folder does not exist: $tripPath"
    }
    $nestedGit = @(Get-ChildItem -LiteralPath $tripPath -Directory -Recurse -Force | Where-Object { $_.Name -eq '.git' })
    if ($nestedGit.Count -gt 0) {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' "Nested .git found below $tripPath."
    }
    $script:IndexPath = Join-Path $tripPath 'index.html'
    Test-TripIndex

    $remote = ((Invoke-TripGit @('remote', 'get-url', 'origin')) -join '').Trim()
    if ($remote -notmatch '^https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?$' -and $remote -notmatch '^git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$') {
        Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' "origin is not a GitHub URL: $remote"
    }
    $owner = $Matches[1]
    $repoName = $Matches[2]
    $repository = "$owner/$repoName"
    $branch = ((Invoke-TripGit @('branch', '--show-current')) -join '').Trim()
    if ($branch -ne 'main') { Stop-WithVerdict 'LOCAL_VALIDATION_FAIL' "Current branch must be main; found '$branch'." }

    $statusBefore = @(Invoke-TripGit @('status', '--porcelain'))
    $dirtyPaths = @(Get-TripDirtyPaths -StatusLines $statusBefore)
    $tripPrefix = "$name\"
    $outOfScope = @($dirtyPaths | Where-Object { $_ -ne $name -and -not $_.StartsWith($tripPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($outOfScope.Count -gt 0) {
        Stop-WithVerdict 'OUT_OF_SCOPE_DIRTY_CHANGES' "Dirty paths outside '$name': $($outOfScope -join ', ')"
    }
    $treeDirty = $dirtyPaths.Count -gt 0

    Invoke-TripGit @('fetch', 'origin', 'main') | Out-Null
    $localHead = ((Invoke-TripGit @('rev-parse', 'HEAD')) -join '').Trim()
    $remoteHead = ((Invoke-TripGit @('rev-parse', 'origin/main')) -join '').Trim()
    $remoteContainsLocal = Test-TripAncestor -Ancestor $localHead -Descendant $remoteHead
    $localContainsRemote = Test-TripAncestor -Ancestor $remoteHead -Descendant $localHead
    if (-not $remoteContainsLocal -and -not $localContainsRemote) {
        Stop-WithVerdict 'REMOTE_LOCAL_CONFLICT' 'Local and remote main histories diverged; both sides were preserved.'
    }
    if ($remoteContainsLocal -and -not $localContainsRemote) {
        if ($treeDirty) { Stop-WithVerdict 'REMOTE_LOCAL_CONFLICT' 'Remote is ahead while local changes exist.' }
        Invoke-TripGit @('pull', '--ff-only', 'origin', 'main') | Out-Null
    }

    Test-TripIndex
    $statusAfterSync = @(Invoke-TripGit @('status', '--porcelain'))
    $dirtyAfterSync = @(Get-TripDirtyPaths -StatusLines $statusAfterSync)
    $outOfScopeAfterSync = @($dirtyAfterSync | Where-Object { $_ -ne $name -and -not $_.StartsWith($tripPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($outOfScopeAfterSync.Count -gt 0) {
        Stop-WithVerdict 'OUT_OF_SCOPE_DIRTY_CHANGES' "Dirty paths outside '$name': $($outOfScopeAfterSync -join ', ')"
    }

    $script:EmptyCommitCreated = $false
    $statusTrip = @(Invoke-TripGit @('status', '--porcelain', '--', $name))
    if ($statusTrip.Count -gt 0) {
        Invoke-TripGit @('add', '--', $name) | Out-Null
        & git -C $script:RepoRoot diff --cached --quiet -- $name 2>$null
        $cachedExit = $LASTEXITCODE
        if ($cachedExit -eq 1) {
            Invoke-TripGit @('commit', '-m', "Update $name $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
        }
        elseif ($cachedExit -ne 0) {
            Stop-WithVerdict 'TRIP_PUBLISH_FAIL' 'Unable to inspect the staged trip diff.'
        }
    }

    $localHead = ((Invoke-TripGit @('rev-parse', 'HEAD')) -join '').Trim()
    $remoteHeadNow = ((Invoke-TripGit @('rev-parse', 'origin/main')) -join '').Trim()
    $needsPush = $localHead -ne $remoteHeadNow -and (Test-TripAncestor -Ancestor $remoteHeadNow -Descendant $localHead)
    if ($needsPush) { Invoke-TripGit @('push', 'origin', 'main') | Out-Null }
    Invoke-TripGit @('fetch', 'origin', 'main') | Out-Null
    $remoteHead = ((Invoke-TripGit @('rev-parse', 'origin/main')) -join '').Trim()
    if ($remoteHead -ne $localHead) { Stop-WithVerdict 'TRIP_PUBLISH_FAIL' "Remote SHA $remoteHead differs from local SHA $localHead." }

    $pages = Enable-TripPages -Repository $repository
    $pagesRoot = [string]$pages.html_url
    if ([string]::IsNullOrWhiteSpace($pagesRoot)) { $pagesRoot = "https://$($owner.ToLowerInvariant()).github.io/$($repoName.ToLowerInvariant())/" }
    $liveUrl = "$($pagesRoot.TrimEnd('/'))/$name/"
    $deployment = Test-TripLivePages -Repository $repository -PagesUrl $liveUrl -Deadline (Get-Date).AddSeconds(240)

    Write-Output "TRIP_NAME=$name"
    Write-Output "REPOSITORY=$repository"
    Write-Output "LOCAL_COMMIT_SHA=$localHead"
    Write-Output "REMOTE_COMMIT_SHA=$remoteHead"
    Write-Output "LIVE_URL=$liveUrl"
    Write-Output "PAGES_STATUS=$($deployment.PageStatus)"
    Write-Output "PAGES_BUILD_STATUS=$($deployment.BuildStatus)"
    Write-Output "LIVE_HTTP_STATUS=$($deployment.StatusCode)"
    Write-Output "EMPTY_COMMIT_CREATED=$script:EmptyCommitCreated"
    $script:FinalVerdict = 'TRIP_PUBLISH_PASS'
    Write-Output "FINAL_VERDICT=$script:FinalVerdict"
}
catch {
    Write-Error $_.Exception.Message
    Write-Output "FINAL_VERDICT=$script:FinalVerdict"
    throw
}
