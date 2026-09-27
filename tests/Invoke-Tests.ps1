#Requires -Version 7.2
<#
.SYNOPSIS
    Tests setup.ps1, sync.ps1, update.ps1, and the handoff skill's locate.ps1 end to end, in
    throwaway copies of this repo.

.DESCRIPTION
    Never runs the scripts in this folder. Each group of tests builds a sandbox under
    .test-sandbox/, which git ignores: a copy of this repo's working tree (uncommitted changes
    included), a scratch profile, a dev-home with some content, and local bare repos standing in
    for GitHub. The copy's local-settings.json sets testHomeDir before anything in the copy runs,
    so every setup run from it, including the ones sync.ps1 and update.ps1 start, uses the
    scratch profile instead of yours. Nothing here uses the network or GitHub.

    Prints PASS, FAIL, or SKIP for each check, and exits 1 if any check failed. A group's sandbox
    is deleted when all its checks pass, and kept for a look when one fails, or with -Keep.

    Not covered, so check these by hand: setup's first-run questions, cloning or creating
    dev-home with gh, and answering yes to a settings change.

.PARAMETER Keep
    Keep every sandbox, even when its checks pass.

.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SandboxRoot = Join-Path $RepoRoot '.test-sandbox'
$Pwsh = [System.Environment]::ProcessPath
$script:Checks = 0
$script:Failures = 0
$script:GroupFailed = $false

# ---------------------------------------------------------------------------------------------
# Reporting

function Write-Result {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIP')][string]$State,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Detail = @()
    )
    $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow' }[$State]
    Write-Host ('{0,-5} ' -f $State) -ForegroundColor $color -NoNewline
    Write-Host $Name
    foreach ($line in $Detail) { Write-Host ('      ' + $line) }
}

function Test-Check {
    # Records one check. The detail lines are shown only when it fails.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string[]]$Detail = @()
    )
    $script:Checks++
    if ($Condition) {
        Write-Result -State PASS -Name $Name
        return
    }
    $script:Failures++
    $script:GroupFailed = $true
    Write-Result -State FAIL -Name $Name -Detail $Detail
}

function Test-HasLine {
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Pattern)
    return (@($Lines | Where-Object { $_ -match $Pattern }).Count -gt 0)
}

# ---------------------------------------------------------------------------------------------
# Running things

function Invoke-Git {
    # Runs git for building and checking sandboxes. Stops the tests when git fails.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = @(& git -c core.autocrlf=false -c commit.gpgsign=false @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw ('git {0} failed: {1}' -f ($Arguments -join ' '), ($out -join ' ')) }
    return , $out
}

function Invoke-Script {
    # Runs one of a sandbox copy's scripts in its own process, with input redirected so it can
    # never wait for an answer. Returns the exit code and the output lines.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [string]$Answer = ''
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith(([System.IO.Path]::GetFullPath($SandboxRoot) + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to run $full, which is not in a sandbox."
    }
    $ErrorActionPreference = 'Continue'
    $out = @($Answer | & $Pwsh -NoProfile -File $full @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out }
}

function Invoke-WhileAsking {
    # Runs one of a sandbox copy's scripts, waits for the output line that comes just before its
    # question, runs the Meanwhile block, then answers. Returns the exit code and the output lines.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Answer,
        [Parameter(Mandatory)][scriptblock]$Meanwhile
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith(([System.IO.Path]::GetFullPath($SandboxRoot) + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to run $full, which is not in a sandbox."
    }
    $info = [System.Diagnostics.ProcessStartInfo]::new($Pwsh)
    foreach ($argument in @('-NoProfile', '-File', $full)) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        $asked = $false
        while (-not $asked) {
            $read = $process.StandardOutput.ReadLineAsync()
            if ((-not $read.Wait([TimeSpan]::FromSeconds(60))) -or ($null -eq $read.Result)) { break }
            $lines.Add($read.Result)
            $asked = $read.Result -match $Prompt
        }
        if (-not $asked) {
            $process.Kill($true)
            $lines.Add("(the script never reached the line matching $Prompt)")
            return [pscustomobject]@{ ExitCode = -1; Lines = $lines.ToArray() }
        }
        & $Meanwhile
        $process.StandardInput.WriteLine($Answer)
        $process.StandardInput.Close()
        $rest = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill($true)
            $lines.Add('(the script did not finish within 2 minutes)')
            return [pscustomobject]@{ ExitCode = -1; Lines = $lines.ToArray() }
        }
        $lines.AddRange([string[]]($rest.Result -split "\r?\n"))
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = $lines.ToArray() }
    }
    finally {
        $process.Dispose()
    }
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Get-LinkTarget {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.LinkTarget
}

