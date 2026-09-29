#Requires -Version 7.2
<#
.SYNOPSIS
    Sets up dev-home-tools on this PC: finds or creates your dev-home, fills in the skills and
    rules with this PC's paths, links them into Claude Code and Codex, and checks the settings
    they need.

.DESCRIPTION
    Safe to run any number of times. It rewrites only its own generated files, creates missing
    links, replaces links whose target is gone, removes links it made to skills that no longer
    exist, and reports anything else without changing it.

    On the first run it asks where your dev-home is (the private repo that holds your handoffs
    and knowledge base), and saves the answer in local-settings.json next to this script. If
    that folder doesn't exist yet, it offers to clone your dev-home from GitHub, or to create a
    new private one from the files in starter/.

    The skills and core rules in this repo hold placeholders where paths go. Setup writes copies
    with this PC's paths filled in to .generated/, and links those into the tools. Pre-approved
    commands must match the command text exactly, so the paths can't be variables.

    When a settings file is missing something, it shows the exact lines it would change and asks
    first. On yes, it saves a dated backup of the file, then writes the change. It never edits a
    file it can't fully parse (a settings.json with comments, for example); it prints what to add
    by hand instead.

    Run it by hand once per PC. After that, sync.ps1 runs it with -Quiet after every sync, so
    changes to the skills, and skills added on another PC, reach this one.

    Claude Code gets the links in ~/.claude, in each folder listed under claudeConfigDirs in
    local-settings.json (one per extra Claude account; the first run offers each ~/.claude-*
    folder it finds), and in the folder in CLAUDE_CONFIG_DIR when that's set. Codex gets them
    when it's installed.

    Folder links are symbolic links when Windows Developer Mode is on, and directory junctions
    otherwise.

    For testing, tests/Invoke-Tests.ps1 runs a throwaway copy of this repo whose
    local-settings.json sets testHomeDir. Setup then uses that folder instead of your profile, and
    says so on every run. Setup never writes testHomeDir itself.

.PARAMETER Quiet
    Print only changes and problems. Prints nothing when everything is already in place. Never
    asks anything, because agents run setup this way: anything that needs an answer is reported
    instead.

.PARAMETER ContentDir
    Your dev-home folder. Saved in local-settings.json, so later runs don't need it.

.EXAMPLE
    pwsh -NoProfile -File .\setup.ps1 -WhatIf

    Shows what it would change, without changing anything.

.EXAMPLE
    pwsh -NoProfile -File .\setup.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Quiet,
    [string]$ContentDir
)

$ErrorActionPreference = 'Stop'

# Codex joins its global AGENTS.md with the project's AGENTS.md files and stops reading at
# project_doc_max_bytes, 32 KiB by default. The global file comes first, so the cut would fall on
# the project's own instructions, without a warning. Twice the default leaves room for long
# project files.
$CodexDocBytes = 65536

# Files whose placeholders setup fills in. Any other file is copied as it is.
$TextExtensions = @('.md', '.txt', '.json', '.toml', '.yml', '.yaml', '.ps1', '.py', '.sh')

# The start of the Codex rules file that setup writes. Setup only ever replaces a file that
# starts with it.
$CodexMarker = '<!-- Written by dev-home-tools setup.ps1'

$ToolsRoot = $PSScriptRoot
$SettingsPath = Join-Path $ToolsRoot 'local-settings.json'
$GeneratedRoot = Join-Path $ToolsRoot '.generated'
# The profile folder to set up: yours, unless local-settings.json sets testHomeDir.
$HomeDir = $HOME
$script:Cmdlet = $PSCmdlet
$script:Problems = [System.Collections.Generic.List[string]]::new()
$script:UnknownPlaceholders = [System.Collections.Generic.List[string]]::new()
$script:GeneratedChanges = 0

# Color only when a person is watching the console. Agents run setup with its output
# redirected, so they get plain text. NO_COLOR turns color off too.
$script:UseColor = (-not [Console]::IsOutputRedirected) -and (-not $env:NO_COLOR)

function Write-Line {
    param(
        [AllowEmptyString()][string]$Text = '',
        [string]$Color = ''
    )
    if (-not $script:UseColor) {
        Write-Output $Text
    }
    elseif ($Color) {
        Write-Host $Text -ForegroundColor $Color
    }
    else {
        Write-Host $Text
    }
}

