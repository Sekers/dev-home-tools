#Requires -Version 7.2
<#
.SYNOPSIS
    Syncs your dev-home with GitHub, commits only the files it is given, and checks
    dev-home-tools for updates.

.DESCRIPTION
    Agents run git in dev-home only through this script, so that several sessions can use the
    handoff and knowledge skills at once. Every session on this PC shares that folder, so a file
    this script is not given may be another session's work in progress. It never stages,
    commits, stashes, resets, or discards such a file. It lists it instead, with how long ago it
    changed: LEFT, or STALE once nobody has touched it for 15 minutes.

    It finds dev-home through local-settings.json, which setup.ps1 writes. One run at a time: a
    run waits for any other run on the same dev-home to finish.

    Without -Message, it syncs: fetch, then fast-forward, or merge when two PCs both have new
    commits, then push. Git refuses a merge that would change an uncommitted file, and a merge
    that conflicts is undone at once, so nothing is lost either way. With -Message and paths, it
    first commits exactly those paths.

    Then it checks dev-home-tools for new commits. With autoUpdate on in local-settings.json, it
    pulls them (fast-forward only). Otherwise it prints an UPDATE line, and update.ps1 shows the
    commits and pulls them after a yes.

    Last, it runs setup.ps1 -Quiet, so updated skills, and skills added on another PC, are set
    up on this one.

    Exits 0 when done, including when GitHub can't be reached, and 1 when the user needs to act.

.PARAMETER Message
    The commit message for the paths, in the form "<area>: <what>".

.PARAMETER Path
    The files to commit, relative to dev-home, as separate arguments after the message. Name
    both paths of a renamed file.

.EXAMPLE
    pwsh -NoProfile -File C:/Users/you/dev-home-tools/sync.ps1

    Syncs with GitHub, and lists the files left uncommitted.

.EXAMPLE
    pwsh -NoProfile -File C:/Users/you/dev-home-tools/sync.ps1 -Message "handoff: you/tool" "handoffs/github/you/tool/HANDOFF.md"

    Commits that one file, then syncs.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Message,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'

$ToolsRoot = $PSScriptRoot
$SettingsPath = Join-Path $ToolsRoot 'local-settings.json'
# dev-home's folder, from local-settings.json.
$Root = $null
$AutoUpdate = $false
# An agent commits right after it writes, so a file nobody has touched for this long is probably
# not another session's edit in progress.
$StaleAfter = [TimeSpan]::FromMinutes(15)
$MutexWait = [TimeSpan]::FromMinutes(2)
# Tries for a git command that finds a lock held by another git process, 2 seconds apart.
$LockTries = 5

$script:UseColor = (-not [Console]::IsOutputRedirected) -and (-not $env:NO_COLOR)
$script:Problems = 0
# Set once anything about the commit or the sync is reported, so "up to date" is printed only
# when nothing else was.
$script:Reported = $false
$script:Stopped = $false
$script:GitDir = $null

function Write-Status {
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'COMMITTED', 'PULLED', 'MERGED', 'PUSHED', 'PENDING', 'OFFLINE', 'LEFT', 'STALE', 'UPDATE', 'PROBLEM')][string]$State,
        [Parameter(Mandatory)][string]$Message
    )
    if ($State -eq 'PROBLEM') { $script:Problems++ }
    if ($State -notin @('OK', 'LEFT', 'STALE', 'UPDATE')) { $script:Reported = $true }
    $label = '{0,-9} ' -f $State
    if (-not $script:UseColor) {
        Write-Output ($label + $Message)
        return
    }
    $color = switch ($State) {
        'OK' { 'Green' }
        'PROBLEM' { 'Red' }
        { $_ -in @('PENDING', 'OFFLINE', 'STALE', 'UPDATE') } { 'Yellow' }
        default { 'Cyan' }
    }
    Write-Host $label -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Invoke-Git {
    # Runs git in a repo, dev-home unless -Repo says otherwise. Returns the exit code and the
    # output and error lines. A command that finds a lock held by another git process is tried
    # again; a lock file is never deleted.
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Repo = $Root
    )
    $ErrorActionPreference = 'Continue'
    for ($try = 1; ; $try++) {
        $out = [System.Collections.Generic.List[string]]::new()
        $err = [System.Collections.Generic.List[string]]::new()
        & git -C $Repo @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add($_.ToString()) }
            else { $out.Add([string]$_) }
        }
        $code = $LASTEXITCODE
        $locked = ($code -ne 0) -and (($err -join "`n") -match "Unable to create '[^']*\.lock'|cannot lock ref|index\.lock")
        if ((-not $locked) -or ($try -ge $LockTries)) {
            return [pscustomobject]@{ ExitCode = $code; Out = $out.ToArray(); Err = $err.ToArray(); Locked = $locked }
        }
        Start-Sleep -Seconds 2
    }
}