function Test-Link {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )
    $actual = Get-LinkTarget -Path $Link
    $ok = ($null -ne $actual) -and ([System.IO.Path]::GetFullPath($actual).TrimEnd('\', '/') -eq [System.IO.Path]::GetFullPath($Target).TrimEnd('\', '/'))
    Test-Check -Name $Name -Condition $ok -Detail @("expected: $Link -> $Target", "found: $actual")
}

# ---------------------------------------------------------------------------------------------
# Sandboxes

function New-Sandbox {
    # Builds a sandbox and returns its paths. The copy's local-settings.json, with testHomeDir,
    # is written before anything in the copy can run. With -ToolsRepo, the copy is also a git
    # repo with a remote, and a second clone stands in for the maintainer pushing updates.
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$ToolsRepo
    )
    $root = Join-Path $SandboxRoot ('{0}-{1}' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $box = [pscustomobject]@{
        Root        = $root
        Tools       = Join-Path $root 'tools'
        Profile     = Join-Path $root 'profile'
        Content     = Join-Path $root 'dev-home'
        Remote      = Join-Path $root 'dev-home-remote.git'
        ToolsRemote = Join-Path $root 'tools-remote.git'
        Upstream    = Join-Path $root 'tools-upstream'
    }

    # The copy: this repo's working tree, without its git data, generated files, settings, or
    # sandboxes.
    New-Item -ItemType Directory -Path $box.Tools | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $RepoRoot -Force)) {
        if ($item.Name -in @('.git', '.generated', 'local-settings.json', '.test-sandbox')) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $box.Tools -Recurse -Force
    }
    $settings = [ordered]@{
        contentDir       = $box.Content.Replace('\', '/')
        autoUpdate       = $false
        claudeConfigDirs = @()
        testHomeDir      = $box.Profile.Replace('\', '/')
    }
    Write-TextFile -Path (Join-Path $box.Tools 'local-settings.json') -Text ($settings | ConvertTo-Json)

    # A scratch profile whose settings already have what setup checks for, so a clean run
    # exits 0.
    $claudeSettings = [ordered]@{ permissions = [ordered]@{ additionalDirectories = @($box.Content, $box.Tools) } }
    Write-TextFile -Path (Join-Path $box.Profile '.claude/settings.json') -Text ($claudeSettings | ConvertTo-Json -Depth 5)
    Write-TextFile -Path (Join-Path $box.Profile '.codex/config.toml') -Text ("project_doc_max_bytes = 65536`n`n[sandbox_workspace_write]`nwritable_roots = ['{0}']`n" -f $box.Content)

    # dev-home, with a remote and some content.
    Invoke-Git @('init', '--quiet', '--bare', '-b', 'main', $box.Remote) | Out-Null
    Invoke-Git @('clone', '--quiet', $box.Remote, $box.Content) | Out-Null
    $files = [ordered]@{
        'rules/global.md'          = "# My rules`n`n- Personal rule one.`n"
        'knowledge/README.md'      = "# Knowledge base`n"
        'handoffs/demo/HANDOFF.md' = "# demo handoff`n"
        'skills/mine/SKILL.md'     = "---`nname: mine`ndescription: A personal test skill.`n---`n"
    }
    foreach ($relative in $files.Keys) { Write-TextFile -Path (Join-Path $box.Content $relative) -Text $files[$relative] }
    Invoke-Git (@('-C', $box.Content, 'add', '--') + @($files.Keys)) | Out-Null
    Invoke-Git @('-C', $box.Content, 'commit', '--quiet', '-m', 'test: content') | Out-Null
    Invoke-Git @('-C', $box.Content, 'push', '--quiet', '-u', 'origin', 'main') | Out-Null

    if ($ToolsRepo) {
        Invoke-Git @('-C', $box.Tools, 'init', '--quiet', '-b', 'main') | Out-Null
        Invoke-Git @('-C', $box.Tools, 'add', '-A') | Out-Null
        Invoke-Git @('-C', $box.Tools, 'commit', '--quiet', '-m', 'test: tools') | Out-Null
        Invoke-Git @('init', '--quiet', '--bare', '-b', 'main', $box.ToolsRemote) | Out-Null
        Invoke-Git @('-C', $box.Tools, 'remote', 'add', 'origin', $box.ToolsRemote) | Out-Null
        Invoke-Git @('-C', $box.Tools, 'push', '--quiet', '-u', 'origin', 'main') | Out-Null
        Invoke-Git @('clone', '--quiet', $box.ToolsRemote, $box.Upstream) | Out-Null
    }
    return $box
}

function Remove-Sandbox {
    # Deletes a sandbox. Links go first, one by one and without following them, so deleting the
    # rest can't reach anything a link points to.
    param([Parameter(Mandatory)][string]$Root)
    $full = [System.IO.Path]::GetFullPath($Root)
    if (-not $full.StartsWith(([System.IO.Path]::GetFullPath($SandboxRoot) + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete $full, which is not in $SandboxRoot."
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Recurse -Force -Attributes ReparsePoint)) {
        if ($item.PSIsContainer) { [System.IO.Directory]::Delete($item.FullName, $false) }
        else { [System.IO.File]::Delete($item.FullName) }
    }
    Remove-Item -LiteralPath $full -Recurse -Force
    if (@(Get-ChildItem -LiteralPath $SandboxRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $SandboxRoot -Force }
}

function Complete-Group {
    param([Parameter(Mandatory)]$Box)
    if ($Keep -or $script:GroupFailed) {
        Write-Host ('      Sandbox kept: {0}' -f $Box.Root)
    }
    else {
        Remove-Sandbox -Root $Box.Root
    }
}

function Test-RealProfile {
    # The point of the sandbox: nothing in the real profile may point into it.
    param([Parameter(Mandatory)]$Box)
    $hits = [System.Collections.Generic.List[string]]::new()
    $sandbox = [System.IO.Path]::GetFullPath($SandboxRoot)
    $folders = @(Join-Path $HOME '.agents' 'skills')
    foreach ($claude in @(Get-ChildItem -LiteralPath $HOME -Directory -Force -Filter '.claude*' -ErrorAction SilentlyContinue)) {
        $folders += Join-Path $claude.FullName 'skills'
        $folders += Join-Path $claude.FullName 'rules'
    }
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $folder -Force)) {
            $target = $item.LinkTarget
            if ($target -and [System.IO.Path]::GetFullPath($target).StartsWith($sandbox, [System.StringComparison]::OrdinalIgnoreCase)) {
                $hits.Add(('{0} -> {1}' -f $item.FullName, $target))
            }
        }
    }
    $codexRules = Join-Path $HOME '.codex' 'AGENTS.md'
    if (Test-Path -LiteralPath $codexRules) {
        $text = Get-Content -LiteralPath $codexRules -Raw -ErrorAction SilentlyContinue
        if ($text -and ($text.Contains($Box.Root) -or $text.Contains($Box.Root.Replace('\', '/')))) { $hits.Add($codexRules) }
    }
    Test-Check -Name 'your real profile has nothing pointing into the sandbox' -Condition ($hits.Count -eq 0) -Detail $hits
}

# ---------------------------------------------------------------------------------------------
# setup.ps1

function Test-Setup {
    Write-Host
    Write-Host 'setup.ps1' -ForegroundColor Cyan
    $script:GroupFailed = $false
    $box = New-Sandbox -Name 'setup'
    $setup = Join-Path $box.Tools 'setup.ps1'
    $generated = Join-Path $box.Tools '.generated'
    $toolsForward = $box.Tools.Replace('\', '/')
    $codexRules = Join-Path $box.Profile '.codex/AGENTS.md'
    $settingsPath = Join-Path $box.Tools 'local-settings.json'

    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'first run exits 0' ($run.ExitCode -eq 0) $run.Lines
    Test-Check 'says it is using the test profile' (Test-HasLine $run.Lines '^TEST\s') $run.Lines

    $leftover = @(Get-ChildItem -LiteralPath $generated -Recurse -File -ErrorAction SilentlyContinue | Select-String -Pattern '\{\{[A-Z_]+\}\}')
    Test-Check 'fills in every placeholder' ((Test-Path -LiteralPath "$generated/skills/handoff/SKILL.md") -and ($leftover.Count -eq 0)) @($leftover | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber })
    $skill = Get-Content -LiteralPath "$generated/skills/handoff/SKILL.md" -Raw
    Test-Check 'writes the copy''s path into the pre-approvals' ($skill.Contains("Bash(pwsh -NoProfile -File $toolsForward/sync.ps1)"))
    Test-Check 'points the handoff skill at its generated template' ($skill.Contains("$toolsForward/.generated/skills/handoff/template.md"))

    foreach ($folder in @('.claude/skills', '.agents/skills')) {
        Test-Link "links the handoff skill in $folder" (Join-Path $box.Profile "$folder/handoff") (Join-Path $generated 'skills/handoff')
        Test-Link "links the knowledge skill in $folder" (Join-Path $box.Profile "$folder/knowledge") (Join-Path $generated 'skills/knowledge')
        Test-Link "links the personal skill in $folder" (Join-Path $box.Profile "$folder/mine") (Join-Path $box.Content 'skills/mine')
    }
    Test-Link 'links the core rules for Claude Code' (Join-Path $box.Profile '.claude/rules/dev-home-tools') (Join-Path $generated 'rules')
    Test-Link 'links the personal rules for Claude Code' (Join-Path $box.Profile '.claude/rules/dev-home') (Join-Path $box.Content 'rules')

    $codex = Get-Content -LiteralPath $codexRules -Raw
    $core = $codex.IndexOf('# Private repo: dev-home (rules loaded)')
    $personal = $codex.IndexOf('- Personal rule one.')
    Test-Check 'writes Codex''s rules: the marker, then the core rules, then the personal ones' ($codex.StartsWith('<!-- Written by dev-home-tools setup.ps1') -and ($core -gt 0) -and ($personal -gt $core)) @($codex)

    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    $other = @($run.Lines | Where-Object { $_ -notmatch '^TEST\s' })
    Test-Check 'a second run changes nothing and prints nothing else' (($run.ExitCode -eq 0) -and ($other.Count -eq 0)) $run.Lines

    Copy-Item -LiteralPath (Join-Path $box.Profile '.claude/settings.json') -Destination (Join-Path $box.Root 'claude-settings.json')
    Copy-Item -LiteralPath (Join-Path $box.Profile '.codex/config.toml') -Destination (Join-Path $box.Root 'config.toml')
    Write-TextFile -Path (Join-Path $box.Profile '.claude/settings.json') -Text "{}`n"
    Write-TextFile -Path (Join-Path $box.Profile '.codex/config.toml') -Text ''
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'reports missing settings without changing them' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'additionalDirectories') -and (Test-HasLine $run.Lines 'writable_roots') -and ((Get-Content -LiteralPath (Join-Path $box.Profile '.claude/settings.json') -Raw) -eq "{}`n")) $run.Lines
    Copy-Item -LiteralPath (Join-Path $box.Root 'claude-settings.json') -Destination (Join-Path $box.Profile '.claude/settings.json') -Force
    Copy-Item -LiteralPath (Join-Path $box.Root 'config.toml') -Destination (Join-Path $box.Profile '.codex/config.toml') -Force

    $coreTemplate = Join-Path $box.Tools 'rules/core.md'
    Add-Content -LiteralPath $coreTemplate -Value '- A line added to the core rules.'
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'a changed template reaches the generated copy and Codex''s rules' ((Get-Content -LiteralPath $codexRules -Raw).Contains('A line added to the core rules.') -and (Get-Content -LiteralPath "$generated/rules/core.md" -Raw).Contains('A line added to the core rules.')) $run.Lines

    # A generated folder from an older layout, with the core rules link still pointing into it.
    $oldCore = Join-Path $generated 'instructions'
    Write-TextFile -Path (Join-Path $oldCore 'core.md') -Text "old core rules`n"
    $coreLink = Join-Path $box.Profile '.claude/rules/dev-home-tools'
    [System.IO.Directory]::Delete($coreLink, $false)
    New-Item -ItemType Junction -Path $coreLink -Target $oldCore | Out-Null
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'removes a generated folder that has no templates' (($run.ExitCode -eq 0) -and (-not (Test-Path -LiteralPath $oldCore))) $run.Lines
    Test-Link 'moves the core rules link off the removed folder' $coreLink (Join-Path $generated 'rules')

    # Two paths in a skill: one starts as a file and becomes a folder, the other the reverse.
    $toFolder = Join-Path $box.Tools 'skills/handoff/to-folder'
    $toFile = Join-Path $box.Tools 'skills/handoff/to-file'
    Write-TextFile -Path $toFolder -Text "a file`n"
    Write-TextFile -Path (Join-Path $toFile 'inner.md') -Text "a folder`n"
    Invoke-Script -Path $setup -Arguments @('-Quiet') | Out-Null
    [System.IO.File]::Delete($toFolder)
    Write-TextFile -Path (Join-Path $toFolder 'inner.md') -Text "now a folder`n"
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'a template file that becomes a folder is set up' (($run.ExitCode -eq 0) -and (Test-Path -LiteralPath "$generated/skills/handoff/to-folder/inner.md" -PathType Leaf)) $run.Lines
    [System.IO.Directory]::Delete($toFile, $true)
    Write-TextFile -Path $toFile -Text "now a file`n"
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'a template folder that becomes a file is set up' (($run.ExitCode -eq 0) -and (Test-Path -LiteralPath "$generated/skills/handoff/to-file" -PathType Leaf)) $run.Lines
    [System.IO.File]::Delete($toFile)
    [System.IO.Directory]::Delete($toFolder, $true)

    [System.IO.Directory]::Delete((Join-Path $box.Tools 'skills/knowledge'), $true)
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'a removed skill loses its generated copy and its links' ((-not (Test-Path -LiteralPath "$generated/skills/knowledge")) -and ($null -eq (Get-LinkTarget (Join-Path $box.Profile '.claude/skills/knowledge'))) -and ($null -eq (Get-LinkTarget (Join-Path $box.Profile '.agents/skills/knowledge')))) $run.Lines

    $handoffLink = Join-Path $box.Profile '.claude/skills/handoff'
    [System.IO.Directory]::Delete($handoffLink, $false)
    $gone = Join-Path $box.Root 'gone'
    New-Item -ItemType Directory -Path $gone | Out-Null
    New-Item -ItemType Junction -Path $handoffLink -Target $gone | Out-Null
    [System.IO.Directory]::Delete($gone, $false)
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Link 'replaces a link whose target is gone' $handoffLink (Join-Path $generated 'skills/handoff')

    Write-TextFile -Path $codexRules -Text "my own codex rules`n"
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'leaves alone a Codex rules file it did not write' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'setup did not write it') -and ((Get-Content -LiteralPath $codexRules -Raw) -eq "my own codex rules`n")) $run.Lines
    [System.IO.File]::Delete($codexRules)

    $madeLink = $false
    try {
        New-Item -ItemType SymbolicLink -Path $codexRules -Target (Join-Path $box.Content 'rules/global.md') -ErrorAction Stop | Out-Null
        $madeLink = $true
    }
    catch {
        Write-Result -State SKIP -Name 'leaves alone a Codex rules link whose target exists' -Detail @('Creating a file symlink needs admin rights or Developer Mode on this PC.')
    }
    if ($madeLink) {
        $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
        Test-Check 'leaves alone a Codex rules link whose target exists' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'Left alone') -and ($null -ne (Get-LinkTarget $codexRules))) $run.Lines
        [System.IO.File]::Delete($codexRules)
    }

    $handoffTemplate = Join-Path $box.Tools 'skills/handoff/template.md'
    $templateText = Get-Content -LiteralPath $handoffTemplate -Raw
    Add-Content -LiteralPath $handoffTemplate -Value '{{NOT_A_PLACEHOLDER}}'
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'reports a placeholder it does not know' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'NOT_A_PLACEHOLDER')) $run.Lines
    Write-TextFile -Path $handoffTemplate -Text $templateText

    Write-TextFile -Path (Join-Path $box.Content 'skills/handoff/SKILL.md') -Text "---`nname: handoff`ndescription: A clash.`n---`n"
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'reports a personal skill with a dev-home-tools skill''s name, and keeps the tooling one' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'same name') -and ((Get-LinkTarget $handoffLink) -like '*.generated*')) $run.Lines
    Remove-Item -LiteralPath (Join-Path $box.Content 'skills/handoff') -Recurse -Force

    $before = Get-Content -LiteralPath $settingsPath -Raw
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet', '-ContentDir', (Join-Path $box.Root 'has space'))
    Test-Check 'refuses a dev-home path with a space, and keeps the settings' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'space') -and ((Get-Content -LiteralPath $settingsPath -Raw) -eq $before)) $run.Lines

    $run = Invoke-Script -Path $setup -Arguments @('-Quiet', '-ContentDir', (Join-Path $box.Root 'another-dev-home'))
    $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Test-Check 'saving a new dev-home folder keeps testHomeDir' (($saved.contentDir -like '*another-dev-home') -and ($saved.testHomeDir -eq $box.Profile.Replace('\', '/'))) $run.Lines
    Test-Check 'with -Quiet, reports a missing dev-home instead of asking' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'There is no dev-home')) $run.Lines
    Write-TextFile -Path $settingsPath -Text $before

    # What a first run leaves behind when git init worked but the commit didn't.
    $unfinished = Join-Path $box.Root 'unfinished-dev-home'
    Invoke-Git @('init', '--quiet', '-b', 'main', $unfinished) | Out-Null
    Write-TextFile -Path (Join-Path $unfinished 'README.md') -Text "# dev-home`n"
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet', '-ContentDir', $unfinished)
    Test-Check 'reports a dev-home repo with no commits instead of carrying on' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'no commits')) $run.Lines
    Write-TextFile -Path $settingsPath -Text $before

    # A dev-home git refuses to read says nothing about its contents, so no advice to delete it.
    $unreadable = Join-Path $box.Root 'unreadable-dev-home'
    Invoke-Git @('init', '--quiet', '-b', 'main', $unreadable) | Out-Null
    Invoke-Git @('-C', $unreadable, 'commit', '--quiet', '--allow-empty', '-m', 'test: content') | Out-Null
    Add-Content -LiteralPath (Join-Path $unreadable '.git/config') -Value '[broken'
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet', '-ContentDir', $unreadable)
    Test-Check 'reports a dev-home git can''t read, without advice to delete it' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'could not read') -and (-not (Test-HasLine $run.Lines 'delete'))) $run.Lines
    Write-TextFile -Path $settingsPath -Text $before

    # Hand-edited, because setup itself never saves a path that fails its checks.
    $settings = $before | ConvertFrom-Json
    $settings.contentDir = [System.IO.Path]::GetPathRoot($box.Root).Replace('\', '/')
    Write-TextFile -Path $settingsPath -Text ($settings | ConvertTo-Json)
    Push-Location -LiteralPath $box.Root
    try { $run = Invoke-Script -Path $setup -Arguments @('-Quiet') } finally { Pop-Location }
    Test-Check 'refuses a dev-home at the root of a drive' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'root of a drive')) $run.Lines
    Write-TextFile -Path $settingsPath -Text $before

    Test-SettingsPlans -Box $box
    Test-RealProfile -Box $box
    Complete-Group -Box $box
}