function Write-Status {
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'TEST', 'LINKED', 'REMOVED', 'WROTE', 'CREATED', 'SET', 'CHANGE', 'PROBLEM')][string]$State,
        [Parameter(Mandatory)][string]$Message
    )
    if ($State -eq 'PROBLEM') { $script:Problems.Add($Message) }
    if ($Quiet -and ($State -eq 'OK')) { return }
    $label = '{0,-8} ' -f $State
    if (-not $script:UseColor) {
        Write-Output ($label + $Message)
        return
    }
    $color = switch ($State) {
        'OK' { 'Green' }
        { $_ -in @('CHANGE', 'TEST') } { 'Yellow' }
        'PROBLEM' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host $label -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Exit-Setup {
    # Prints the summary and exits: 0 when there were no problems, 1 otherwise.
    if ($WhatIfPreference -and (-not $Quiet)) {
        Write-Line
        Write-Line -Text 'This was a preview (-WhatIf). Nothing was changed.' -Color Yellow
    }
    if ($script:Problems.Count -eq 0) {
        if (-not ($Quiet -or $WhatIfPreference)) {
            Write-Line
            Write-Line -Text 'All checks passed.' -Color Green
        }
        exit 0
    }
    if (-not $Quiet) {
        Write-Line
        Write-Line -Text ('{0} problem(s) to fix. Run setup.ps1 again afterward.' -f $script:Problems.Count) -Color Red
    }
    exit 1
}

function Invoke-Tool {
    # Runs a program without printing its output. Returns the exit code and the output lines.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $ErrorActionPreference = 'Continue'
    $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

function Get-FirstLine {
    param([AllowNull()][string[]]$Lines)
    foreach ($line in @($Lines)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { return $line.Trim() }
    }
    return '(no message)'
}

function Read-Answer {
    # Asks a question and returns the answer, or the default when the answer is blank. Returns
    # $null when no one can answer: with -Quiet, or when input is redirected.
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Default = ''
    )
    if ($Quiet -or [Console]::IsInputRedirected) { return $null }
    $prompt = if ($Default) { '{0} [{1}]' -f $Question, $Default } else { $Question }
    try {
        $answer = Read-Host -Prompt $prompt
    }
    catch {
        return $null   # pwsh -NonInteractive can't ask
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Confirm-Change {
    # Asks a yes/no question and returns $true only for yes. Never asks with -Quiet, or when no one
    # can answer because input is redirected.
    param([Parameter(Mandatory)][string]$Question)
    if ($Quiet -or [Console]::IsInputRedirected) { return $false }
    try {
        $answer = Read-Host -Prompt ($Question + ' [y/N]')
    }
    catch {
        return $false   # pwsh -NonInteractive can't ask
    }
    return ($answer -match '^\s*(y|yes)\s*$')
}

# ---------------------------------------------------------------------------------------------
# Paths

function ConvertTo-ComparablePath {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path
    foreach ($prefix in @('\\?\', '\??\')) {
        if ($p.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $p = $p.Substring($prefix.Length)
        }
    }
    $p = [System.IO.Path]::GetFullPath($p)
    return $p.TrimEnd([char[]]@('\', '/'))
}

function ConvertTo-ForwardPath {
    # The full path with forward slashes, as the skills' commands use it.
    param([Parameter(Mandatory)][string]$Path)
    return (ConvertTo-ComparablePath -Path $Path).Replace('\', '/')
}

function Resolve-HomePath {
    # Expands a leading ~ to the profile folder being set up.
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '^~([\\/]|$)') { return (Join-Path $HomeDir $Path.Substring(1).TrimStart('\', '/')) }
    return $Path
}

function Test-SafePath {
    # Returns why a folder can't be written into the skills' commands, or $null when it can.
    # Setup writes the paths into commands and pre-approvals as they are, unquoted, so they may
    # hold only characters that need no quoting in Git Bash or PowerShell.
    param([Parameter(Mandatory)][string]$Path)
    # A root turns into "C:" once its trailing slash is trimmed, and "C:" means the current folder
    # on that drive.
    if ($Path -match '^[A-Za-z]:[\\/]*$') { return 'is the root of a drive' }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return 'is not a full path on a drive, such as C:/Users/you/dev-home' }
    if ($Path.Substring(2) -match '[^A-Za-z0-9_.@\\/-]') { return 'has a space or another character that commands would need quoted' }
    return $null
}

# ---------------------------------------------------------------------------------------------
# This PC's settings, in local-settings.json

function Read-LocalSettings {
    # Returns this PC's saved settings, with defaults for anything missing. IsNew is $true when
    # there is no file yet. Exits when the file can't be read, rather than guess.
    $settings = [pscustomobject]@{ contentDir = ''; autoUpdate = $false; claudeConfigDirs = @(); testHomeDir = ''; IsNew = $true }
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return $settings }
    try {
        $saved = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Status -State PROBLEM -Message ('{0} could not be read as JSON. Fix it, or delete it and answer the questions again, then run setup.ps1 again.' -f $SettingsPath)
        Exit-Setup
    }
    $settings.IsNew = $false
    if ($null -eq $saved) { return $settings }
    if ($saved.contentDir -is [string]) { $settings.contentDir = $saved.contentDir }
    $settings.autoUpdate = ($saved.autoUpdate -eq $true)
    $settings.claudeConfigDirs = @($saved.claudeConfigDirs | Where-Object { ($_ -is [string]) -and $_ })
    if ($saved.testHomeDir -is [string]) { $settings.testHomeDir = $saved.testHomeDir }
    return $settings
}

function Save-LocalSettings {
    # Writes the settings back. testHomeDir is kept when the file has it, and never added.
    param([Parameter(Mandatory)][pscustomobject]$Settings)
    $data = [ordered]@{
        contentDir       = $Settings.contentDir
        autoUpdate       = [bool]$Settings.autoUpdate
        claudeConfigDirs = @($Settings.claudeConfigDirs)
    }
    if ($Settings.testHomeDir) { $data['testHomeDir'] = $Settings.testHomeDir }
    $json = $data | ConvertTo-Json
    [System.IO.File]::WriteAllText($SettingsPath, ($json.Replace("`r`n", "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------------------------
# Generated files

function Get-RenderedBytes {
    # A file's bytes, with the placeholders filled in for the file types in $TextExtensions. Line
    # breaks in those become LF. A placeholder setup doesn't know is noted for the summary.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    if ($TextExtensions -notcontains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        return , [System.IO.File]::ReadAllBytes($Path)
    }
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    foreach ($key in $Values.Keys) { $text = $text.Replace('{{' + $key + '}}', $Values[$key]) }
    foreach ($match in [regex]::Matches($text, '\{\{[A-Z_]+\}\}')) {
        $script:UnknownPlaceholders.Add(('{0} ({1})' -f $Path, $match.Value))
    }
    return , [System.Text.UTF8Encoding]::new($false).GetBytes($text)
}

function Test-SameBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    $current = [System.IO.File]::ReadAllBytes($Path)
    return ($current.Length -eq $Bytes.Length) -and ([Convert]::ToBase64String($current) -ceq [Convert]::ToBase64String($Bytes))
}

function Sync-GeneratedFolder {
    # Makes Destination hold exactly the files in Source, with the placeholders filled in. With no
    # Source, empties Destination and removes it. Counts each file written or removed in
    # $script:GeneratedChanges.
    param(
        [string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $sourceFiles = @()
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Source) {
        $sourceFiles = @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)
        foreach ($file in $sourceFiles) { [void]$wanted.Add([System.IO.Path]::GetRelativePath($Source, $file.FullName)) }
    }

    # Old files and empty folders go first, so that a path that was a folder can become a file,
    # and the other way around.
    if (Test-Path -LiteralPath $Destination) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Destination -File -Recurse -Force)) {
            if ($wanted.Contains([System.IO.Path]::GetRelativePath($Destination, $file.FullName))) { continue }
            if (-not $script:Cmdlet.ShouldProcess($file.FullName, 'Remove a generated file whose template is gone')) { continue }
            Remove-Item -LiteralPath $file.FullName -Force
            $script:GeneratedChanges++
        }
        # Empty folders, deepest first. Setup made every folder in here; none is a link.
        $folders = @(Get-ChildItem -LiteralPath $Destination -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)
        if (-not $Source) { $folders += Get-Item -LiteralPath $Destination }
        foreach ($folder in $folders) {
            if (@(Get-ChildItem -LiteralPath $folder.FullName -Force).Count -gt 0) { continue }
            if ($script:Cmdlet.ShouldProcess($folder.FullName, 'Remove an empty generated folder')) {
                Remove-Item -LiteralPath $folder.FullName -Force
            }
        }
    }

    foreach ($file in $sourceFiles) {
        $target = Join-Path $Destination ([System.IO.Path]::GetRelativePath($Source, $file.FullName))
        $bytes = Get-RenderedBytes -Path $file.FullName -Values $Values
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Test-SameBytes -Path $target -Bytes $bytes)) { continue }
        if (-not $script:Cmdlet.ShouldProcess($target, 'Write a generated file')) { continue }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($target, $bytes)
        $script:GeneratedChanges++
    }
}

# ---------------------------------------------------------------------------------------------
# dev-home itself

function Initialize-ContentRepo {
    # Offers to clone the person's dev-home from GitHub, or to create a new private one from
    # starter/. The caller checks the folder afterward.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    if ($Quiet -or [Console]::IsInputRedirected) {
        Write-Status -State PROBLEM -Message ('There is no dev-home at {0}. Run setup.ps1 in a terminal without -Quiet, and it offers to clone yours from GitHub or create a new one.' -f $Path)
        return
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Status -State PROBLEM -Message ('There is no dev-home at {0}, and cloning or creating one needs the GitHub CLI (gh). Install it, sign in with gh auth login, then run setup.ps1 again.' -f $Path)
        return
    }
    if ((Invoke-Tool -FilePath 'gh' -Arguments @('auth', 'status')).ExitCode -ne 0) {
        Write-Status -State PROBLEM -Message ('There is no dev-home at {0}, and the GitHub CLI is not signed in. Run gh auth login, then run setup.ps1 again.' -f $Path)
        return
    }

    Write-Line -Text ('There is no dev-home at {0} yet.' -f $Path)
    $choice = Read-Answer -Question 'Clone your existing dev-home from GitHub (c), create a new private one (n), or stop here (s)?' -Default 's'
    if ($choice -match '^\s*(c|clone)\s*$') {
        $name = Read-Answer -Question 'Your dev-home repo on GitHub: owner/name, or just the name if it is under your account' -Default 'dev-home'
        if (-not $script:Cmdlet.ShouldProcess($Path, ('Clone {0} from GitHub' -f $name))) { return }
        $clone = Invoke-Tool -FilePath 'gh' -Arguments @('repo', 'clone', $name, $Path)
        if ($clone.ExitCode -ne 0) {
            Write-Status -State PROBLEM -Message ('Could not clone {0}. gh: {1}' -f $name, (Get-FirstLine $clone.Lines))
            return
        }
        Write-Status -State CREATED -Message ('Cloned {0} into {1}' -f $name, $Path)
        return
    }
    if ($choice -notmatch '^\s*(n|new)\s*$') {
        Write-Status -State PROBLEM -Message ('Stopped: there is no dev-home at {0} yet.' -f $Path)
        return
    }

    $name = Read-Answer -Question 'Name for the new private repo on GitHub' -Default 'dev-home'
    if (-not $script:Cmdlet.ShouldProcess($Path, ('Create a private repo named {0} on GitHub, from starter/' -f $name))) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $starterRoot = Join-Path $ToolsRoot 'starter'
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $starterRoot -File -Recurse -Force)) {
        $relative = [System.IO.Path]::GetRelativePath($starterRoot, $file.FullName)
        $target = Join-Path $Path $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($target, (Get-RenderedBytes -Path $file.FullName -Values $Values))
        $files.Add($relative.Replace('\', '/'))
    }
    $steps = @(
        , @('init', '--quiet', '-b', 'main')
        , @('config', '--local', 'commit.gpgsign', 'false')
        , @('config', '--local', 'pull.rebase', 'false')
        , (@('add', '--') + $files)
        , @('commit', '--quiet', '-m', 'starter: new dev-home')
    )
    foreach ($step in $steps) {
        $git = Invoke-Tool -FilePath 'git' -Arguments (@('-C', $Path) + $step)
        if ($git.ExitCode -ne 0) {
            Write-Status -State PROBLEM -Message ('Could not set up the repo in {0}: git {1} failed. git: {2}' -f $Path, $step[0], (Get-FirstLine $git.Lines))
            return
        }
    }
    $create = Invoke-Tool -FilePath 'gh' -Arguments @('repo', 'create', $name, '--private', '--source', $Path, '--remote', 'origin', '--push')
    if ($create.ExitCode -ne 0) {
        Write-Status -State PROBLEM -Message ('Created dev-home in {0}, but not on GitHub. gh: {1}. Once that is fixed, run: gh repo create {2} --private --source {0} --remote origin --push' -f $Path, (Get-FirstLine $create.Lines), $name)
        return
    }
    Write-Status -State CREATED -Message ('New private repo {0} on GitHub, with this PC''s copy in {1}' -f $name, $Path)
}

# ---------------------------------------------------------------------------------------------
# Links

function Get-LinkTargetOrNull {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Info)
    try { return $Info.LinkTarget } catch { return $null }
}

function Get-LinkInfo {
    # Returns $null when nothing exists at $Path. Otherwise returns IsLink, and Target when it
    # is a link. A link whose target is missing still counts as a link.
    param([Parameter(Mandatory)][string]$Path)
    $dirInfo = [System.IO.DirectoryInfo]::new($Path)
    $fileInfo = [System.IO.FileInfo]::new($Path)
    $target = Get-LinkTargetOrNull -Info $dirInfo
    if ($null -eq $target) { $target = Get-LinkTargetOrNull -Info $fileInfo }
    if ($null -ne $target) {
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path -Parent $Path) $target
        }
        return [pscustomobject]@{ IsLink = $true; Target = (ConvertTo-ComparablePath -Path $target) }
    }
    if ($dirInfo.Exists -or $fileInfo.Exists) {
        return [pscustomobject]@{ IsLink = $false; Target = $null }
    }
    return $null
}