function Get-FirstLine {
    param([AllowNull()][string[]]$Lines)
    foreach ($line in @($Lines)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { return $line.Trim() }
    }
    return '(no message)'
}

function Format-CommitCount {
    param([int]$Count)
    if ($Count -eq 1) { return '1 commit' }
    return ('{0} commits' -f $Count)
}

function Format-Age {
    param([TimeSpan]$Age)
    if ($Age.TotalMinutes -lt 1) { return 'under a minute ago' }
    if ($Age.TotalHours -lt 1) { return ('{0} min ago' -f [int][math]::Floor($Age.TotalMinutes)) }
    if ($Age.TotalDays -lt 2) { return ('{0} h ago' -f [int][math]::Floor($Age.TotalHours)) }
    return ('{0} days ago' -f [int][math]::Floor($Age.TotalDays))
}

function Write-Busy {
    param([Parameter(Mandatory)]$Result)
    Write-Status -State PROBLEM -Message ('Another git process kept dev-home locked through {0} tries, so this step was skipped. If no git is running, one that stopped partway left a lock file behind; ask the user before deleting it. git: {1}' -f $LockTries, (Get-FirstLine $Result.Err))
}

function Get-AheadBehind {
    param([string]$Repo = $Root)
    $counts = Invoke-Git -Repo $Repo -Arguments @('rev-list', '--left-right', '--count', 'HEAD...@{upstream}')
    if ($counts.ExitCode -ne 0) { return $null }
    $parts = @((($counts.Out -join ' ').Trim()) -split '\s+')
    return [pscustomobject]@{ Ahead = [int]$parts[0]; Behind = [int]$parts[1] }
}

function Invoke-Commit {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$CommitMessage
    )
    $list = $Paths -join ', '
    $add = Invoke-Git -Arguments (@('--literal-pathspecs', 'add', '--') + $Paths)
    if ($add.ExitCode -ne 0) {
        $script:Stopped = $true
        if ($add.Locked) { Write-Busy -Result $add; return }
        Write-Status -State PROBLEM -Message ('Could not stage {0}, so nothing was committed. git: {1}' -f $list, (Get-FirstLine $add.Err))
        return
    }
    $staged = Invoke-Git -Arguments (@('--literal-pathspecs', 'diff', '--cached', '--quiet', '--') + $Paths)
    if ($staged.ExitCode -eq 0) {
        Write-Status -State OK -Message ('Nothing to commit: {0} already match the last commit.' -f $list)
        return
    }
    # With paths, git commits only those paths, and anything another session staged stays out.
    $commit = Invoke-Git -Arguments (@('--literal-pathspecs', 'commit', '--quiet', '-m', $CommitMessage, '--') + $Paths)
    if ($commit.ExitCode -ne 0) {
        $script:Stopped = $true
        # git add staged the paths, and a merge refuses while anything is staged. This puts only
        # their index entries back to the last commit; the files keep their changes.
        $unstage = Invoke-Git -Arguments (@('--literal-pathspecs', 'restore', '--staged', '--') + $Paths)
        if ($commit.Locked) {
            Write-Busy -Result $commit
        }
        else {
            Write-Status -State PROBLEM -Message ('Could not commit {0}. git: {1}' -f $list, (Get-FirstLine ($commit.Err + $commit.Out)))
        }
        if ($unstage.ExitCode -ne 0) {
            Write-Status -State PROBLEM -Message ('{0} stayed staged, and git refuses to merge while anything is staged. Ask the user. git: {1}' -f $list, (Get-FirstLine $unstage.Err))
        }
        return
    }
    Write-Status -State COMMITTED -Message ('"{0}" ({1})' -f $CommitMessage, $list)
}

