#Requires -Version 7.2
<#
.SYNOPSIS
    Shows the dev-home-tools commits waiting on GitHub, and pulls them after a yes.

.DESCRIPTION
    Lists each waiting commit and the files it changes, and points to the command that shows
    every changed line. On a yes, it pulls them (fast-forward only), then runs setup.ps1 so the
    updated skills and rules take effect on this PC.

    sync.ps1 prints an UPDATE line when commits are waiting, unless autoUpdate is on in
    local-settings.json, in which case it pulls them itself.

.EXAMPLE
    pwsh -NoProfile -File .\update.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ToolsRoot = $PSScriptRoot

function Invoke-Git {
    # Runs git in dev-home-tools. Returns the exit code and the output lines.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $lines = @(& git -C $ToolsRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

function Stop-Update {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host $Text -ForegroundColor Red
    exit 1
}

$fetch = Invoke-Git -Arguments @('fetch', '--quiet')
if ($fetch.ExitCode -ne 0) { Stop-Update ('Could not reach GitHub. git: {0}' -f ($fetch.Lines -join ' ')) }

# Everything below uses this exact commit, not @{upstream}: a sync in another session can fetch
# newer commits while the question waits, and a yes pulls only what was shown.
$target = Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', '@{upstream}')
if ($target.ExitCode -ne 0) { Stop-Update 'This clone has no upstream branch to update from.' }
$commit = ($target.Lines -join '').Trim()

$counts = Invoke-Git -Arguments @('rev-list', '--left-right', '--count', "HEAD...$commit")
if ($counts.ExitCode -ne 0) { Stop-Update ('Could not compare this clone with GitHub. git: {0}' -f ($counts.Lines -join ' ')) }
$parts = @((($counts.Lines -join ' ').Trim()) -split '\s+')
$ahead = [int]$parts[0]
$behind = [int]$parts[1]
if ($behind -eq 0) {
    Write-Host 'dev-home-tools is up to date.' -ForegroundColor Green
    exit 0
}
if ($ahead -gt 0) {
    Stop-Update ('This clone has {0} commit(s) of its own, so it can''t simply move forward to GitHub''s {1} new one(s). Merge them by hand.' -f $ahead, $behind)
}

Write-Host ('{0} new commit(s) in dev-home-tools:' -f $behind)
Write-Host
(Invoke-Git -Arguments @('log', '--format=  %h %ad  %s', '--date=short', "HEAD..$commit")).Lines | ForEach-Object { Write-Host $_ }
Write-Host
Write-Host 'Files they change:'
(Invoke-Git -Arguments @('diff', '--stat', 'HEAD', $commit)).Lines | ForEach-Object { Write-Host ('  ' + $_) }
Write-Host
Write-Host ('To see every changed line first: git -C {0} diff HEAD {1}' -f $ToolsRoot.Replace('\', '/'), $commit)
Write-Host

try {
    $answer = Read-Host -Prompt 'Pull them now? [y/N]'
}
catch {
    Stop-Update 'This needs an answer, so run it in a terminal.'
}
if ($answer -notmatch '^\s*(y|yes)\s*$') {
    Write-Host 'Nothing was pulled.'
    exit 0
}

$merge = Invoke-Git -Arguments @('merge', '--ff-only', '--quiet', $commit)
if ($merge.ExitCode -ne 0) { Stop-Update ('Could not pull them. git: {0}' -f ($merge.Lines -join ' ')) }
Write-Host ('Pulled {0} commit(s). Running setup so they take effect:' -f $behind) -ForegroundColor Cyan
& ([System.Environment]::ProcessPath) -NoProfile -File (Join-Path $ToolsRoot 'setup.ps1') -Quiet
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host 'Done.' -ForegroundColor Green