function New-FolderLink {
    # Creates a symbolic link to a folder, falling back to a junction. Returns the kind made.
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath
    )
    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath | Out-Null
        return 'symlink'
    }
    catch {
        if (-not $IsWindows) { throw }
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
        return 'junction'
    }
}

function Remove-FolderLink {
    # Removes a folder link without touching its target. Remove-Item -Recurse would follow a
    # junction and delete the target's files, so it is never used here.
    param([Parameter(Mandatory)][string]$LinkPath)
    if ($IsWindows) {
        & cmd.exe /d /c rmdir $LinkPath
        if ($LASTEXITCODE -ne 0) { throw "rmdir exited with code $LASTEXITCODE." }
    }
    else {
        [System.IO.File]::Delete($LinkPath)
    }
}

function Sync-Link {
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Label
    )
    $existing = Get-LinkInfo -Path $LinkPath
    $wantedTarget = ConvertTo-ComparablePath -Path $TargetPath

    # A link whose target is gone has nothing to lose, such as one left from an older layout.
    if (($null -ne $existing) -and $existing.IsLink -and ($existing.Target -ne $wantedTarget) -and
        (-not (Test-Path -LiteralPath $existing.Target))) {
        if (-not $script:Cmdlet.ShouldProcess($LinkPath, ('Replace a link to {0}, which is gone' -f $existing.Target))) { return }
        try {
            Remove-FolderLink -LinkPath $LinkPath
            $existing = $null
        }
        catch {
            Write-Status -State PROBLEM -Message ('{0}: could not remove the broken link {1}. {2}' -f $Label, $LinkPath, $_.Exception.Message)
            return
        }
    }

    if ($null -eq $existing) {
        if (-not $script:Cmdlet.ShouldProcess($LinkPath, "Create a link to $TargetPath")) { return }
        try {
            $kind = New-FolderLink -LinkPath $LinkPath -TargetPath $TargetPath
            Write-Status -State LINKED -Message ('{0} ({1}): {2}' -f $Label, $kind, $LinkPath)
        }
        catch {
            Write-Status -State PROBLEM -Message ('{0}: could not create {1}. {2}' -f $Label, $LinkPath, $_.Exception.Message)
        }
        return
    }
    if (-not $existing.IsLink) {
        Write-Status -State PROBLEM -Message ('{0}: {1} already exists and is not a link. Move anything you need from it into dev-home, delete it, then run setup.ps1 again.' -f $Label, $LinkPath)
        return
    }
    if ($existing.Target -eq $wantedTarget) {
        Write-Status -State OK -Message $Label
        return
    }
    Write-Status -State PROBLEM -Message ('{0}: {1} links to {2}, not to {3}. Left alone. If you no longer need it, remove it with cmd /c rmdir, then run setup.ps1 again.' -f $Label, $LinkPath, $existing.Target, $TargetPath)
}

function Sync-CodexRules {
    # Codex reads a single always-on file, so setup writes the core rules and the person's own
    # rules into it, joined. It replaces only a file it wrote, or a link whose target is gone.
    param(
        [Parameter(Mandatory)][string]$CorePath,
        [Parameter(Mandatory)][string]$PersonalPath
    )
    $path = Join-Path $HomeDir '.codex' 'AGENTS.md'
    $label = 'Codex always-on rules'
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($CodexMarker + ', from its core rules and your dev-home rules/global.md. Edit those instead: setup rewrites this file after every sync. -->')
    foreach ($source in @($CorePath, $PersonalPath)) {
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $parts.Add([System.IO.File]::ReadAllText($source).Replace("`r`n", "`n").TrimEnd("`n"))
        }
    }
    $text = ($parts -join "`n`n") + "`n"

    $existing = Get-LinkInfo -Path $path
    if ($null -ne $existing) {
        if ($existing.IsLink) {
            if (Test-Path -LiteralPath $existing.Target) {
                Write-Status -State PROBLEM -Message ('{0}: {1} links to {2}. Left alone. Move anything you want to keep into {3}, delete the link, then run setup.ps1 again.' -f $label, $path, $existing.Target, $PersonalPath)
                return
            }
            if (-not $script:Cmdlet.ShouldProcess($path, 'Replace this link with the joined rules file')) { return }
            [System.IO.File]::Delete($path)
        }
        else {
            $current = [System.IO.File]::ReadAllText($path)
            if (-not $current.StartsWith($CodexMarker, [System.StringComparison]::Ordinal)) {
                Write-Status -State PROBLEM -Message ('{0}: {1} already exists, and setup did not write it. Move anything you want to keep into {2}, delete the file, then run setup.ps1 again.' -f $label, $path, $PersonalPath)
                return
            }
            if ($current -ceq $text) {
                Write-Status -State OK -Message $label
                return
            }
        }
    }
    if (-not $script:Cmdlet.ShouldProcess($path, 'Write the core and personal rules, joined')) { return }
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Status -State WROTE -Message ('{0}: {1}' -f $label, $path)
}

# ---------------------------------------------------------------------------------------------
# Settings changes. Each change is planned in full first, checked by reading the new text back,
# shown as a line diff, and written only after a yes, with a backup.

function ConvertTo-Lines {
    # Splits file text into lines, without the empty entry that a final line break leaves.
    param([AllowEmptyString()][string]$Text)
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($Text -split '\r?\n'))
    if (($Text.Length -eq 0) -or $Text.EndsWith("`n")) { $lines.RemoveAt($lines.Count - 1) }
    return , $lines.ToArray()
}

function Read-SettingsFile {
    # Reads a settings file along with how it's saved (byte order mark, line breaks), so a rewrite
    # can keep both. Text is '' when the file doesn't exist yet. Reason says why it can't be edited.
    param([Parameter(Mandatory)][string]$Path)
    $file = [pscustomobject]@{ Text = ''; Bom = $false; NewLine = "`n"; FinalNewLine = $true; Reason = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $file }
    $link = Get-LinkInfo -Path $Path
    if (($null -ne $link) -and $link.IsLink) {
        $file.Reason = 'it is a link, so edit the file it points to instead'
        return $file
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $file.Bom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
    $skip = if ($file.Bom) { 3 } else { 0 }
    try {
        $file.Text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, $skip, $bytes.Length - $skip)
    }
    catch {
        $file.Reason = 'it is not saved as UTF-8'
        return $file
    }
    $crlf = [regex]::Matches($file.Text, "`r`n").Count
    if (($crlf * 2) -gt [regex]::Matches($file.Text, "`n").Count) { $file.NewLine = "`r`n" }
    $file.FinalNewLine = ($file.Text.Length -eq 0) -or $file.Text.EndsWith("`n")
    return $file
}

function Write-SettingsFile {
    # Writes the new text to a file next to the original and reads it back, then swaps it into
    # place. The original becomes a dated backup. Returns the backup's path, or '' when there was
    # no file before.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$Bom
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -Confirm:$false | Out-Null
    }
    $temp = $Path + '.dev-home-new'
    try {
        [System.IO.File]::WriteAllText($temp, $Text, [System.Text.UTF8Encoding]::new($Bom))
        if ([System.IO.File]::ReadAllText($temp) -cne $Text) { throw 'The new file did not read back the same.' }
        if (-not (Test-Path -LiteralPath $Path)) {
            [System.IO.File]::Move($temp, $Path)
            return ''
        }
        # Replace would overwrite an older backup with the same name, so pick an unused one.
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = '{0}.bak-{1}' -f $Path, $stamp
        for ($n = 2; Test-Path -LiteralPath $backup; $n++) { $backup = '{0}.bak-{1}-{2}' -f $Path, $stamp, $n }
        try {
            [System.IO.File]::Replace($temp, $Path, $backup)
        }
        catch {
            # Windows can fail after renaming the original to the backup name. Put it back.
            if ((-not (Test-Path -LiteralPath $Path)) -and (Test-Path -LiteralPath $backup)) {
                [System.IO.File]::Move($backup, $Path)
            }
            throw
        }
        return $backup
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -Confirm:$false }
    }
}