function Merge-Upstream {
    param([int]$Ahead, [int]$Behind)
    if ($Ahead -eq 0) {
        $merge = Invoke-Git -Arguments @('merge', '--ff-only', '--quiet', '@{upstream}')
        if ($merge.ExitCode -eq 0) {
            Write-Status -State PULLED -Message ('{0} from GitHub.' -f (Format-CommitCount -Count $Behind))
            return
        }
    }
    else {
        $merge = Invoke-Git -Arguments @('merge', '--no-edit', '--quiet', '-m', 'sync: merge another PC''s commits', '@{upstream}')
        if ($merge.ExitCode -eq 0) {
            Write-Status -State MERGED -Message ('{0} from GitHub, with a merge commit, because two PCs had new commits.' -f (Format-CommitCount -Count $Behind))
            return
        }
    }
    $script:Stopped = $true
    if ($merge.Locked) { Write-Busy -Result $merge; return }
    if (Test-Path -LiteralPath (Join-Path $script:GitDir 'MERGE_HEAD')) {
        $conflicts = @((Invoke-Git -Arguments @('diff', '--name-only', '--diff-filter=U')).Out)
        $abort = Invoke-Git -Arguments @('merge', '--abort')
        if ($abort.ExitCode -eq 0) {
            Write-Status -State PROBLEM -Message ('Two PCs changed {0}. The merge was undone, and this PC''s commits are safe. Ask the user how to combine the two versions.' -f ($conflicts -join ', '))
        }
        else {
            Write-Status -State PROBLEM -Message ('Two PCs changed {0}, and undoing the merge failed, so a merge is still in progress in dev-home. Ask the user. git: {1}' -f ($conflicts -join ', '), (Get-FirstLine $abort.Err))
        }
        return
    }
    # Git lists the files that stopped it on indented lines.
    $files = @(@($merge.Err) + @($merge.Out) | Where-Object { $_ -match '^\s+\S' } | ForEach-Object { $_.Trim() })
    if ($files.Count -gt 0) {
        Write-Status -State PROBLEM -Message ('Git won''t bring in the commits from GitHub while these files have uncommitted changes here: {0}. Nothing was changed. Once they are committed, sync again.' -f ($files -join ', '))
    }
    else {
        Write-Status -State PROBLEM -Message ('Could not bring in the commits from GitHub. Nothing was changed. git: {0}' -f (Get-FirstLine (@($merge.Err) + @($merge.Out))))
    }
}

function Sync-Remote {
    # A push rejected because GitHub moved on gets one more round of fetch, merge, and push.
    for ($round = 1; $round -le 2; $round++) {
        $fetch = Invoke-Git -Arguments @('fetch', '--quiet')
        if ($fetch.ExitCode -ne 0) {
            if ($fetch.Locked) { Write-Busy -Result $fetch; return }
            Write-Status -State OFFLINE -Message ('Could not reach GitHub, so this copy may be behind. git: {0}' -f (Get-FirstLine $fetch.Err))
            $counts = Get-AheadBehind
            if (($null -ne $counts) -and ($counts.Ahead -gt 0)) {
                Write-Status -State PENDING -Message ('{0} not pushed yet. The next sync pushes it.' -f (Format-CommitCount -Count $counts.Ahead))
            }
            return
        }
        $counts = Get-AheadBehind
        if ($null -eq $counts) {
            Write-Status -State PROBLEM -Message 'Could not compare with GitHub, because this branch has no upstream branch.'
            return
        }
        if ($counts.Behind -gt 0) {
            Merge-Upstream -Ahead $counts.Ahead -Behind $counts.Behind
            if ($script:Stopped) {
                if ($counts.Ahead -gt 0) {
                    Write-Status -State PENDING -Message ('{0} not pushed yet.' -f (Format-CommitCount -Count $counts.Ahead))
                }
                return
            }
            $counts = Get-AheadBehind
        }
        if ($counts.Ahead -eq 0) { return }
        $push = Invoke-Git -Arguments @('push', '--quiet')
        if ($push.ExitCode -eq 0) {
            Write-Status -State PUSHED -Message ('{0} to GitHub.' -f (Format-CommitCount -Count $counts.Ahead))
            return
        }
        if (($round -eq 1) -and (($push.Err -join "`n") -match 'rejected|fetch first|non-fast-forward')) { continue }
        Write-Status -State PENDING -Message ('{0} not pushed yet. The next sync pushes it. git: {1}' -f (Format-CommitCount -Count $counts.Ahead), (Get-FirstLine $push.Err))
        return
    }
}