function Test-SettingsPlans {
    # Loads setup's settings functions from the copy without running it, and plans changes for
    # several starting files.
    param([Parameter(Mandatory)]$Box)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Box.Tools 'setup.ps1'), [ref]$null, [ref]$null)
    $names = @('ConvertTo-ComparablePath', 'Get-LinkTargetOrNull', 'Get-LinkInfo', 'Read-SettingsFile', 'ConvertTo-Lines',
        'Get-ClaudeSettingsPlan', 'Get-TomlPathPattern', 'Get-TomlMaskedLine', 'Get-TomlDepthChange', 'Read-TomlLayout',
        'Get-TomlValueText', 'Test-CodexConfigText', 'Get-CodexConfigPlan')
    foreach ($function in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($names -contains $function.Name) { . ([scriptblock]::Create($function.Extent.Text)) }
    }
    $work = Join-Path $Box.Root 'plans'
    New-Item -ItemType Directory -Path $work | Out-Null
    $entries = @('C:\Users\you\dev-home', 'C:\Users\you\dev-home-tools')

    $plan = Get-ClaudeSettingsPlan -Path (Join-Path $work 'missing.json') -Entries $entries
    Test-Check 'Claude settings: plans a new file with both folders' ((-not $plan.Reason) -and ((@(($plan.NewText | ConvertFrom-Json).permissions.additionalDirectories) -join '|') -eq ($entries -join '|'))) @($plan.Reason, $plan.NewText)

    $path = Join-Path $work 'existing.json'
    [System.IO.File]::WriteAllText($path, "{`r`n  `"permissions`": {`r`n    `"additionalDirectories`": [`"D:\\Other`"]`r`n  }`r`n}`r`n")
    $plan = Get-ClaudeSettingsPlan -Path $path -Entries $entries
    Test-Check 'Claude settings: adds after an existing entry, and keeps CRLF' ((-not $plan.Reason) -and ((@(($plan.NewText | ConvertFrom-Json).permissions.additionalDirectories) -join '|') -eq ('D:\Other|' + ($entries -join '|'))) -and $plan.NewText.Contains("`r`n")) @($plan.Reason, $plan.NewText)

    $path = Join-Path $work 'comments.json'
    [System.IO.File]::WriteAllText($path, "{`n  // a comment`n  `"model`": `"x`"`n}`n")
    $plan = Get-ClaudeSettingsPlan -Path $path -Entries $entries
    Test-Check 'Claude settings: refuses a file with comments' ([bool]$plan.Reason) @($plan.NewText)

    $CodexDocBytes = 65536
    $script:CodexRoot = 'C:\Users\you\dev-home'
    $script:CodexRootPattern = Get-TomlPathPattern -Path $script:CodexRoot
    $path = Join-Path $work 'empty.toml'
    [System.IO.File]::WriteAllText($path, '')
    $plan = Get-CodexConfigPlan -Path $path
    Test-Check 'Codex config: plans both settings for an empty file' ((-not $plan.Reason) -and $plan.NewText.Contains("writable_roots = ['C:\Users\you\dev-home']") -and $plan.NewText.Contains('project_doc_max_bytes = 65536')) @($plan.Reason, $plan.NewText)

    $path = Join-Path $work 'other.toml'
    [System.IO.File]::WriteAllText($path, "model = `"x`"`n`n[sandbox_workspace_write]`nwritable_roots = ['D:\Other']`n")
    $plan = Get-CodexConfigPlan -Path $path
    Test-Check 'Codex config: adds to an existing writable_roots list' ((-not $plan.Reason) -and $plan.NewText.Contains("writable_roots = ['D:\Other', 'C:\Users\you\dev-home']")) @($plan.Reason, $plan.NewText)

    Test-Check 'Codex config: a forward-slash path counts as present' (Test-CodexConfigText -Text "project_doc_max_bytes = 70000`n`n[sandbox_workspace_write]`nwritable_roots = [`"C:/Users/you/dev-home`"]`n")
    Test-Check 'Codex config: a longer path that starts the same does not count' (-not (Test-CodexConfigText -Text "project_doc_max_bytes = 70000`n`n[sandbox_workspace_write]`nwritable_roots = ['C:\Users\you\dev-home-tools']`n"))
}

# ---------------------------------------------------------------------------------------------
# sync.ps1 and update.ps1

function Test-Sync {
    Write-Host
    Write-Host 'sync.ps1 and update.ps1' -ForegroundColor Cyan
    $script:GroupFailed = $false
    $box = New-Sandbox -Name 'sync' -ToolsRepo
    $sync = Join-Path $box.Tools 'sync.ps1'
    $update = Join-Path $box.Tools 'update.ps1'
    $settingsPath = Join-Path $box.Tools 'local-settings.json'
    $generatedSkill = Join-Path $box.Tools '.generated/skills/handoff/SKILL.md'
    $upstreamSkill = Join-Path $box.Upstream 'skills/handoff/SKILL.md'

    $run = Invoke-Script -Path (Join-Path $box.Tools 'setup.ps1') -Arguments @('-Quiet')
    Test-Check 'setup runs cleanly first' ($run.ExitCode -eq 0) $run.Lines

    $run = Invoke-Script -Path $sync
    Test-Check 'a plain sync says dev-home is up to date' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines 'up to date') -and (-not (Test-HasLine $run.Lines '^(UPDATE|PROBLEM)\s'))) $run.Lines

    Add-Content -LiteralPath (Join-Path $box.Content 'handoffs/demo/HANDOFF.md') -Value 'A new line.'
    Write-TextFile -Path (Join-Path $box.Content 'notes.md') -Text "someone else's file`n"
    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'handoff: demo', 'handoffs/demo/HANDOFF.md')
    $pushed = (Invoke-Git @('-C', $box.Remote, 'log', '-1', '--format=%s', 'main'))[0]
    $untracked = Invoke-Git @('-C', $box.Content, 'status', '--porcelain')
    Test-Check 'commits and pushes only the named file' (($run.ExitCode -eq 0) -and ($pushed -eq 'handoff: demo') -and (Test-HasLine $untracked '^\?\? notes\.md')) $run.Lines
    Test-Check 'lists the other new file as LEFT' (Test-HasLine $run.Lines '^LEFT\s+notes\.md') $run.Lines
    [System.IO.File]::Delete((Join-Path $box.Content 'notes.md'))

    Add-Content -LiteralPath $upstreamSkill -Value 'Upstream change one.'
    Invoke-Git @('-C', $box.Upstream, 'commit', '--quiet', '-am', 'handoff: change one') | Out-Null
    Invoke-Git @('-C', $box.Upstream, 'push', '--quiet') | Out-Null
    $run = Invoke-Script -Path $sync
    Test-Check 'with autoUpdate off, reports a waiting update and pulls nothing' ((Test-HasLine $run.Lines '^UPDATE\s') -and (-not (Get-Content -LiteralPath $generatedSkill -Raw).Contains('Upstream change one.'))) $run.Lines

    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $settings.autoUpdate = $true
    Write-TextFile -Path $settingsPath -Text ($settings | ConvertTo-Json)
    $run = Invoke-Script -Path $sync
    Test-Check 'with autoUpdate on, pulls the update and sets it up' ((Test-HasLine $run.Lines '^PULLED\s+1 commit to dev-home-tools') -and (Get-Content -LiteralPath $generatedSkill -Raw).Contains('Upstream change one.')) $run.Lines
    $settings.autoUpdate = $false
    Write-TextFile -Path $settingsPath -Text ($settings | ConvertTo-Json)

    $run = Invoke-Script -Path $update
    Test-Check 'update.ps1 with nothing waiting says so' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines 'up to date')) $run.Lines

    Add-Content -LiteralPath $upstreamSkill -Value 'Upstream change two.'
    Invoke-Git @('-C', $box.Upstream, 'commit', '--quiet', '-am', 'handoff: change two') | Out-Null
    Invoke-Git @('-C', $box.Upstream, 'push', '--quiet') | Out-Null
    $run = Invoke-Script -Path $update -Answer 'n'
    Test-Check 'update.ps1 shows the waiting commit, and a no pulls nothing' ((Test-HasLine $run.Lines 'change two') -and (Test-HasLine $run.Lines 'Nothing was pulled') -and (-not (Get-Content -LiteralPath $generatedSkill -Raw).Contains('Upstream change two.'))) $run.Lines
    $run = Invoke-Script -Path $update -Answer 'y'
    Test-Check 'update.ps1 with a yes pulls and sets it up' (($run.ExitCode -eq 0) -and (Get-Content -LiteralPath $generatedSkill -Raw).Contains('Upstream change two.')) $run.Lines

    # A sync in another session fetches a newer commit while update.ps1 waits for its answer.
    Add-Content -LiteralPath $upstreamSkill -Value 'Upstream change three.'
    Invoke-Git @('-C', $box.Upstream, 'commit', '--quiet', '-am', 'handoff: change three') | Out-Null
    Invoke-Git @('-C', $box.Upstream, 'push', '--quiet') | Out-Null
    $run = Invoke-WhileAsking -Path $update -Prompt '^To see every changed line first' -Answer 'y' -Meanwhile {
        Add-Content -LiteralPath $upstreamSkill -Value 'Upstream change four.'
        Invoke-Git @('-C', $box.Upstream, 'commit', '--quiet', '-am', 'handoff: change four') | Out-Null
        Invoke-Git @('-C', $box.Upstream, 'push', '--quiet') | Out-Null
        Invoke-Git @('-C', $box.Tools, 'fetch', '--quiet') | Out-Null
    }
    $head = (Invoke-Git @('-C', $box.Tools, 'log', '-1', '--format=%s'))[0]
    $skillText = Get-Content -LiteralPath $generatedSkill -Raw
    Test-Check 'update.ps1 pulls only the commits it showed, even if newer ones arrive while it asks' (($run.ExitCode -eq 0) -and ($head -eq 'handoff: change three') -and $skillText.Contains('Upstream change three.') -and (-not $skillText.Contains('Upstream change four.'))) (@("HEAD: $head") + $run.Lines)

    Invoke-Git @('-C', $box.Tools, 'branch', '--quiet', '--unset-upstream') | Out-Null
    $run = Invoke-Script -Path $sync
    Test-Check 'a tooling clone with no upstream is skipped quietly' (($run.ExitCode -eq 0) -and (-not (Test-HasLine $run.Lines '^(UPDATE|OFFLINE)\s'))) $run.Lines

    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'no area', 'handoffs/demo/HANDOFF.md')
    Test-Check 'refuses a commit message without an area' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines '<area>: <what>')) $run.Lines
    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'handoff: demo', 'handoffs')
    Test-Check 'refuses to commit a folder' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'is a folder')) $run.Lines
    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'handoff: demo', '../outside.md')
    Test-Check 'refuses a path outside dev-home' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'not inside dev-home')) $run.Lines

    $hidden = $settingsPath + '.off'
    [System.IO.File]::Move($settingsPath, $hidden)
    $run = Invoke-Script -Path $sync
    Test-Check 'without local-settings.json, says to run setup' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'not set up on this PC')) $run.Lines
    [System.IO.File]::Move($hidden, $settingsPath)

    Test-RealProfile -Box $box
    Complete-Group -Box $box
}