function Get-LineDiff {
    # Lists the lines that differ between two versions of a file, with a little context, each run
    # headed by its line number in the new version. The preview comes from this, so it shows what
    # the write really changes, however the new text was built.
    param([string[]]$Old, [string[]]$New, [int]$Context = 2)
    $top = 0
    while (($top -lt $Old.Count) -and ($top -lt $New.Count) -and ($Old[$top] -ceq $New[$top])) { $top++ }
    $bottom = 0
    while (($bottom -lt ($Old.Count - $top)) -and ($bottom -lt ($New.Count - $top)) -and
        ($Old[$Old.Count - 1 - $bottom] -ceq $New[$New.Count - 1 - $bottom])) { $bottom++ }

    # Line up the lines in between with Myers' diff, whose work grows with the number of changes
    # rather than the size of the file. $trace keeps V from before each round, for the walk back.
    $n = $Old.Count - $top - $bottom
    $m = $New.Count - $top - $bottom
    $max = $n + $m
    $offset = $max + 1
    $v = [int[]]::new(2 * $max + 3)
    $trace = [System.Collections.Generic.List[int[]]]::new()
    $done = ($max -eq 0)
    $rounds = [Math]::Min($max, 300)
    for ($d = 0; (-not $done) -and ($d -le $rounds); $d++) {
        $trace.Add([int[]]$v.Clone())
        for ($k = -$d; $k -le $d; $k += 2) {
            if (($k -eq -$d) -or (($k -ne $d) -and ($v[$offset + $k - 1] -lt $v[$offset + $k + 1]))) { $x = $v[$offset + $k + 1] }
            else { $x = $v[$offset + $k - 1] + 1 }
            $y = $x - $k
            while (($x -lt $n) -and ($y -lt $m) -and ($Old[$top + $x] -ceq $New[$top + $y])) {
                $x++
                $y++
            }
            $v[$offset + $k] = $x
            if (($x -ge $n) -and ($y -ge $m)) {
                $done = $true
                break
            }
        }
    }

    # The lines in between, in order, as kept (' '), removed ('-'), or added ('+').
    $middle = [System.Collections.Generic.List[object]]::new()
    if ($done) {
        $x = $n
        $y = $m
        for ($d = $trace.Count - 1; $d -ge 0; $d--) {
            $before = $trace[$d]
            $k = $x - $y
            if (($k -eq -$d) -or (($k -ne $d) -and ($before[$offset + $k - 1] -lt $before[$offset + $k + 1]))) { $prevK = $k + 1 }
            else { $prevK = $k - 1 }
            $prevX = $before[$offset + $prevK]
            $prevY = $prevX - $prevK
            while (($x -gt $prevX) -and ($y -gt $prevY)) {
                $middle.Add(@(' ', $New[$top + $y - 1]))
                $x--
                $y--
            }
            if ($d -gt 0) {
                if ($x -eq $prevX) { $middle.Add(@('+', $New[$top + $y - 1])) }
                else { $middle.Add(@('-', $Old[$top + $x - 1])) }
            }
            $x = $prevX
            $y = $prevY
        }
        $middle.Reverse()
    }
    else {
        # Too many changes to line up quickly: show the old lines as removed and the new ones as
        # added. Still exact, just longer.
        for ($i = 0; $i -lt $n; $i++) { $middle.Add(@('-', $Old[$top + $i])) }
        for ($i = 0; $i -lt $m; $i++) { $middle.Add(@('+', $New[$top + $i])) }
    }

    # Every line with its line number in the new file.
    $lines = [System.Collections.Generic.List[object]]::new()
    for ($k = 0; $k -lt $top; $k++) { $lines.Add(@(' ', $New[$k], ($k + 1))) }
    $j = $top
    foreach ($entry in $middle) {
        if ($entry[0] -eq '-') {
            $lines.Add(@('-', $entry[1], ($j + 1)))
        }
        else {
            $j++
            $lines.Add(@($entry[0], $entry[1], $j))
        }
    }
    for ($k = $New.Count - $bottom; $k -lt $New.Count; $k++) { $lines.Add(@(' ', $New[$k], ($k + 1))) }

    # Show each changed line, and the kept lines within $Context of one.
    $show = [bool[]]::new($lines.Count)
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k][0] -eq ' ') { continue }
        $from = [Math]::Max(0, $k - $Context)
        $to = [Math]::Min($lines.Count - 1, $k + $Context)
        for ($c = $from; $c -le $to; $c++) { $show[$c] = $true }
    }
    $diff = [System.Collections.Generic.List[string]]::new()
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if (-not $show[$k]) { continue }
        if (($k -eq 0) -or (-not $show[$k - 1])) { $diff.Add(('Line {0}:' -f $lines[$k][2])) }
        $diff.Add($lines[$k][0] + ' ' + $lines[$k][1])
    }
    return , $diff.ToArray()
}

function Repair-Setting {
    # Offers a planned settings change: shows the changed lines, asks, then writes the file with a
    # backup. When the change can't be made safely, the answer is no, or setup runs with -Quiet, it
    # reports a problem and leaves the file alone.
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Need,
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][string]$HowTo,
        [Parameter(Mandatory)][string]$Snippet
    )
    $problem = '{0}: {1} needs {2}.' -f $Subject, $Path, $Need
    if ($Plan.Reason) {
        Write-Status -State PROBLEM -Message $problem
        if (-not $Quiet) {
            Write-Line -Text ('         Setup won''t change this file itself: {0}.' -f $Plan.Reason)
            Write-Line -Text ('         ' + $HowTo)
            Write-Line -Color Yellow -Text $Snippet
        }
        return
    }
    if ($Quiet) {
        Write-Status -State PROBLEM -Message ($problem + ' Run setup.ps1 without -Quiet, and it offers to make the change.')
        return
    }

    Write-Status -State CHANGE -Message $problem
    Write-Line -Text '         Setup can make this change, and keeps a backup of the file first. Lines marked + are added, - removed:'
    if ($Plan.Note) { Write-Line -Text ('         ' + $Plan.Note) }
    $diff = Get-LineDiff -Old (ConvertTo-Lines -Text $Plan.File.Text) -New (ConvertTo-Lines -Text $Plan.NewText)
    $limit = 40
    foreach ($line in ($diff | Select-Object -First $limit)) {
        $color = if ($line.StartsWith('+ ')) { 'Green' } elseif ($line.StartsWith('- ')) { 'Red' } else { '' }
        Write-Line -Color $color -Text ('           ' + $line)
    }
    if ($diff.Count -gt $limit) { Write-Line -Text ('           ...and {0} more lines.' -f ($diff.Count - $limit)) }

    if (-not $script:Cmdlet.ShouldProcess($Path, 'Change the lines shown, after asking, and keep a backup')) { return }
    if (-not (Confirm-Change -Question '         Make this change?')) {
        Write-Status -State PROBLEM -Message ('{0}: left unchanged. Make the change shown above by hand, or run setup.ps1 again and answer y.' -f $Subject)
        return
    }
    try {
        $now = Read-SettingsFile -Path $Path
        if ($now.Reason -or ($now.Text -cne $Plan.File.Text)) {
            throw 'The file changed while setup was waiting for an answer, so it was left alone. Run setup.ps1 again.'
        }
        $backup = Write-SettingsFile -Path $Path -Text $Plan.NewText -Bom $Plan.File.Bom
        $saved = if ($backup) { ' Backup of the old file: ' + $backup } else { ' (new file)' }
        Write-Status -State SET -Message ('{0}: changed {1}.{2}' -f $Subject, $Path, $saved)
    }
    catch {
        Write-Status -State PROBLEM -Message ('{0}: could not write {1}. {2}' -f $Subject, $Path, $_.Exception.GetBaseException().Message)
    }
}

function Get-ClaudeSettingsPlan {
    # Plans adding folders to permissions.additionalDirectories in a Claude Code settings.json.
    # The new text is two-space JSON, as Claude Code writes it. As a check, it's parsed again with
    # the additions taken back out, and has to match the original exactly.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Entries
    )
    Add-Type -AssemblyName System.Text.Json, System.Text.Encodings.Web
    $file = Read-SettingsFile -Path $Path
    $plan = [pscustomobject]@{ File = $file; NewText = $null; Reason = $file.Reason; Note = '' }
    if ($plan.Reason) { return $plan }

    try {
        if ([string]::IsNullOrWhiteSpace($file.Text)) { $json = [System.Text.Json.Nodes.JsonObject]::new() }
        else { $json = [System.Text.Json.Nodes.JsonNode]::Parse($file.Text) }
    }
    catch {
        $plan.Reason = 'it is not plain JSON (it may have comments), and rewriting it would lose that'
        return $plan
    }
    if ($json -isnot [System.Text.Json.Nodes.JsonObject]) {
        $plan.Reason = 'its top level is not a JSON object'
        return $plan
    }

    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    try {
        $original = $json.ToJsonString()
        $originalIndented = $json.ToJsonString($options).Replace("`r`n", "`n")
        $added = 'entry'
        $permissions = $json['permissions']
        if ($null -eq $permissions) {
            if ($json.ContainsKey('permissions')) { $plan.Reason = 'its "permissions" is null'; return $plan }
            $permissions = [System.Text.Json.Nodes.JsonObject]::new()
            $json['permissions'] = $permissions
            $added = 'permissions'
        }
        elseif ($permissions -isnot [System.Text.Json.Nodes.JsonObject]) {
            $plan.Reason = 'its "permissions" is not a JSON object'
            return $plan
        }
        $list = $permissions['additionalDirectories']
        if ($null -eq $list) {
            if ($permissions.ContainsKey('additionalDirectories')) { $plan.Reason = 'its "additionalDirectories" is null'; return $plan }
            $list = [System.Text.Json.Nodes.JsonArray]::new()
            $permissions['additionalDirectories'] = $list
            if ($added -eq 'entry') { $added = 'list' }
        }
        elseif ($list -isnot [System.Text.Json.Nodes.JsonArray]) {
            $plan.Reason = 'its "additionalDirectories" is not a list'
            return $plan
        }
        foreach ($entry in $Entries) { $list.Add([System.Text.Json.Nodes.JsonValue]::Create([string]$entry)) }

        $newText = $json.ToJsonString($options).Replace("`r`n", "`n").Replace("`n", $file.NewLine)
        if ($file.FinalNewLine) { $newText += $file.NewLine }

        # Check: read the new text back, confirm the new entries, take the additions out again,
        # and compare what's left with the original.
        $check = [System.Text.Json.Nodes.JsonNode]::Parse($newText)
        $checkList = $check['permissions']['additionalDirectories']
        $first = $checkList.Count - $Entries.Count
        for ($i = 0; $i -lt $Entries.Count; $i++) {
            $expected = [System.Text.Json.Nodes.JsonValue]::Create([string]$Entries[$i]).ToJsonString()
            if ($checkList[$first + $i].ToJsonString() -cne $expected) { throw 'a new entry did not read back' }
        }
        switch ($added) {
            'permissions' { [void]$check.Remove('permissions') }
            'list' { [void]$check['permissions'].Remove('additionalDirectories') }
            default { for ($i = 0; $i -lt $Entries.Count; $i++) { $checkList.RemoveAt($checkList.Count - 1) } }
        }
        if ($check.ToJsonString() -cne $original) { throw 'the rest of the file did not read back the same' }
    }
    catch {
        $plan.Reason = 'a check of the planned change failed ({0})' -f $_.Exception.Message
        return $plan
    }

    $plan.NewText = $newText
    if ((-not [string]::IsNullOrWhiteSpace($file.Text)) -and ($originalIndented -cne $file.Text.Replace("`r`n", "`n").TrimEnd("`n"))) {
        $plan.Note = 'Some other lines change only in layout (spacing or escaping). The settings in them stay the same.'
    }
    return $plan
}

