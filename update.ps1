#Requires -Version 7.2
<#
.SYNOPSIS
    Shows the dev-home-tools commits waiting on GitHub, and pulls them after a yes.

.DESCRIPTION
    Lists each waiting commit and the files it changes, and points to the command that shows
    every changed line. On a yes, it pulls them (fast-forward only), then runs setup.ps1 so the
    updated skills and rules take effect on this PC.

    Everything about dev-home-tools updates happens here: sync.ps1 runs this script with -Quiet,
    and a person runs it without. So what the user is told and what gets installed come from the
    same code.

.PARAMETER Quiet
    How sync.ps1 runs it, inside sync's own process. Never asks. Checks GitHub, then prints at
    most one line, in sync.ps1's format: OFFLINE when GitHub can't be reached, UPDATE while
    commits are waiting, or PULLED once it has pulled them, which it does only when autoUpdate is
    on in local-settings.json. Leaves setup to sync.ps1, which runs it next. Because it runs
    inside sync's process, it changes nothing the whole process shares, such as environment
    variables or the current folder.

.EXAMPLE
    pwsh -NoProfile -File .\update.ps1
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ToolsRoot = $PSScriptRoot
# Running git and printing status lines, shared with setup.ps1 and sync.ps1.
. (Join-Path $ToolsRoot 'internal/shared/git.ps1')
. (Join-Path $ToolsRoot 'internal/shared/output.ps1')
$SettingsPath = Join-Path $ToolsRoot 'local-settings.json'

function Stop-Update {
    # With -Quiet, as a PROBLEM line, so sync.ps1 reports it like its own.
    param([Parameter(Mandatory)][string]$Text)
    if ($Quiet) { Write-StatusLine -State PROBLEM -Message $Text }
    else { Write-Host $Text -ForegroundColor Red }
    exit 1
}

# Git would otherwise use any repo this folder sits in, such as a zip download unpacked inside
# another project, and offer to update that repo instead.
if (-not (Test-Path -LiteralPath (Join-Path $ToolsRoot '.git'))) {
    if ($Quiet) { exit 0 }
    Stop-Update ('{0} is not a git clone of dev-home-tools, so it can''t update itself. Clone dev-home-tools as the README shows, and use that copy instead.' -f $ToolsRoot)
}

# A clone with no upstream branch, such as a new local copy, has nothing to update from.
if ((Invoke-Git -Repo $ToolsRoot -Arguments @('rev-parse', '--verify', '--quiet', '@{upstream}')).ExitCode -ne 0) {
    if ($Quiet) { exit 0 }
    Stop-Update 'This clone has no upstream branch to update from.'
}

$fetch = Invoke-Git -Repo $ToolsRoot -Arguments @('fetch', '--quiet')
if ($fetch.ExitCode -ne 0) {
    if ($Quiet) {
        Write-StatusLine -State OFFLINE -Message ('Could not check dev-home-tools for updates. git: {0}' -f (Get-FirstLine $fetch.Err))
        exit 0
    }
    Stop-Update ('Could not reach GitHub. git: {0}' -f (Get-FirstLine ($fetch.Err + $fetch.Out)))
}

# Everything below uses this exact commit, not @{upstream}: a sync in another session can fetch
# newer commits while the question waits, and a yes pulls only what was shown.
$target = Invoke-Git -Repo $ToolsRoot -Arguments @('rev-parse', '--verify', '--quiet', '@{upstream}')
if ($target.ExitCode -ne 0) { Stop-Update ('Could not read what GitHub has for dev-home-tools. git: {0}' -f (Get-FirstLine ($target.Err + $target.Out))) }
$commit = ($target.Out -join '').Trim()

$counts = Invoke-Git -Repo $ToolsRoot -Arguments @('rev-list', '--left-right', '--count', "HEAD...$commit")
if ($counts.ExitCode -ne 0) { Stop-Update ('Could not compare dev-home-tools with GitHub. git: {0}' -f (Get-FirstLine ($counts.Err + $counts.Out))) }
$parts = @((($counts.Out -join ' ').Trim()) -split '\s+')
$ahead = [int]$parts[0]
$behind = [int]$parts[1]
if ($behind -eq 0) {
    if ($Quiet) { exit 0 }
    Write-Host 'dev-home-tools is up to date.' -ForegroundColor Green
    exit 0
}
$waiting = Format-CommitCount -Count $behind
if ($ahead -gt 0) {
    if ($Quiet) {
        Write-StatusLine -State UPDATE -Message ('{0} waiting in dev-home-tools, not installed, because this clone has {1} of its own. The user can merge them by hand.' -f $waiting, (Format-CommitCount -Count $ahead))
        exit 0
    }
    Stop-Update ('This clone has {0} commit(s) of its own, so it can''t simply move forward to GitHub''s {1} new one(s). Merge them by hand.' -f $ahead, $behind)
}

if ($Quiet) {
    # Only the user's own setting installs anything unasked. A file that can't be read counts as
    # autoUpdate off.
    $autoUpdate = $false
    try { $autoUpdate = ((Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json).autoUpdate -eq $true) } catch { $autoUpdate = $false }
    if (-not $autoUpdate) {
        Write-StatusLine -State UPDATE -Message ('{0} waiting in dev-home-tools. To see them and install them, the user runs: pwsh -NoProfile -File {1}/update.ps1' -f $waiting, $ToolsRoot.Replace('\', '/'))
        exit 0
    }
    $merge = Invoke-Git -Repo $ToolsRoot -Arguments @('merge', '--ff-only', '--quiet', $commit)
    if ($merge.ExitCode -ne 0) {
        Write-StatusLine -State UPDATE -Message ('{0} waiting in dev-home-tools, not installed. git: {1}' -f $waiting, (Get-FirstLine ($merge.Err + $merge.Out)))
        exit 0
    }
    Write-StatusLine -State PULLED -Message ('{0} to dev-home-tools.' -f $waiting)
    exit 0
}

Write-Host ('{0} new commit(s) in dev-home-tools:' -f $behind)
Write-Host
(Invoke-Git -Repo $ToolsRoot -Arguments @('log', '--format=  %h %ad  %s', '--date=short', "HEAD..$commit")).Out | ForEach-Object { Write-Host $_ }
Write-Host
Write-Host 'Files they change:'
(Invoke-Git -Repo $ToolsRoot -Arguments @('diff', '--stat', 'HEAD', $commit)).Out | ForEach-Object { Write-Host ('  ' + $_) }
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

$merge = Invoke-Git -Repo $ToolsRoot -Arguments @('merge', '--ff-only', '--quiet', $commit)
if ($merge.ExitCode -ne 0) { Stop-Update ('Could not pull them. git: {0}' -f (Get-FirstLine ($merge.Err + $merge.Out))) }
Write-Host ('Pulled {0} commit(s). Running setup so they take effect:' -f $behind) -ForegroundColor Cyan
& ([System.Environment]::ProcessPath) -NoProfile -File (Join-Path $ToolsRoot 'setup.ps1') -Quiet
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host 'Done.' -ForegroundColor Green