function Write-Uncommitted {
    $status = Invoke-Git -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if ($status.ExitCode -ne 0) {
        Write-Status -State PROBLEM -Message ('Could not list uncommitted files. git: {0}' -f (Get-FirstLine $status.Err))
        return
    }
    $fields = ($status.Out -join "`n").Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $entry = $fields[$i]
        if ($entry.Length -lt 4) { continue }
        $x = [string]$entry[0]
        $y = [string]$entry[1]
        $file = $entry.Substring(3)
        $kind = 'changed'
        if ($x -eq '?') { $kind = 'new file' }
        elseif (($x -in @('R', 'C')) -or ($y -in @('R', 'C'))) {
            # A rename is followed by the name it had before.
            $i++
            $kind = 'renamed from ' + $fields[$i]
        }
        elseif (($x -eq 'D') -or ($y -eq 'D')) { $kind = 'deleted' }
        elseif ($x -eq 'A') { $kind = 'new file' }
        if (($x -ne ' ') -and ($x -ne '?')) { $kind += ', staged' }

        # A deleted file has no time of its own, so use its folder's, which changes when an
        # entry is removed.
        $age = $null
        $full = Join-Path $Root $file
        foreach ($candidate in @($full, (Split-Path -Parent $full))) {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                $age = (Get-Date) - $item.LastWriteTime
                break
            }
        }
        if ($null -eq $age) {
            Write-Status -State STALE -Message ('{0} ({1}, age unknown)' -f $file, $kind)
        }
        elseif ($age -ge $StaleAfter) {
            Write-Status -State STALE -Message ('{0} ({1}, {2})' -f $file, $kind, (Format-Age $age))
        }
        else {
            Write-Status -State LEFT -Message ('{0} ({1}, {2})' -f $file, $kind, (Format-Age $age))
        }
    }
}