function Get-TomlPathPattern {
    # Matches the path inside a TOML string, written with single or doubled slashes of either
    # kind, but not a longer path that starts the same way.
    param([Parameter(Mandatory)][string]$Path)
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' } | ForEach-Object { [regex]::Escape($_) })
    return ($parts -join '[\\/]{1,2}') + '[\\/]{0,2}[''"]'
}

function Get-TomlMaskedLine {
    # Returns a config.toml line with the insides of strings replaced by underscores and any
    # comment cut off, so brackets, dots, and equals signs in strings can't pass for structure.
    # Positions still match the original line. Returns $null when a string doesn't close.
    param([AllowEmptyString()][string]$Line)
    $masked = [System.Text.StringBuilder]::new()
    $quote = [char]0
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($quote -eq [char]0) {
            if ($c -eq [char]'#') { break }
            if (($c -eq [char]'"') -or ($c -eq [char]"'")) { $quote = $c }
            [void]$masked.Append($c)
        }
        elseif ($c -eq $quote) {
            $quote = [char]0
            [void]$masked.Append($c)
        }
        elseif (($quote -eq [char]'"') -and ($c -eq [char]'\') -and (($i + 1) -lt $Line.Length)) {
            [void]$masked.Append('__')
            $i++
        }
        else {
            [void]$masked.Append('_')
        }
    }
    if ($quote -ne [char]0) { return $null }
    return $masked.ToString()
}

function Get-TomlDepthChange {
    # Brackets and braces opened minus closed, in a masked line.
    param([AllowEmptyString()][string]$Masked)
    $change = 0
    foreach ($c in $Masked.ToCharArray()) {
        if (($c -eq [char]'[') -or ($c -eq [char]'{')) { $change++ }
        elseif (($c -eq [char]']') -or ($c -eq [char]'}')) { $change-- }
    }
    return $change
}

function Read-TomlLayout {
    # Finds the tables and keys in config.toml, as far as setup needs them: each key's table and
    # the lines its value spans. Sets Reason instead when the file uses TOML this reader doesn't
    # follow, so setup never edits a file it hasn't fully understood.
    param([string[]]$Lines)
    $layout = [pscustomobject]@{
        Headers = [System.Collections.Generic.List[object]]::new()
        Keys    = [System.Collections.Generic.List[object]]::new()
        Reason  = $null
    }
    $table = ''
    $depth = 0
    $key = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $masked = Get-TomlMaskedLine -Line $Lines[$i]
        if ($null -eq $masked) {
            $layout.Reason = 'line {0} has a string that does not close on that line' -f ($i + 1)
            return $layout
        }
        if ($depth -gt 0) {
            $depth += Get-TomlDepthChange -Masked $masked
            $key.End = $i
            if ($depth -lt 0) { $layout.Reason = 'line {0} closes more brackets than were opened' -f ($i + 1); return $layout }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($masked)) { continue }
        $header = [regex]::Match($masked, '^\s*(\[\[?)([^\[\]]+)(\]\]?)\s*$')
        if ($header.Success -and ($header.Groups[1].Length -eq $header.Groups[3].Length)) {
            $table = $Lines[$i].Substring($header.Groups[2].Index, $header.Groups[2].Length).Trim()
            $layout.Headers.Add([pscustomobject]@{ Name = $table; Line = $i; IsArray = ($header.Groups[1].Length -eq 2) })
            continue
        }
        $assignment = [regex]::Match($masked, '^\s*([^=\[\]\{\}]+?)\s*=(.*)$')
        if ($assignment.Success) {
            $key = [pscustomobject]@{
                Table = $table
                Name  = $Lines[$i].Substring($assignment.Groups[1].Index, $assignment.Groups[1].Length)
                Start = $i
                End   = $i
            }
            $layout.Keys.Add($key)
            $depth = Get-TomlDepthChange -Masked $assignment.Groups[2].Value
            if ($depth -lt 0) { $layout.Reason = 'line {0} closes more brackets than it opens' -f ($i + 1); return $layout }
            continue
        }
        $layout.Reason = 'line {0} is not a table, a key, or a comment' -f ($i + 1)
        return $layout
    }
    if ($depth -ne 0) { $layout.Reason = 'a list or inline table does not close' }
    return $layout
}

function Get-TomlValueText {
    # A key's lines joined, with any comments cut off, so a commented-out path doesn't count.
    param([string[]]$Lines, [Parameter(Mandatory)][pscustomobject]$Key)
    $code = for ($i = $Key.Start; $i -le $Key.End; $i++) {
        $Lines[$i].Substring(0, (Get-TomlMaskedLine -Line $Lines[$i]).Length)
    }
    return (@($code) -join "`n")
}

function Test-CodexConfigText {
    # True when config.toml text has WritableRoot in [sandbox_workspace_write] writable_roots and a
    # top-level project_doc_max_bytes of at least MinDocBytes. Comments and other tables don't
    # count. For a file the TOML reader can't follow, it falls back to a plain text search.
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$WritableRoot,
        [Parameter(Mandatory)][int64]$MinDocBytes
    )
    $rootPattern = Get-TomlPathPattern -Path $WritableRoot
    $lines = ConvertTo-Lines -Text $Text
    $layout = if ($Text -match "'''|""""""") { $null } else { Read-TomlLayout -Lines $lines }
    if (($null -eq $layout) -or $layout.Reason) {
        $hasWritableRoot = $Text -match ('writable_roots\s*=\s*\[[^\]]*' + $rootPattern)
        $maxBytes = [regex]::Match($Text, '(?m)^\s*project_doc_max_bytes\s*=\s*(\d+)')
        return ($hasWritableRoot -and $maxBytes.Success -and ([int64]$maxBytes.Groups[1].Value -ge $MinDocBytes))
    }
    $hasWritableRoot = $false
    $hasMaxBytes = $false
    foreach ($key in $layout.Keys) {
        if (($key.Table -eq '') -and ($key.Name -ceq 'project_doc_max_bytes')) {
            $number = [regex]::Match((Get-TomlValueText -Lines $lines -Key $key), '=\s*([0-9][0-9_]*)\s*$')
            [int64]$value = 0
            if ($number.Success -and [int64]::TryParse(($number.Groups[1].Value -replace '_', ''), [ref]$value) -and ($value -ge $MinDocBytes)) {
                $hasMaxBytes = $true
            }
        }
        elseif (($key.Table -ceq 'sandbox_workspace_write') -and ($key.Name -ceq 'writable_roots') -and
            ((Get-TomlValueText -Lines $lines -Key $key) -match $rootPattern)) {
            $hasWritableRoot = $true
        }
    }
    return ($hasWritableRoot -and $hasMaxBytes)
}