# ---------------------------------------------------------------------------------------------
# The handoff skill's locate.ps1

function Invoke-Locate {
    # Runs locate.ps1 in a folder. Returns the exit code, the output lines, and the values printed.
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Folder
    )
    Push-Location -LiteralPath $Folder
    try { $run = Invoke-Script -Path $Script } finally { Pop-Location }
    $values = @{}
    foreach ($line in $run.Lines) {
        if ($line -match '^(\w+): (.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Lines = $run.Lines; Values = $values }
}

function Get-TestFirstCommit {
    # The start of a repo's first commit on the main line, worked out here without locate.ps1.
    param([Parameter(Mandatory)][string]$Repo)
    return (Invoke-Git @('-C', $Repo, 'rev-list', '--first-parent', '--max-parents=0', 'HEAD'))[0].Substring(0, 7)
}

function Test-Locate {
    Write-Host
    Write-Host 'handoff skill: locate.ps1' -ForegroundColor Cyan
    $script:GroupFailed = $false
    $box = New-Sandbox -Name 'locate'
    $run = Invoke-Script -Path (Join-Path $box.Tools 'setup.ps1') -Arguments @('-Quiet')
    Test-Check 'setup runs cleanly first' ($run.ExitCode -eq 0) $run.Lines
    $locate = Join-Path $box.Tools '.generated/skills/handoff/locate.ps1'

    # Git also looks for a repo in parent folders, and the sandbox is inside this repo.
    $ceiling = $env:GIT_CEILING_DIRECTORIES
    $env:GIT_CEILING_DIRECTORIES = $box.Root.Replace('\', '/')
    try {
        $repo = Join-Path $box.Root 'Sample Repo'
        Invoke-Git @('init', '--quiet', '-b', 'main', $repo) | Out-Null
        Invoke-Git @('-C', $repo, 'commit', '--quiet', '--allow-empty', '-m', 'test: first') | Out-Null
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', 'https://example.com/placeholder.git') | Out-Null
        $id = Get-TestFirstCommit -Repo $repo

        # Each address, and the folder under handoffs/ it should get. {id} stands for the start of
        # the sample repo's first commit.
        $cases = [ordered]@{
            'https://github.com/You/Tool.git'                      = 'github/you/tool'
            'git@github.com:You/Tool.git'                          = 'github/you/tool'
            'ssh://git@github.com/You/Tool'                        = 'github/you/tool'
            'https://user:secret@github.com:443/you/tool/'         = 'github/you/tool'
            'https://gitlab.com/Team/Sub/App.git'                  = 'gitlab/team/sub/app'
            'git@gitlab.com:team/sub/app.git'                      = 'gitlab/team/sub/app'
            'https://someone@bitbucket.org/Space/Repo.git'         = 'bitbucket/space/repo'
            'git@bitbucket.org:space/repo.git'                     = 'bitbucket/space/repo'
            'https://Org@dev.azure.com/Org/My%20Project/_git/Repo' = 'azure-devops/org/my project/repo'
            'git@ssh.dev.azure.com:v3/Org/My%20Project/Repo'       = 'azure-devops/org/my project/repo'
            'https://dev.azure.com/Org/_git/Repo'                  = 'azure-devops/org/repo/repo'
            'https://git.example.com/team/app.git'                 = 'other/sample repo-{id}'
            'git@git.example.com:team/app.git'                     = 'other/sample repo-{id}'
            'https://github.com/just-an-owner'                     = 'other/sample repo-{id}'
            'https://github.com/you/%2E%2E'                        = 'other/sample repo-{id}'
            'https://gitlab.com/team/../../outside'                = 'other/sample repo-{id}'
            'https://github.com/you/to*ol'                         = 'other/sample repo-{id}'
            'C:/repos/tool'                                        = 'local/sample repo-{id}'
            'C:\repos\tool'                                        = 'local/sample repo-{id}'
            'file:///C:/repos/tool'                                = 'local/sample repo-{id}'
            '../tool'                                              = 'local/sample repo-{id}'
        }
        foreach ($address in $cases.Keys) {
            $folder = $cases[$address].Replace('{id}', $id)
            Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', $address) | Out-Null
            $result = Invoke-Locate -Script $locate -Folder $repo
            Test-Check ('files {0} under {1}' -f $address, $folder) (($result.ExitCode -eq 0) -and ($result.Values['handoff'] -ceq "handoffs/$folder/HANDOFF.md")) $result.Lines
        }

        Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', 'https://github.com/You/Tool.git') | Out-Null
        $result = Invoke-Locate -Script $locate -Folder $repo
        $v = $result.Values
        Test-Check 'prints the service, the name, and the draft path' (($v['service'] -ceq 'github') -and ($v['name'] -ceq 'you/tool') -and ($v['draft'] -ceq '.drafts/github/you/tool/issue.md')) $result.Lines
        # The sandbox keeps dev-home beside the sample repo.
        Test-Check 'prints the handoff''s path relative to the project folder' ($v['link'] -ceq '../dev-home/handoffs/github/you/tool/HANDOFF.md') $result.Lines

        Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', 'https://git.example.com/team/app.git') | Out-Null
        $result = Invoke-Locate -Script $locate -Folder $repo
        $v = $result.Values
        Test-Check 'another host: service other, named by folder and first commit' (($v['service'] -ceq 'other') -and ($v['name'] -ceq "sample repo-$id") -and ($v['draft'] -ceq ".drafts/other/sample repo-$id/issue.md")) $result.Lines

        Invoke-Git @('-C', $repo, 'remote', 'remove', 'origin') | Out-Null
        $result = Invoke-Locate -Script $locate -Folder $repo
        $v = $result.Values
        Test-Check 'no origin: service local, named by folder and first commit' (($v['service'] -ceq 'local') -and ($v['name'] -ceq "sample repo-$id") -and ($v['handoff'] -ceq "handoffs/local/sample repo-$id/HANDOFF.md")) $result.Lines

        # Merging in unrelated history gives the repo a second first commit.
        Invoke-Git @('-C', $repo, 'checkout', '--quiet', '--orphan', 'other-history') | Out-Null
        Invoke-Git @('-C', $repo, 'commit', '--quiet', '--allow-empty', '-m', 'test: other history') | Out-Null
        Invoke-Git @('-C', $repo, 'checkout', '--quiet', 'main') | Out-Null
        Invoke-Git @('-C', $repo, 'merge', '--quiet', '--no-ff', '--allow-unrelated-histories', '-m', 'test: merge', 'other-history') | Out-Null
        $roots = Invoke-Git @('-C', $repo, 'rev-list', '--max-parents=0', 'HEAD')
        $result = Invoke-Locate -Script $locate -Folder $repo
        Test-Check 'merged-in unrelated history keeps the main line''s first commit' (($roots.Count -eq 2) -and ($result.Values['handoff'] -ceq "handoffs/local/sample repo-$id/HANDOFF.md")) (@($roots) + $result.Lines)

        $empty = Join-Path $box.Root 'Empty Repo'
        Invoke-Git @('init', '--quiet', '-b', 'main', $empty) | Out-Null
        $result = Invoke-Locate -Script $locate -Folder $empty
        Test-Check 'a repo with no commits yet goes by its folder name alone' ($result.Values['handoff'] -ceq 'handoffs/local/empty repo/HANDOFF.md') $result.Lines

        # A shallow clone's oldest commit is only where the download stopped, not the first one.
        $source = Join-Path $box.Root 'shallow-source'
        Invoke-Git @('init', '--quiet', '-b', 'main', $source) | Out-Null
        Invoke-Git @('-C', $source, 'commit', '--quiet', '--allow-empty', '-m', 'test: one') | Out-Null
        Invoke-Git @('-C', $source, 'commit', '--quiet', '--allow-empty', '-m', 'test: two') | Out-Null
        $shallow = Join-Path $box.Root 'Shallow Clone'
        Invoke-Git @('clone', '--quiet', '--depth', '1', ('file:///' + $source.Replace('\', '/')), $shallow) | Out-Null
        $result = Invoke-Locate -Script $locate -Folder $shallow
        Test-Check 'a shallow clone goes by its folder name alone' ($result.Values['handoff'] -ceq 'handoffs/local/shallow clone/HANDOFF.md') $result.Lines

        $plain = Join-Path $box.Root 'Plain Folder'
        New-Item -ItemType Directory -Path $plain | Out-Null
        $result = Invoke-Locate -Script $locate -Folder $plain
        Test-Check 'a folder outside git goes under local, by its name' ($result.Values['handoff'] -ceq 'handoffs/local/plain folder/HANDOFF.md') $result.Lines

        $main = Join-Path $box.Root 'Main Checkout'
        $worktree = Join-Path $box.Root 'worktree'
        Invoke-Git @('init', '--quiet', '-b', 'main', $main) | Out-Null
        Invoke-Git @('-C', $main, 'commit', '--quiet', '--allow-empty', '-m', 'test: main') | Out-Null
        Invoke-Git @('-C', $main, 'worktree', 'add', '--quiet', $worktree) | Out-Null
        $mainId = Get-TestFirstCommit -Repo $main
        $result = Invoke-Locate -Script $locate -Folder $worktree
        Test-Check 'a worktree with no origin uses its main checkout''s folder name and first commit' ($result.Values['handoff'] -ceq "handoffs/local/main checkout-$mainId/HANDOFF.md") $result.Lines
        Invoke-Git @('-C', $main, 'remote', 'add', 'origin', 'git@github.com:you/tool.git') | Out-Null
        $result = Invoke-Locate -Script $locate -Folder $worktree
        Test-Check 'a worktree uses its main checkout''s origin' ($result.Values['handoff'] -ceq 'handoffs/github/you/tool/HANDOFF.md') $result.Lines

        # When git fails, a guessed path would file the handoff in the wrong place.
        $broken = Join-Path $box.Root 'Broken Repo'
        Invoke-Git @('init', '--quiet', '-b', 'main', $broken) | Out-Null
        Invoke-Git @('-C', $broken, 'commit', '--quiet', '--allow-empty', '-m', 'test: first') | Out-Null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[broken'
        $result = Invoke-Locate -Script $locate -Folder $broken
        Test-Check 'in a repo git can''t read, stops with git''s error instead of guessing' (($result.ExitCode -eq 1) -and (-not $result.Values.ContainsKey('handoff')) -and (Test-HasLine $result.Lines 'bad config')) $result.Lines

        $path = $env:PATH
        $env:PATH = (@($path -split ';' | Where-Object { $_ -and (-not (Test-Path -LiteralPath (Join-Path $_ 'git.exe'))) }) -join ';')
        try { $result = Invoke-Locate -Script $locate -Folder $main } finally { $env:PATH = $path }
        Test-Check 'without git, stops with a message instead of guessing' (($result.ExitCode -eq 1) -and (-not $result.Values.ContainsKey('handoff')) -and (Test-HasLine $result.Lines 'git was not found')) $result.Lines
    }
    finally {
        $env:GIT_CEILING_DIRECTORIES = $ceiling
    }

    Test-RealProfile -Box $box
    Complete-Group -Box $box
}

# ---------------------------------------------------------------------------------------------

Write-Host ('Testing the working tree of {0}' -f $RepoRoot)
Test-Setup
Test-Sync
Test-Locate
Write-Host
if ($script:Failures -gt 0) {
    Write-Host ('{0} of {1} checks failed.' -f $script:Failures, $script:Checks) -ForegroundColor Red
    exit 1
}
Write-Host ('All {0} checks passed.' -f $script:Checks) -ForegroundColor Green
exit 0