function Update-Tools {
    # Checks dev-home-tools for new commits on GitHub. Pulls them, fast-forward only, when this
    # PC's autoUpdate setting is on. Otherwise says they are waiting.
    if (-not (Test-Path -LiteralPath (Join-Path $ToolsRoot '.git'))) { return }
    # A clone with no upstream branch, such as a new local copy, has nothing to update from.
    if ((Invoke-Git -Repo $ToolsRoot -Arguments @('rev-parse', '--abbrev-ref', '@{upstream}')).ExitCode -ne 0) { return }
    $fetch = Invoke-Git -Repo $ToolsRoot -Arguments @('fetch', '--quiet')
    if ($fetch.ExitCode -ne 0) {
        Write-Status -State OFFLINE -Message ('Could not check dev-home-tools for updates. git: {0}' -f (Get-FirstLine $fetch.Err))
        return
    }
    $counts = Get-AheadBehind -Repo $ToolsRoot
    if (($null -eq $counts) -or ($counts.Behind -eq 0)) { return }
    $commits = Format-CommitCount -Count $counts.Behind
    $update = 'pwsh -NoProfile -File {0}/update.ps1' -f $ToolsRoot.Replace('\', '/')
    if (-not $AutoUpdate) {
        Write-Status -State UPDATE -Message ('{0} waiting in dev-home-tools. To see them and pull them, the user runs: {1}' -f $commits, $update)
        return
    }
    if ($counts.Ahead -gt 0) {
        Write-Status -State UPDATE -Message ('{0} waiting in dev-home-tools, not pulled, because this clone has {1} of its own. The user can merge them by hand.' -f $commits, (Format-CommitCount -Count $counts.Ahead))
        return
    }
    $merge = Invoke-Git -Repo $ToolsRoot -Arguments @('merge', '--ff-only', '--quiet', '@{upstream}')
    if ($merge.ExitCode -ne 0) {
        Write-Status -State UPDATE -Message ('{0} waiting in dev-home-tools, not pulled. git: {1}' -f $commits, (Get-FirstLine $merge.Err))
        return
    }
    Write-Status -State PULLED -Message ('{0} to dev-home-tools.' -f $commits)
}

function Invoke-Setup {
    $setup = Join-Path $ToolsRoot 'setup.ps1'
    # In its own process, so that its settings and its exit can't reach this script. It prints
    # its own PROBLEM lines.
    & ([System.Environment]::ProcessPath) -NoProfile -File $setup -Quiet
    if ($LASTEXITCODE -ne 0) { $script:Problems++ }
}

function Invoke-Run {
    param(
        [string[]]$Paths,
        [string]$CommitMessage
    )
    $markers = [ordered]@{
        'MERGE_HEAD'       = 'A merge'
        'rebase-merge'     = 'A rebase'
        'rebase-apply'     = 'A rebase'
        'CHERRY_PICK_HEAD' = 'A cherry-pick'
        'REVERT_HEAD'      = 'A revert'
    }
    foreach ($name in $markers.Keys) {
        if (Test-Path -LiteralPath (Join-Path $script:GitDir $name)) {
            Write-Status -State PROBLEM -Message ('{0} is in progress in dev-home, perhaps left by a git command that stopped partway. Nothing was changed. Ask the user to finish or abort it.' -f $markers[$name])
            return
        }
    }
    if ($Paths.Count -gt 0) {
        Invoke-Commit -Paths $Paths -CommitMessage $CommitMessage
        if ($script:Stopped) { return }
    }
    Sync-Remote
    if (-not $script:Reported) {
        Write-Status -State OK -Message 'dev-home is up to date with GitHub.'
    }
    Write-Uncommitted
    Update-Tools
    Invoke-Setup
}

# ---------------------------------------------------------------------------------------------

try {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        Write-Status -State PROBLEM -Message ('dev-home-tools is not set up on this PC yet. The user runs {0} once in a terminal.' -f (Join-Path $ToolsRoot 'setup.ps1'))
        exit 1
    }
    $settings = $null
    try { $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json } catch { $settings = $null }
    if (($null -eq $settings) -or (-not ($settings.contentDir -is [string])) -or (-not $settings.contentDir)) {
        Write-Status -State PROBLEM -Message ('{0} has no dev-home folder. The user runs {1} once in a terminal.' -f $SettingsPath, (Join-Path $ToolsRoot 'setup.ps1'))
        exit 1
    }
    $Root = [System.IO.Path]::GetFullPath($settings.contentDir)
    $AutoUpdate = ($settings.autoUpdate -eq $true)

    $rootFull = $Root.TrimEnd('\', '/')
    $commitPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $full = [System.IO.Path]::GetFullPath($value, $rootFull)
        if (-not $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Status -State PROBLEM -Message ('{0} is not inside dev-home ({1}).' -f $value, $rootFull)
            continue
        }
        # A folder would take in every file under it, including another session's new files.
        if (Test-Path -LiteralPath $full -PathType Container) {
            Write-Status -State PROBLEM -Message ('{0} is a folder. Name each file to commit.' -f $value)
            continue
        }
        $relative = $full.Substring($rootFull.Length + 1).Replace('\', '/')
        if ($commitPaths -notcontains $relative) { $commitPaths.Add($relative) }
    }
    if ($script:Problems -eq 0) {
        if ($Message -and ($commitPaths.Count -eq 0)) {
            Write-Status -State PROBLEM -Message 'Name the files to commit after -Message.'
        }
        elseif ((-not $Message) -and ($commitPaths.Count -gt 0)) {
            Write-Status -State PROBLEM -Message 'Give a commit message with -Message "<area>: <what>".'
        }
        elseif ($Message -and ($Message -notmatch '^[^\s:]+: \S')) {
            Write-Status -State PROBLEM -Message ('Commit messages read "<area>: <what>", for example "handoff: my-project". Got: {0}' -f $Message)
        }
    }
    if ($script:Problems -gt 0) { exit 1 }

    $gitDirResult = Invoke-Git -Arguments @('rev-parse', '--absolute-git-dir')
    if ($gitDirResult.ExitCode -ne 0) {
        Write-Status -State PROBLEM -Message ('{0} is not a git repo. git: {1}' -f $rootFull, (Get-FirstLine $gitDirResult.Err))
        exit 1
    }
    $script:GitDir = Get-FirstLine $gitDirResult.Out

    # One run at a time on this dev-home. The name comes from the folder's path, because a mutex
    # name can't hold one.
    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($rootFull.ToLowerInvariant())))
    $mutex = [System.Threading.Mutex]::new($false, ('Local\dev-home-sync-' + $hash.Substring(0, 16)))
    $owned = $false
    try {
        try {
            $owned = $mutex.WaitOne($MutexWait)
        }
        catch {
            # A run that stopped partway leaves the mutex abandoned. Waiting still takes it.
            $abandoned = ($_.Exception -is [System.Threading.AbandonedMutexException]) -or ($_.Exception.InnerException -is [System.Threading.AbandonedMutexException])
            if (-not $abandoned) { throw }
            $owned = $true
        }
        if ($owned) {
            Invoke-Run -Paths $commitPaths.ToArray() -CommitMessage $Message
        }
        else {
            Write-Status -State PROBLEM -Message ('Another sync in dev-home has been running for {0} minutes. Try again shortly, and if it keeps happening, ask the user.' -f $MutexWait.TotalMinutes)
        }
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
catch {
    Write-Status -State PROBLEM -Message ('sync.ps1 stopped: {0}' -f $_.Exception.Message)
}

if ($script:Problems -gt 0) { exit 1 }
exit 0