function Get-CodexConfigPlan {
    # Plans the config.toml change that adds WritableRoot to writable_roots and raises
    # project_doc_max_bytes to at least MinDocBytes, as whole-line insertions and edits, leaving
    # every other line as it was. The new text is read again to confirm it's still TOML this reader
    # follows, with each setting defined once and set as needed.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WritableRoot,
        [Parameter(Mandatory)][int64]$MinDocBytes
    )
    $rootPattern = Get-TomlPathPattern -Path $WritableRoot
    $file = Read-SettingsFile -Path $Path
    $plan = [pscustomobject]@{ File = $file; NewText = $null; Reason = $file.Reason; Note = '' }
    if ($plan.Reason) { return $plan }
    if ($file.Text -match "'''|""""""") {
        $plan.Reason = 'it has multi-line strings, which setup does not edit'
        return $plan
    }
    $lines = ConvertTo-Lines -Text $file.Text
    $layout = Read-TomlLayout -Lines $lines
    if ($layout.Reason) { $plan.Reason = $layout.Reason; return $plan }

    $entry = "'{0}'" -f $WritableRoot
    $inserts = [System.Collections.Generic.List[object]]::new()   # lines to add before line At
    $changes = @{}                                                 # line index -> new text

    # project_doc_max_bytes: a top-level key, so it goes above the first table.
    $maxKeys = @($layout.Keys | Where-Object { ($_.Table -eq '') -and ($_.Name -match '^["'']?project_doc_max_bytes["'']?$') })
    if ($maxKeys.Count -gt 1) { $plan.Reason = 'it sets project_doc_max_bytes more than once'; return $plan }
    if ($maxKeys.Count -eq 1) {
        $key = $maxKeys[0]
        $number = [regex]::Match((Get-TomlMaskedLine -Line $lines[$key.Start]), '=\s*([0-9][0-9_]*)\s*$')
        [int64]$value = 0
        if (($key.Name -cne 'project_doc_max_bytes') -or ($key.End -ne $key.Start) -or (-not $number.Success) -or
            (-not [int64]::TryParse(($number.Groups[1].Value -replace '_', ''), [ref]$value))) {
            $plan.Reason = 'its project_doc_max_bytes line is in a form setup does not edit'
            return $plan
        }
        if ($value -lt $MinDocBytes) {
            $digits = $number.Groups[1]
            $changes[$key.Start] = $lines[$key.Start].Substring(0, $digits.Index) + $MinDocBytes + $lines[$key.Start].Substring($digits.Index + $digits.Length)
        }
    }
    else {
        $newLine = 'project_doc_max_bytes = {0}' -f $MinDocBytes
        $topKeys = @($layout.Keys | Where-Object { $_.Table -eq '' })
        if ($topKeys.Count -gt 0) {
            $inserts.Add([pscustomobject]@{ At = $topKeys[-1].End + 1; Lines = @($newLine) })
        }
        elseif ($layout.Headers.Count -gt 0) {
            # Above the first table, and above any comment sitting right on top of it.
            $at = $layout.Headers[0].Line
            while (($at -gt 0) -and $lines[$at - 1].TrimStart().StartsWith('#')) { $at-- }
            $inserts.Add([pscustomobject]@{ At = $at; Lines = @($newLine, '') })
        }
        else {
            $inserts.Add([pscustomobject]@{ At = $lines.Count; Lines = @($newLine) })
        }
    }

    # writable_roots, in the [sandbox_workspace_write] table.
    $otherForms = @($layout.Headers | Where-Object { ($_.Name -match '^["'']?sandbox_workspace_write') -and (($_.Name -cne 'sandbox_workspace_write') -or $_.IsArray) }) +
        @($layout.Keys | Where-Object { ($_.Table -eq '') -and ($_.Name -match '^["'']?sandbox_workspace_write') })
    if ($otherForms.Count -gt 0) { $plan.Reason = 'it sets sandbox_workspace_write in a form setup does not edit'; return $plan }
    $tables = @($layout.Headers | Where-Object { $_.Name -ceq 'sandbox_workspace_write' })
    if ($tables.Count -gt 1) { $plan.Reason = 'it has [sandbox_workspace_write] more than once'; return $plan }
    if ($tables.Count -eq 0) {
        $inserts.Add([pscustomobject]@{ At = $lines.Count; Lines = @('[sandbox_workspace_write]', ('writable_roots = [{0}]' -f $entry)) })
    }
    else {
        $roots = @($layout.Keys | Where-Object { ($_.Table -ceq 'sandbox_workspace_write') -and ($_.Name -match '^["'']?writable_roots["'']?$') })
        if (($roots.Count -gt 1) -or (($roots.Count -eq 1) -and ($roots[0].Name -cne 'writable_roots'))) {
            $plan.Reason = 'its writable_roots line is in a form setup does not edit'
            return $plan
        }
        if ($roots.Count -eq 0) {
            $inserts.Add([pscustomobject]@{ At = $tables[0].Line + 1; Lines = @(('writable_roots = [{0}]' -f $entry)) })
        }
        elseif (-not ((Get-TomlValueText -Lines $lines -Key $roots[0]) -match $rootPattern)) {
            $key = $roots[0]
            if ($key.Start -eq $key.End) {
                # One line: add the entry before the closing bracket.
                $list = [regex]::Match((Get-TomlMaskedLine -Line $lines[$key.Start]), '=\s*\[(.*)\]\s*$')
                if (-not $list.Success) { $plan.Reason = 'its writable_roots is not a list'; return $plan }
                $inner = $list.Groups[1]
                $head = $lines[$key.Start].Substring(0, $inner.Index + $inner.Length).TrimEnd()
                $tail = $lines[$key.Start].Substring($inner.Index + $inner.Length)
                $separator = if ([string]::IsNullOrWhiteSpace($inner.Value)) { '' } elseif ($head.EndsWith(',')) { ' ' } else { ', ' }
                $changes[$key.Start] = $head + $separator + $entry + $tail
            }
            else {
                # Several lines: add a line above the closing bracket, with a comma after the
                # entry before it if that has none.
                if ((Get-TomlMaskedLine -Line $lines[$key.End]).Trim() -ne ']') {
                    $plan.Reason = 'its writable_roots spans several lines in a form setup does not edit'
                    return $plan
                }
                $last = $key.End - 1
                while (($last -gt $key.Start) -and [string]::IsNullOrWhiteSpace((Get-TomlMaskedLine -Line $lines[$last]))) { $last-- }
                $lastCode = (Get-TomlMaskedLine -Line $lines[$last]).TrimEnd()
                $indent = if ($last -gt $key.Start) { [regex]::Match($lines[$last], '^\s*').Value } else { [regex]::Match($lines[$key.End], '^\s*').Value + '    ' }
                $newEntry = $indent + $entry
                if ($lastCode.EndsWith(',')) { $newEntry += ',' }
                elseif (-not $lastCode.EndsWith('[')) { $changes[$last] = $lines[$last].Insert($lastCode.Length, ',') }
                $inserts.Add([pscustomobject]@{ At = $key.End; Lines = @($newEntry) })
            }
        }
    }

    # Build the new text. Each original line keeps its own line break, so unchanged lines stay
    # byte for byte as they were. New lines use the break the file mostly uses.
    $breaks = @([regex]::Matches($file.Text, '\r?\n') | ForEach-Object { $_.Value })
    $out = [System.Text.StringBuilder]::new()
    $previous = ''
    $open = $false   # the last line written has no line break after it
    for ($i = 0; $i -le $lines.Count; $i++) {
        foreach ($insert in $inserts) {
            if ($insert.At -ne $i) { continue }
            foreach ($line in $insert.Lines) {
                if ($open) {
                    [void]$out.Append($file.NewLine)
                    $open = $false
                }
                # A new table gets a blank line above it, unless it starts the file.
                if ($line.StartsWith('[') -and ($out.Length -gt 0) -and ($previous.Trim() -ne '')) { [void]$out.Append($file.NewLine) }
                [void]$out.Append($line).Append($file.NewLine)
                $previous = $line
            }
        }
        if ($i -lt $lines.Count) {
            $line = if ($changes.ContainsKey($i)) { $changes[$i] } else { $lines[$i] }
            $break = if ($i -lt $breaks.Count) { $breaks[$i] } else { '' }
            [void]$out.Append($line).Append($break)
            $previous = $line
            $open = ($break -eq '')
        }
    }
    $newText = $out.ToString()

    # Check: the new text must read cleanly, pass the same test setup runs, and define each table
    # and setting once.
    $after = Read-TomlLayout -Lines (ConvertTo-Lines -Text $newText)
    $tableNames = @($after.Headers | Where-Object { -not $_.IsArray } | ForEach-Object { $_.Name })
    $ok = (-not $after.Reason) -and (Test-CodexConfigText -Text $newText -WritableRoot $WritableRoot -MinDocBytes $MinDocBytes) -and
        ([System.Collections.Generic.HashSet[string]]::new([string[]]$tableNames).Count -eq $tableNames.Count) -and
        (@($after.Keys | Where-Object { ($_.Table -eq '') -and ($_.Name -ceq 'project_doc_max_bytes') }).Count -eq 1) -and
        (@($after.Keys | Where-Object { ($_.Table -ceq 'sandbox_workspace_write') -and ($_.Name -ceq 'writable_roots') }).Count -eq 1)
    if (-not $ok) {
        $plan.Reason = 'a check of the planned change failed'
        return $plan
    }
    $plan.NewText = $newText
    return $plan
}

# ---------------------------------------------------------------------------------------------
# 1. Where things are

$toolsProblem = Test-SafePath -Path $ToolsRoot
if ($toolsProblem) {
    Write-Status -State PROBLEM -Message ('dev-home-tools is at {0}, which {1}. Setup writes this path into commands as it is, so move the folder, then run setup.ps1 again.' -f $ToolsRoot, $toolsProblem)
    Exit-Setup
}

$settings = Read-LocalSettings
if ($settings.testHomeDir) {
    $HomeDir = ConvertTo-ComparablePath -Path $settings.testHomeDir
    if (-not (Test-Path -LiteralPath $HomeDir -PathType Container)) {
        Write-Status -State PROBLEM -Message ('local-settings.json sets testHomeDir to {0}, which does not exist.' -f $HomeDir)
        Exit-Setup
    }
    Write-Status -State TEST -Message ('Using the test profile {0} instead of {1}, because local-settings.json sets testHomeDir.' -f $HomeDir, $HOME)
}
$saveSettings = $false
if ($ContentDir) {
    $wanted = ConvertTo-ForwardPath -Path $ContentDir
    if ($settings.contentDir -cne $wanted) {
        $settings.contentDir = $wanted
        $saveSettings = $true
    }
}
elseif (-not $settings.contentDir) {
    $default = ConvertTo-ForwardPath -Path (Join-Path (Split-Path -Parent $ToolsRoot) 'dev-home')
    if (-not ($Quiet -or [Console]::IsInputRedirected)) {
        Write-Line -Text 'dev-home is your private repo for handoffs and a knowledge base. Setup needs its folder on this PC:'
        Write-Line -Text 'where it is now, or where it should go. Press Enter to accept the suggestion in brackets.'
    }
    $answer = Read-Answer -Question 'Your dev-home folder' -Default $default
    if ($null -eq $answer) {
        Write-Status -State PROBLEM -Message 'This PC has no dev-home folder set. Run setup.ps1 once in a terminal without -Quiet, and it asks for one.'
        Exit-Setup
    }
    $settings.contentDir = ConvertTo-ForwardPath -Path $answer
    $saveSettings = $true
}

$contentProblem = Test-SafePath -Path $settings.contentDir
if ($contentProblem) {
    Write-Status -State PROBLEM -Message ('The dev-home folder {0} {1}. Setup writes this path into commands as it is. Choose another folder with -ContentDir.' -f $settings.contentDir, $contentProblem)
    Exit-Setup
}

if ($settings.IsNew -and (-not ($Quiet -or [Console]::IsInputRedirected))) {
    Write-Line -Text 'sync.ps1 can pull dev-home-tools updates on every sync, or only tell you when there are some,'
    Write-Line -Text 'so you can look at them first and pull them with update.ps1.'
    $settings.autoUpdate = Confirm-Change -Question 'Pull updates automatically?'

    # Another Claude account run with CLAUDE_CONFIG_DIR has its own folder, usually ~/.claude-<name>.
    foreach ($folder in @(Get-ChildItem -LiteralPath $HomeDir -Directory -Force -Filter '.claude-*')) {
        if (Confirm-Change -Question ('Also set up {0}, for another Claude account?' -f $folder.FullName)) {
            $settings.claudeConfigDirs = @($settings.claudeConfigDirs) + ('~/' + $folder.Name)
        }
    }
    $saveSettings = $true
}

if ($saveSettings -and $script:Cmdlet.ShouldProcess($SettingsPath, 'Save this PC''s settings')) {
    Save-LocalSettings -Settings $settings
    Write-Status -State SET -Message ('This PC''s settings: {0}' -f $SettingsPath)
}

$ContentRoot = ConvertTo-ComparablePath -Path $settings.contentDir
$Values = @{
    TOOLS_DIR   = ConvertTo-ForwardPath -Path $ToolsRoot
    CONTENT_DIR = ConvertTo-ForwardPath -Path $ContentRoot
}

# 2. dev-home itself: clone or create it when it's missing, then set its repo-local git config.

$contentMissing = -not (Test-Path -LiteralPath $ContentRoot -PathType Container)
if ((-not $contentMissing) -and (@(Get-ChildItem -LiteralPath $ContentRoot -Force).Count -eq 0)) { $contentMissing = $true }
if ($contentMissing) {
    Initialize-ContentRepo -Path $ContentRoot -Values $Values
    if (-not (Test-Path -LiteralPath (Join-Path $ContentRoot '.git'))) { Exit-Setup }
}
if (-not (Test-Path -LiteralPath (Join-Path $ContentRoot '.git'))) {
    Write-Status -State PROBLEM -Message ('{0} is not a git repo. Point setup at your dev-home with -ContentDir, or move that folder aside so setup can clone or create one there.' -f $ContentRoot)
    Exit-Setup
}
# A repo with no commits is most likely a new dev-home that setup couldn't finish, for example
# because git doesn't know the person's name and email yet. Starting over is the simple fix. Only
# exit code 1 means no commits: anything else is git failing to read the repo, which says nothing
# about what's in it.
$head = Invoke-Tool -FilePath 'git' -Arguments @('-C', $ContentRoot, 'rev-parse', '--verify', '--quiet', 'HEAD')
if ($head.ExitCode -eq 1) {
    Write-Status -State PROBLEM -Message ('{0} is a git repo with no commits, probably from a setup run that stopped partway. If it holds nothing you need, delete the folder, fix what stopped setup, then run setup.ps1 again to clone or create dev-home there.' -f $ContentRoot)
    Exit-Setup
}
if ($head.ExitCode -ne 0) {
    Write-Status -State PROBLEM -Message ('git could not read {0}, so setup stopped. git: {1}' -f $ContentRoot, (Get-FirstLine $head.Lines))
    Exit-Setup
}

# No signing prompts for agent commits, and pulls that merge rather than rebase, as sync.ps1
# does, because a rebase refuses to run while any file is uncommitted.
$wantedConfig = [ordered]@{ 'commit.gpgsign' = 'false'; 'pull.rebase' = 'false' }
foreach ($key in $wantedConfig.Keys) {
    $value = $wantedConfig[$key]
    $current = (Invoke-Tool -FilePath 'git' -Arguments @('-C', $ContentRoot, 'config', '--local', '--get', $key)).Lines
    if ((Get-FirstLine $current) -eq $value) {
        Write-Status -State OK -Message ('dev-home git config {0} = {1}' -f $key, $value)
    }
    elseif ($script:Cmdlet.ShouldProcess("git config --local $key in $ContentRoot", "Set to $value")) {
        if ((Invoke-Tool -FilePath 'git' -Arguments @('-C', $ContentRoot, 'config', '--local', $key, $value)).ExitCode -eq 0) {
            Write-Status -State SET -Message ('dev-home git config {0} = {1}' -f $key, $value)
        }
        else {
            Write-Status -State PROBLEM -Message ('Could not set git config {0} in {1}.' -f $key, $ContentRoot)
        }
    }
}

# 3. Generated files: the skills and core rules with this PC's paths filled in.

$skillSources = @(Get-ChildItem -LiteralPath (Join-Path $ToolsRoot 'skills') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
$generatedSkills = Join-Path $GeneratedRoot 'skills'
foreach ($skill in $skillSources) {
    $destination = Join-Path $generatedSkills $skill.Name
    $skillValues = $Values.Clone()
    $skillValues['SKILL_DIR'] = ConvertTo-ForwardPath -Path $destination
    Sync-GeneratedFolder -Source $skill.FullName -Destination $destination -Values $skillValues
}
if (Test-Path -LiteralPath $generatedSkills) {
    foreach ($folder in @(Get-ChildItem -LiteralPath $generatedSkills -Directory)) {
        if ($skillSources.Name -notcontains $folder.Name) {
            Sync-GeneratedFolder -Destination $folder.FullName -Values $Values
        }
    }
}
Sync-GeneratedFolder -Source (Join-Path $ToolsRoot 'rules') -Destination (Join-Path $GeneratedRoot 'rules') -Values $Values

# A folder here with no templates, such as one left from an older layout, is removed.
if (Test-Path -LiteralPath $GeneratedRoot) {
    foreach ($folder in @(Get-ChildItem -LiteralPath $GeneratedRoot -Directory -Force)) {
        if (@('skills', 'rules') -notcontains $folder.Name) {
            Sync-GeneratedFolder -Destination $folder.FullName -Values $Values
        }
    }
}

$note = "Setup writes everything in this folder from the templates in skills/ and rules/, with`nthis PC's paths filled in. Don't edit it: the next setup run rewrites it.`n"
$notePath = Join-Path $GeneratedRoot 'README.txt'
if (((-not (Test-Path -LiteralPath $notePath)) -or ([System.IO.File]::ReadAllText($notePath) -cne $note)) -and
    (Test-Path -LiteralPath $GeneratedRoot) -and $script:Cmdlet.ShouldProcess($notePath, 'Write a note about this folder')) {
    [System.IO.File]::WriteAllText($notePath, $note, [System.Text.UTF8Encoding]::new($false))
}

foreach ($unknown in ($script:UnknownPlaceholders | Select-Object -Unique)) {
    Write-Status -State PROBLEM -Message ('A placeholder setup does not know, left as it is: {0}' -f $unknown)
}
if ($script:GeneratedChanges -gt 0) {
    Write-Status -State WROTE -Message ('Skills and core rules with this PC''s paths: {0} file(s) changed in {1}' -f $script:GeneratedChanges, $GeneratedRoot)
}
else {
    Write-Status -State OK -Message 'Skills and core rules with this PC''s paths'
}

# 4. Skills, linked into each tool's personal skills folder: the dev-home-tools skills, then
# the personal skills in dev-home.

$codexInstalled = Test-Path -LiteralPath (Join-Path $HomeDir '.codex')
$usingRealHome = (ConvertTo-ComparablePath -Path $HomeDir) -eq (ConvertTo-ComparablePath -Path $HOME)

$defaultClaudeDir = ConvertTo-ComparablePath -Path (Join-Path $HomeDir '.claude')
$claudeCandidates = @($defaultClaudeDir) + @($settings.claudeConfigDirs)
if ($usingRealHome -and $env:CLAUDE_CONFIG_DIR) { $claudeCandidates += $env:CLAUDE_CONFIG_DIR }
$claudeDirs = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in $claudeCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $full = ConvertTo-ComparablePath -Path (Resolve-HomePath -Path $candidate)
    if (($full -ne $defaultClaudeDir) -and (-not (Test-Path -LiteralPath $full))) {
        Write-Status -State PROBLEM -Message ('The Claude folder {0}, listed in {1}, does not exist.' -f $full, $SettingsPath)
        continue
    }
    if ($claudeDirs -notcontains $full) { $claudeDirs.Add($full) }
}

$toolSkillFolders = [System.Collections.Generic.List[string]]::new()
foreach ($claudeDir in $claudeDirs) { $toolSkillFolders.Add((Join-Path $claudeDir 'skills')) }
if ($codexInstalled) { $toolSkillFolders.Add((Join-Path $HomeDir '.agents' 'skills')) }

$links = [System.Collections.Generic.List[object]]::new()
foreach ($skill in $skillSources) {
    $links.Add([pscustomobject]@{ Name = $skill.Name; Target = (Join-Path $generatedSkills $skill.Name) })
}
$personalSkills = Join-Path $ContentRoot 'skills'
if (Test-Path -LiteralPath $personalSkills) {
    foreach ($skill in @(Get-ChildItem -LiteralPath $personalSkills -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })) {
        if ($links.Name -contains $skill.Name) {
            Write-Status -State PROBLEM -Message ("Your personal skill '{0}' has the same name as a dev-home-tools skill, so it isn't linked. Rename its folder and its name field." -f $skill.Name)
            continue
        }
        $links.Add([pscustomobject]@{ Name = $skill.Name; Target = $skill.FullName })
    }
}

# Links into these folders are setup's own, so one whose skill is gone can be removed.
$ownedPrefixes = @($generatedSkills, $personalSkills) | ForEach-Object { (ConvertTo-ComparablePath -Path $_) + [System.IO.Path]::DirectorySeparatorChar }

foreach ($folder in $toolSkillFolders) {
    foreach ($link in $links) {
        Sync-Link -LinkPath (Join-Path $folder $link.Name) -TargetPath $link.Target -Label ("Skill '{0}' in {1}" -f $link.Name, $folder)
    }

    if (-not (Test-Path -LiteralPath $folder)) { continue }
    foreach ($entry in @(Get-ChildItem -LiteralPath $folder -Force)) {
        $link = Get-LinkInfo -Path $entry.FullName
        if (($null -eq $link) -or (-not $link.IsLink) -or (Test-Path -LiteralPath $link.Target)) { continue }
        $owned = @($ownedPrefixes | Where-Object { $link.Target.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ((-not $owned) -or (-not $script:Cmdlet.ShouldProcess($entry.FullName, 'Remove a link to a deleted skill'))) { continue }
        try {
            Remove-FolderLink -LinkPath $entry.FullName
            Write-Status -State REMOVED -Message ('Link to a deleted skill: {0}' -f $entry.FullName)
        }
        catch {
            Write-Status -State PROBLEM -Message ('Could not remove the stale link {0}. {1}' -f $entry.FullName, $_.Exception.Message)
        }
    }
}

# 5. Always-on rules: the core rules from here, and the person's own from dev-home. Claude Code
# loads every file in the rules folder of each Claude folder; Codex reads one file, so setup
# writes the two joined.

$coreRules = Join-Path $GeneratedRoot 'rules'
$personalRules = Join-Path $ContentRoot 'rules'
foreach ($claudeDir in $claudeDirs) {
    $claudeName = Split-Path -Leaf $claudeDir
    Sync-Link -LinkPath (Join-Path $claudeDir 'rules' 'dev-home-tools') -TargetPath $coreRules -Label ('Claude Code core rules in {0}' -f $claudeName)
    if (Test-Path -LiteralPath $personalRules) {
        Sync-Link -LinkPath (Join-Path $claudeDir 'rules' 'dev-home') -TargetPath $personalRules -Label ('Claude Code personal rules in {0}' -f $claudeName)
    }
}
if ($codexInstalled) {
    Sync-CodexRules -CorePath (Join-Path $coreRules 'core.md') -PersonalPath (Join-Path $personalRules 'global.md')
}

# 6. Settings. A missing setting is offered as a change: shown first, made only after a yes, and
# with a backup. See Repair-Setting.

$wantedDirs = @($ContentRoot, (ConvertTo-ComparablePath -Path $ToolsRoot))
foreach ($claudeDir in $claudeDirs) {
    $claudeName = Split-Path -Leaf $claudeDir
    $claudeSettingsPath = Join-Path $claudeDir 'settings.json'
    $present = [System.Collections.Generic.List[string]]::new()
    $claudeReadable = $true
    if (Test-Path -LiteralPath $claudeSettingsPath) {
        try {
            $claudeSettings = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
            if ($null -ne $claudeSettings) {
                $permissions = $claudeSettings.PSObject.Properties['permissions']
                if (($null -ne $permissions) -and ($null -ne $permissions.Value)) {
                    $additional = $permissions.Value.PSObject.Properties['additionalDirectories']
                    if ($null -ne $additional) {
                        foreach ($dir in @($additional.Value)) {
                            if ($dir -is [string]) { $present.Add((ConvertTo-ComparablePath -Path (Resolve-HomePath -Path $dir))) }
                        }
                    }
                }
            }
        }
        catch {
            $claudeReadable = $false
            Write-Status -State PROBLEM -Message ('{0} could not be read as JSON, so its settings were not checked.' -f $claudeSettingsPath)
        }
    }

    $missing = @($wantedDirs | Where-Object { $present -notcontains $_ })
    if ($missing.Count -eq 0) {
        Write-Status -State OK -Message ('Claude Code settings in {0}: additionalDirectories includes dev-home and dev-home-tools' -f $claudeName)
    }
    elseif ($claudeReadable) {
        $plan = $(try { Get-ClaudeSettingsPlan -Path $claudeSettingsPath -Entries $missing } catch { [pscustomobject]@{ Reason = 'planning the change failed ({0})' -f $_.Exception.Message } })
        $entries = ($missing | ForEach-Object { ConvertTo-Json -InputObject $_ }) -join ', '
        Repair-Setting -Subject ('Claude Code settings in {0}' -f $claudeName) -Path $claudeSettingsPath -Plan $plan `
            -Need ('{0} in permissions.additionalDirectories' -f ($missing -join ' and ')) `
            -HowTo 'Merge this into the file. If it already has "permissions", put additionalDirectories inside that block:' `
            -Snippet @"
         {
           "permissions": {
             "additionalDirectories": [$entries]
           }
         }
"@
    }
}

if ($codexInstalled) {
    $codexConfigPath = Join-Path $HomeDir '.codex' 'config.toml'
    $toml = ''
    if (Test-Path -LiteralPath $codexConfigPath) {
        $toml = Get-Content -LiteralPath $codexConfigPath -Raw
        if ($null -eq $toml) { $toml = '' }
    }

    if (Test-CodexConfigText -Text $toml -WritableRoot $ContentRoot -MinDocBytes $CodexDocBytes) {
        Write-Status -State OK -Message 'Codex config: writable_roots and project_doc_max_bytes'
    }
    else {
        $plan = $(try { Get-CodexConfigPlan -Path $codexConfigPath -WritableRoot $ContentRoot -MinDocBytes $CodexDocBytes } catch { [pscustomobject]@{ Reason = 'planning the change failed ({0})' -f $_.Exception.Message } })
        Repair-Setting -Subject 'Codex config' -Path $codexConfigPath -Plan $plan `
            -Need ('dev-home in writable_roots, and project_doc_max_bytes of at least {0} (Codex stops reading AGENTS.md files at 32 KiB by default)' -f $CodexDocBytes) `
            -HowTo 'Merge this into the file. project_doc_max_bytes goes above the first [section]. If the file already has [sandbox_workspace_write], add only the writable_roots line under it:' `
            -Snippet @"
         project_doc_max_bytes = $CodexDocBytes

         [sandbox_workspace_write]
         writable_roots = ['$ContentRoot']
"@
    }
}

# ---------------------------------------------------------------------------------------------

Exit-Setup
