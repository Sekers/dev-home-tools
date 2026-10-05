#Requires -Version 7.2
<#
.SYNOPSIS
    Tests setup.ps1 end to end, in throwaway copies of this repo, and checks the PowerShell files
    in internal/shared/, which it loads, and the links in README.md and docs/.

.DESCRIPTION
    pytest runs this script, one group at a time, beside the Python tests in this folder,
    which cover the Python scripts. The groups here move to pytest as the scripts they test move
    to Python.

    Never runs the scripts in this repo. Each group of tests builds a sandbox under
    internal/development/.test-sandbox/, which git ignores: a copy of this repo's working tree
    (uncommitted changes included, development tools left out), a scratch profile, a dev-home
    with some content, and local bare repos standing in for GitHub. The copy's
    local-settings.json sets testHomeDir before anything in the copy runs, so every setup run
    from it uses the scratch profile instead of yours. The scratch profile's Python install manager folder is a junction to a real
    Python, which setup links the copy's internal/.python to. Nothing here uses the network or
    GitHub.

    Prints PASS, FAIL, or SKIP for each check, and exits 1 if any check failed. A group's sandbox
    is deleted when all its checks pass, and kept for a look when one fails, or with -Keep.

    Not covered, so check these by hand: setup's first-run questions, cloning or creating
    dev-home with gh, answering yes to a settings change, and finding a Python through the
    registry, which a test profile skips.

.PARAMETER Group
    The groups to run: setup, shared, docs. All of them when left out.

.PARAMETER PythonDir
    A folder holding a Python 3.12 or later as python.exe, for the sandboxes' Python install
    manager folder. pytest passes its own base Python. When left out, the real install manager's
    shortcut folder.

.PARAMETER Keep
    Keep every sandbox, even when its checks pass.

.EXAMPLE
    pwsh -NoProfile -File internal/development/tests/Invoke-Tests.ps1 -Group setup
#>
[CmdletBinding()]
param(
    [ValidateSet('setup', 'shared', 'docs')]
    [string[]]$Group = @('setup', 'shared', 'docs'),
    [string]$PythonDir = (Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'Python' 'bin'),
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

# This file is in internal/development/tests/, three folders below the repo's root.
$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$SandboxRoot = Join-Path $RepoRoot 'internal/development/.test-sandbox'
$Pwsh = [System.Environment]::ProcessPath
# What New-Sandbox leaves out of the copy, by its path in the repo: what belongs to this PC
# (including the Python link, which would copy the Python install), and everything for
# development, the sandboxes among it. Python's __pycache__ folders are left out wherever they
# are. helpers.py, beside this file, has the same list.
$NotCopied = @('.git', 'local-settings.json', 'internal/.generated', 'internal/.python', 'internal/development')
if (-not (Test-Path -LiteralPath (Join-Path $PythonDir 'python.exe') -PathType Leaf)) {
    Write-Host ('No python.exe in {0}. Install Python with the Python install manager, or name a folder that has one with -PythonDir.' -f $PythonDir) -ForegroundColor Red
    exit 1
}
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
        [string[]]$Arguments = @()
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith(([System.IO.Path]::GetFullPath($SandboxRoot) + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to run $full, which is not in a sandbox."
    }
    $ErrorActionPreference = 'Continue'
    $out = @('' | & $Pwsh -NoProfile -File $full @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out }
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

function Get-GeneratedStamp {
    # Each different stamp in a generated skill's commands, which name it as --skill <name>
    # --stamp <stamp>.
    param(
        [Parameter(Mandatory)][string]$Generated,
        [Parameter(Mandatory)][string]$Name
    )
    $text = [System.IO.File]::ReadAllText((Join-Path $Generated "skills/$Name/SKILL.md"))
    @([regex]::Matches($text, "--skill $Name --stamp ([0-9a-f]+)") | ForEach-Object { $_.Groups[1].Value }) | Select-Object -Unique
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

function Copy-RepoFolder {
    # Copies a folder of this repo into a sandbox, file by file, leaving out what $NotCopied
    # names, Python's __pycache__ folders, and every link: Copy-Item -Recurse would copy what a
    # link points to, such as a whole Python install.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Relative = ''
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        $path = if ($Relative) { '{0}/{1}' -f $Relative, $item.Name } else { $item.Name }
        if (($NotCopied -contains $path) -or ($item.Name -eq '__pycache__')) { continue }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-RepoFolder -Source $item.FullName -Destination $target -Relative $path }
        else { Copy-Item -LiteralPath $item.FullName -Destination $target -Force }
    }
}

function New-Sandbox {
    # Builds a sandbox and returns its paths. The copy's local-settings.json, with testHomeDir,
    # is written before anything in the copy can run.
    param([Parameter(Mandatory)][string]$Name)
    $root = Join-Path $SandboxRoot ('{0}-{1}' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $box = [pscustomobject]@{
        Root    = $root
        Tools   = Join-Path $root 'tools'
        Profile = Join-Path $root 'profile'
        Content = Join-Path $root 'dev-home'
        Remote  = Join-Path $root 'dev-home-remote.git'
    }

    # The copy: this repo's working tree, without what $NotCopied names.
    Copy-RepoFolder -Source $RepoRoot -Destination $box.Tools
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
    # Where setup looks for the Python install manager's shortcuts in a test profile.
    $pythonParent = Join-Path $box.Profile 'AppData/Local/Python'
    New-Item -ItemType Directory -Path $pythonParent -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $pythonParent 'bin') -Target $PythonDir | Out-Null

    # dev-home, with a remote and some content.
    Invoke-Git @('init', '--quiet', '--bare', '-b', 'main', $box.Remote) | Out-Null
    Invoke-Git @('clone', '--quiet', $box.Remote, $box.Content) | Out-Null
    $files = [ordered]@{
        'global-rules/global-rules.md' = "# My rules`n`n- Personal rule one.`n"
        'knowledge/README.md'      = "# Knowledge base`n"
        'handoffs/demo/HANDOFF.md' = "# demo handoff`n"
        'skills/mine/SKILL.md'     = "---`nname: mine`ndescription: A personal test skill.`n---`n"
    }
    foreach ($relative in $files.Keys) { Write-TextFile -Path (Join-Path $box.Content $relative) -Text $files[$relative] }
    Invoke-Git (@('-C', $box.Content, 'add', '--') + @($files.Keys)) | Out-Null
    Invoke-Git @('-C', $box.Content, 'commit', '--quiet', '-m', 'test: content') | Out-Null
    Invoke-Git @('-C', $box.Content, 'push', '--quiet', '-u', 'origin', 'main') | Out-Null
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
    # Other groups may be running at the same time, and one may have just made its sandbox here.
    try { [System.IO.Directory]::Delete($SandboxRoot, $false) } catch { }
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
    $generated = Join-Path $box.Tools 'internal/.generated'
    $toolsForward = $box.Tools.Replace('\', '/')
    $codexRules = Join-Path $box.Profile '.codex/AGENTS.md'
    $settingsPath = Join-Path $box.Tools 'local-settings.json'
    $rootBefore = @(Get-ChildItem -LiteralPath $box.Tools -Force | ForEach-Object { $_.Name })

    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'first run exits 0' ($run.ExitCode -eq 0) $run.Lines
    Test-Check 'says it is using the test profile' (Test-HasLine $run.Lines '^TEST\s') $run.Lines

    $leftover = @(Get-ChildItem -LiteralPath $generated -Recurse -File -ErrorAction SilentlyContinue | Select-String -Pattern '\{\{[A-Z_]+\}\}')
    Test-Check 'fills in every placeholder' ((Test-Path -LiteralPath "$generated/skills/handoff/SKILL.md") -and ($leftover.Count -eq 0)) @($leftover | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber })
    $skill = Get-Content -LiteralPath "$generated/skills/handoff/SKILL.md" -Raw
    Test-Check 'writes the copy''s path into the pre-approvals' ($skill.Contains("Bash($toolsForward/internal/.python/python.exe -I $toolsForward/sync.py)"))
    # Claude Code's PowerShell tool never pre-approves a command that starts another PowerShell.
    $nested = @(Get-ChildItem -LiteralPath (Join-Path $generated 'skills') -Recurse -Filter 'SKILL.md' | Select-String -Pattern 'PowerShell\(\s*pwsh')
    Test-Check 'pre-approves pwsh commands only for the Bash tool' ($nested.Count -eq 0) @($nested | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber })
    Test-Check 'points the handoff skill at its generated template' ($skill.Contains("$toolsForward/internal/.generated/skills/handoff/template.md"))
    $prepareCommand = '{0}/internal/.python/python.exe -I {0}/internal/.generated/shared-skill-scripts/prepare.py --skill handoff --stamp ' -f $toolsForward
    Test-Check 'writes the shared scripts, and Python and their folder into the pre-approvals' ((Test-Path -LiteralPath "$generated/shared-skill-scripts/facts.py" -PathType Leaf) -and (Test-Path -LiteralPath "$generated/shared-skill-scripts/prepare.py" -PathType Leaf) -and ($skill -match ([regex]::Escape("Bash($prepareCommand") + '[0-9a-f]{12} handoff environment newer-commits\)')))
    Test-Link 'links internal/.python to the Python it finds' (Join-Path $box.Tools 'internal/.python') (Join-Path $box.Profile 'AppData/Local/Python/bin')
    # The root holds what must be there (AGENTS.md says what). local-settings.json, setup's one
    # file there, was already written for the test profile.
    $rootAdded = @(Get-ChildItem -LiteralPath $box.Tools -Force | ForEach-Object { $_.Name } | Where-Object { $rootBefore -notcontains $_ })
    Test-Check 'adds nothing to the root' ($rootAdded.Count -eq 0) $rootAdded

    # Each skill's commands carry one stamp of its own, the start of a SHA-256.
    $stamps = @{}
    foreach ($name in @('handoff', 'knowledge')) { $stamps[$name] = @(Get-GeneratedStamp -Generated $generated -Name $name) }
    Test-Check 'stamps each skill''s commands with one stamp of its own' (($stamps['handoff'].Count -eq 1) -and ($stamps['knowledge'].Count -eq 1) -and ($stamps['handoff'][0] -match '^[0-9a-f]{12}$') -and ($stamps['handoff'][0] -ne $stamps['knowledge'][0])) @(('handoff: ' + ($stamps['handoff'] -join ', ')), ('knowledge: ' + ($stamps['knowledge'] -join ', ')))

    # Each file a tool loads gets the note, whatever skills there are, and no other file does.
    $marker = '<!-- Generated by dev-home-tools setup from '
    $contentForward = $box.Content.Replace('\', '/')
    $skillFiles = @(Get-ChildItem -LiteralPath (Join-Path $generated 'skills') -Directory | ForEach-Object { Join-Path $_.FullName 'SKILL.md' })
    $unnoted = @(foreach ($file in $skillFiles) {
            $name = Split-Path -Leaf (Split-Path -Parent $file)
            $text = Get-Content -LiteralPath $file -Raw
            $close = $text.IndexOf("`n---`n", 3)
            if (-not ($text.StartsWith("---`nname: $name`n") -and ($close -gt 0) -and
                    $text.Substring($close + 5).StartsWith("$marker$toolsForward/templates/skills/$name/. Do not edit this copy") -and
                    $text.Contains("skills of your own go in $contentForward/skills/. -->"))) { $file }
        })
    Test-Check 'notes each skill''s template right after its frontmatter' (($skillFiles.Count -ge 2) -and ($unnoted.Count -eq 0)) $unnoted
    $rulesFile = [System.IO.Path]::GetFullPath((Join-Path $generated 'operating-rules/operating-rules.md'))
    $rules = Get-Content -LiteralPath $rulesFile -Raw
    Test-Check 'notes the operating rules'' template at the top, and where rules of your own go' ($rules.StartsWith("$marker$toolsForward/templates/operating-rules/operating-rules.md. Do not edit this copy") -and $rules.Contains("Put rules of your own in $contentForward/global-rules/global-rules.md;") -and $rules.Contains("`n`n# Private repo: dev-home (rules loaded)")) @($rules)
    $expected = @($skillFiles | ForEach-Object { [System.IO.Path]::GetFullPath($_) }) + $rulesFile
    $extra = @(Get-ChildItem -LiteralPath $generated -Recurse -File | Where-Object {
            ($expected -notcontains $_.FullName) -and ([string](Get-Content -LiteralPath $_.FullName -Raw)).Contains($marker) })
    Test-Check 'notes no other generated file, such as the handoff template' ($extra.Count -eq 0) @($extra.FullName)

    foreach ($folder in @('.claude/skills', '.agents/skills')) {
        Test-Link "links the handoff skill in $folder" (Join-Path $box.Profile "$folder/handoff") (Join-Path $generated 'skills/handoff')
        Test-Link "links the knowledge skill in $folder" (Join-Path $box.Profile "$folder/knowledge") (Join-Path $generated 'skills/knowledge')
        Test-Link "links the personal skill in $folder" (Join-Path $box.Profile "$folder/mine") (Join-Path $box.Content 'skills/mine')
    }
    Test-Link 'links the operating rules for Claude Code' (Join-Path $box.Profile '.claude/rules/dev-home-operating-rules') (Join-Path $generated 'operating-rules')
    Test-Link 'links the global rules for Claude Code' (Join-Path $box.Profile '.claude/rules/dev-home-global-rules') (Join-Path $box.Content 'global-rules')

    $codex = Get-Content -LiteralPath $codexRules -Raw
    $operatingAt = $codex.IndexOf('# Private repo: dev-home (rules loaded)')
    $globalAt = $codex.IndexOf('- Personal rule one.')
    $codexNotes = [regex]::Matches($codex, [regex]::Escape($marker)).Count
    $codexFrom = "$marker$toolsForward/templates/operating-rules/operating-rules.md and $contentForward/global-rules/global-rules.md. "
    Test-Check 'writes Codex''s rules: one note naming both sources, then the operating rules, then the global ones' ($codex.StartsWith($codexFrom) -and $codex.Contains('Put rules of your own in the second file;') -and ($codexNotes -eq 1) -and ($operatingAt -gt 0) -and ($globalAt -gt $operatingAt)) @($codex)

    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    $other = @($run.Lines | Where-Object { $_ -notmatch '^TEST\s' })
    Test-Check 'a second run changes nothing and prints nothing else' (($run.ExitCode -eq 0) -and ($other.Count -eq 0)) $run.Lines

    # A stamp follows the text an agent loads, SKILL.md, and not the skill's other files.
    $handoffFolder = Join-Path $box.Tools 'templates/skills/handoff'
    $skillText = [System.IO.File]::ReadAllText((Join-Path $handoffFolder 'SKILL.md'))
    $templateText = [System.IO.File]::ReadAllText((Join-Path $handoffFolder 'template.md'))
    Add-Content -LiteralPath (Join-Path $handoffFolder 'template.md') -Value '- A line added to the template.'
    Invoke-Script -Path $setup -Arguments @('-Quiet') | Out-Null
    $afterTemplate = @(Get-GeneratedStamp -Generated $generated -Name 'handoff')
    Add-Content -LiteralPath (Join-Path $handoffFolder 'SKILL.md') -Value 'A line added to the skill.'
    Invoke-Script -Path $setup -Arguments @('-Quiet') | Out-Null
    $afterSkill = @(Get-GeneratedStamp -Generated $generated -Name 'handoff')
    Test-Check 'a skill''s stamp changes with its SKILL.md, and not with its other files' ((($afterTemplate -join '') -eq $stamps['handoff'][0]) -and ($afterSkill.Count -eq 1) -and ($afterSkill[0] -ne $stamps['handoff'][0])) @("first: $($stamps['handoff'])", "after the template: $afterTemplate", "after SKILL.md: $afterSkill")
    Write-TextFile -Path (Join-Path $handoffFolder 'SKILL.md') -Text $skillText
    Write-TextFile -Path (Join-Path $handoffFolder 'template.md') -Text $templateText
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'the stamp comes back with the text' ((($run.ExitCode -eq 0)) -and ((@(Get-GeneratedStamp -Generated $generated -Name 'handoff') -join '') -eq $stamps['handoff'][0])) $run.Lines

    # The Python link: re-pointed once its python.exe is gone, reported when no Python is found,
    # and left alone when it isn't a link.
    $pythonLink = Join-Path $box.Tools 'internal/.python'
    $pythonBin = Join-Path $box.Profile 'AppData/Local/Python/bin'
    $noPython = Join-Path $box.Root 'no-python'
    New-Item -ItemType Directory -Path $noPython | Out-Null
    [System.IO.Directory]::Delete($pythonLink, $false)
    New-Item -ItemType Junction -Path $pythonLink -Target $noPython | Out-Null
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 're-points the Python link when its python.exe is gone' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^LINKED\s+Python for the skills')) $run.Lines
    Test-Link 'the Python link leads to the Python it finds again' $pythonLink $pythonBin
    [System.IO.Directory]::Delete($pythonBin, $false)
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'reports when no Python 3.12 or later is found' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines '^PROBLEM\s+Python for the skills: no Python 3\.12 or later')) $run.Lines
    New-Item -ItemType Junction -Path $pythonBin -Target $PythonDir | Out-Null
    [System.IO.Directory]::Delete($pythonLink, $false)
    New-Item -ItemType Directory -Path $pythonLink | Out-Null
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'leaves alone an internal/.python that is not a link' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'is not a link') -and (Test-Path -LiteralPath $pythonLink -PathType Container) -and ($null -eq (Get-LinkTarget $pythonLink))) $run.Lines
    [System.IO.Directory]::Delete($pythonLink, $false)
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Link 'links internal/.python again once the folder is gone' $pythonLink $pythonBin

    # In the generated folder: Python's bytecode cache stays beside the scripts, a link that isn't
    # setup's stays and nothing behind it changes, and a folder whose templates are gone goes,
    # cache and all.
    $cacheFile = Join-Path $generated 'shared-skill-scripts/__pycache__/facts.cpython-399.pyc'
    Write-TextFile -Path $cacheFile -Text 'cache'
    $outside = Join-Path $box.Root 'outside'
    Write-TextFile -Path (Join-Path $outside 'keep.txt') -Text "keep`n"
    $topLink = Join-Path $generated 'someone-elses-link'
    $innerLink = Join-Path $generated 'skills/handoff/someone-elses-link'
    New-Item -ItemType Junction -Path $topLink -Target $outside | Out-Null
    New-Item -ItemType Junction -Path $innerLink -Target $outside | Out-Null
    $oldScripts = Join-Path $generated 'old-scripts'
    Write-TextFile -Path (Join-Path $oldScripts 'old.py') -Text "pass`n"
    Write-TextFile -Path (Join-Path $oldScripts '__pycache__/old.cpython-399.pyc') -Text 'cache'
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'keeps Python''s bytecode cache beside the scripts' (($run.ExitCode -eq 0) -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) $run.Lines
    Test-Check 'leaves links in the generated folder alone, and what they point to' ((Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) -and ($null -ne (Get-LinkTarget $topLink)) -and ($null -ne (Get-LinkTarget $innerLink))) $run.Lines
    Test-Check 'removes a generated folder with no templates, cache and all' (-not (Test-Path -LiteralPath $oldScripts)) $run.Lines
    [System.IO.Directory]::Delete($topLink, $false)
    [System.IO.Directory]::Delete($innerLink, $false)
    $sharedScripts = Join-Path $generated 'shared-skill-scripts'
    [System.IO.Directory]::Delete($sharedScripts, $true)
    New-Item -ItemType Junction -Path $sharedScripts -Target $outside | Out-Null
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'reports a generated folder that is a link, and writes nothing through it' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'is a link, so setup left it alone') -and (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 1)) $run.Lines
    [System.IO.Directory]::Delete($sharedScripts, $false)
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'writes that folder again once the link is gone' (($run.ExitCode -eq 0) -and (Test-Path -LiteralPath (Join-Path $sharedScripts 'facts.py') -PathType Leaf)) $run.Lines

    Copy-Item -LiteralPath (Join-Path $box.Profile '.claude/settings.json') -Destination (Join-Path $box.Root 'claude-settings.json')
    Copy-Item -LiteralPath (Join-Path $box.Profile '.codex/config.toml') -Destination (Join-Path $box.Root 'config.toml')
    Write-TextFile -Path (Join-Path $box.Profile '.claude/settings.json') -Text "{}`n"
    Write-TextFile -Path (Join-Path $box.Profile '.codex/config.toml') -Text ''
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'reports missing settings without changing them' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'additionalDirectories') -and (Test-HasLine $run.Lines 'writable_roots') -and ((Get-Content -LiteralPath (Join-Path $box.Profile '.claude/settings.json') -Raw) -eq "{}`n")) $run.Lines
    Copy-Item -LiteralPath (Join-Path $box.Root 'claude-settings.json') -Destination (Join-Path $box.Profile '.claude/settings.json') -Force
    Copy-Item -LiteralPath (Join-Path $box.Root 'config.toml') -Destination (Join-Path $box.Profile '.codex/config.toml') -Force

    # The Claude folder in CLAUDE_CONFIG_DIR: a test profile takes it only from inside itself. One
    # in no list gets advice that works from a terminal, where that variable usually isn't set.
    $sessionClaude = Join-Path $box.Profile '.claude-second'
    $outsideClaude = Join-Path $box.Root 'outside-claude'
    foreach ($folder in @($sessionClaude, $outsideClaude)) { Write-TextFile -Path (Join-Path $folder 'settings.json') -Text "{}`n" }
    $settingsText = Get-Content -LiteralPath $settingsPath -Raw
    $realClaudeDir = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = $outsideClaude
        $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
        Test-Check 'a test profile ignores a CLAUDE_CONFIG_DIR outside it' (($run.ExitCode -eq 0) -and (-not (Test-Path -LiteralPath (Join-Path $outsideClaude 'skills')))) $run.Lines
        $env:CLAUDE_CONFIG_DIR = $sessionClaude
        $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
        Test-Link 'links the skills in the CLAUDE_CONFIG_DIR folder' (Join-Path $sessionClaude 'skills/handoff') (Join-Path $generated 'skills/handoff')
        Test-Check 'tells how to list a CLAUDE_CONFIG_DIR folder that is in no list' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines '^PROBLEM\s+Claude Code settings in \.claude-second: .* Add "~/\.claude-second" to claudeConfigDirs in .*local-settings\.json, then run setup\.ps1 without -Quiet, and it offers')) $run.Lines
        $listed = $settingsText | ConvertFrom-Json
        $listed.claudeConfigDirs = @('~/.claude-second')
        Write-TextFile -Path $settingsPath -Text ($listed | ConvertTo-Json)
        $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
        Test-Check 'a listed folder gets the advice to run setup without -Quiet' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines '^PROBLEM\s+Claude Code settings in \.claude-second: .* Run setup\.ps1 without -Quiet, and it offers') -and (-not (Test-HasLine $run.Lines 'claudeConfigDirs'))) $run.Lines
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $realClaudeDir
        Write-TextFile -Path $settingsPath -Text $settingsText
    }

    $operatingTemplate = Join-Path $box.Tools 'templates/operating-rules/operating-rules.md'
    Add-Content -LiteralPath $operatingTemplate -Value '- A line added to the operating rules.'
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'a changed template reaches the generated copy and Codex''s rules' ((Get-Content -LiteralPath $codexRules -Raw).Contains('A line added to the operating rules.') -and (Get-Content -LiteralPath "$generated/operating-rules/operating-rules.md" -Raw).Contains('A line added to the operating rules.')) $run.Lines

    # Two skills whose frontmatter ends in an unusual way: one closing line with trailing spaces,
    # and one with no closing line at all.
    $spaced = Join-Path $box.Tools 'templates/skills/spaced'
    $unclosed = Join-Path $box.Tools 'templates/skills/unclosed'
    Write-TextFile -Path (Join-Path $spaced 'SKILL.md') -Text "---`nname: spaced`ndescription: Ends its frontmatter with trailing spaces.`n---  `n`n# Spaced`n"
    Write-TextFile -Path (Join-Path $unclosed 'SKILL.md') -Text "---`nname: unclosed`ndescription: Never ends its frontmatter.`n"
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    $spacedText = Get-Content -LiteralPath "$generated/skills/spaced/SKILL.md" -Raw
    $unclosedText = Get-Content -LiteralPath "$generated/skills/unclosed/SKILL.md" -Raw
    Test-Check 'notes a skill whose closing line has trailing spaces' ($spacedText.Contains("`n---  `n$marker")) @($spacedText)
    Test-Check 'reports frontmatter with no end, and writes that copy without a note' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines '^PROBLEM\s.*unclosed.*no closing') -and $unclosedText.StartsWith("---`nname: unclosed`n") -and (-not $unclosedText.Contains($marker))) $run.Lines
    Remove-Item -LiteralPath $spaced, $unclosed -Recurse -Force
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'removes those two skills again' (($run.ExitCode -eq 0) -and (-not (Test-Path -LiteralPath "$generated/skills/unclosed"))) $run.Lines

    # The generated folder from the previous layout, with the operating rules link still pointing
    # into it.
    $oldRules = Join-Path $generated 'rules'
    Write-TextFile -Path (Join-Path $oldRules 'core.md') -Text "old core rules`n"
    $operatingLink = Join-Path $box.Profile '.claude/rules/dev-home-operating-rules'
    [System.IO.Directory]::Delete($operatingLink, $false)
    New-Item -ItemType Junction -Path $operatingLink -Target $oldRules | Out-Null
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'removes a generated folder that has no templates' (($run.ExitCode -eq 0) -and (-not (Test-Path -LiteralPath $oldRules))) $run.Lines
    Test-Link 'moves the operating rules link off the removed folder' $operatingLink (Join-Path $generated 'operating-rules')

    # Two paths in a skill: one starts as a file and becomes a folder, the other the reverse.
    $toFolder = Join-Path $box.Tools 'templates/skills/handoff/to-folder'
    $toFile = Join-Path $box.Tools 'templates/skills/handoff/to-file'
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

    [System.IO.Directory]::Delete((Join-Path $box.Tools 'templates/skills/knowledge'), $true)
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
        New-Item -ItemType SymbolicLink -Path $codexRules -Target (Join-Path $box.Content 'global-rules/global-rules.md') -ErrorAction Stop | Out-Null
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

    $handoffTemplate = Join-Path $box.Tools 'templates/skills/handoff/template.md'
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

    # Another git process holds a lock for a moment. The shared git helper waits, then tries again.
    # It's loaded in a scope of its own, so its Invoke-Git can't replace this file's.
    $lockRepo = Join-Path $box.Root 'lock-repo'
    Invoke-Git @('init', '--quiet', '-b', 'main', $lockRepo) | Out-Null
    Write-TextFile -Path (Join-Path $lockRepo 'file.md') -Text "text`n"
    $lockFile = Join-Path $lockRepo '.git/index.lock'
    Write-TextFile -Path $lockFile -Text ''
    $release = Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 1; [System.IO.File]::Delete($using:lockFile) }
    $result = & {
        . (Join-Path $box.Tools 'internal/shared/git.ps1')
        Invoke-Git -Repo $lockRepo -Arguments @('add', '--', 'file.md')
    }
    $release | Wait-Job | Remove-Job
    Test-Check 'the shared git helper waits out another git process''s lock, then succeeds' (($result.ExitCode -eq 0) -and ($result.Tries -ge 2)) (@(('exit code {0} after {1} tries' -f $result.ExitCode, $result.Tries)) + @($result.Err))

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

    $codex = @{ WritableRoot = 'C:\Users\you\dev-home'; MinDocBytes = 65536 }
    $path = Join-Path $work 'empty.toml'
    [System.IO.File]::WriteAllText($path, '')
    $plan = Get-CodexConfigPlan -Path $path @codex
    Test-Check 'Codex config: plans both settings for an empty file' ((-not $plan.Reason) -and $plan.NewText.Contains("writable_roots = ['C:\Users\you\dev-home']") -and $plan.NewText.Contains('project_doc_max_bytes = 65536')) @($plan.Reason, $plan.NewText)

    $path = Join-Path $work 'other.toml'
    [System.IO.File]::WriteAllText($path, "model = `"x`"`n`n[sandbox_workspace_write]`nwritable_roots = ['D:\Other']`n")
    $plan = Get-CodexConfigPlan -Path $path @codex
    Test-Check 'Codex config: adds to an existing writable_roots list' ((-not $plan.Reason) -and $plan.NewText.Contains("writable_roots = ['D:\Other', 'C:\Users\you\dev-home']")) @($plan.Reason, $plan.NewText)

    Test-Check 'Codex config: a forward-slash path counts as present' (Test-CodexConfigText -Text "project_doc_max_bytes = 70000`n`n[sandbox_workspace_write]`nwritable_roots = [`"C:/Users/you/dev-home`"]`n" @codex)
    Test-Check 'Codex config: a longer path that starts the same does not count' (-not (Test-CodexConfigText -Text "project_doc_max_bytes = 70000`n`n[sandbox_workspace_write]`nwritable_roots = ['C:\Users\you\dev-home-tools']`n" @codex))
    Test-Check 'Codex config: a project_doc_max_bytes below the minimum does not count' (-not (Test-CodexConfigText -Text "project_doc_max_bytes = 32768`n`n[sandbox_workspace_write]`nwritable_roots = ['C:\Users\you\dev-home']`n" @codex))
}

# ---------------------------------------------------------------------------------------------
# internal/shared/'s PowerShell files, read without running anything

function Test-Shared {
    Write-Host
    Write-Host 'internal/shared/' -ForegroundColor Cyan
    $script:GroupFailed = $false
    $isFunction = { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    $sharedFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'internal/shared') -Filter '*.ps1' -File | ForEach-Object { 'internal/shared/' + $_.Name })
    $sharedNames = @(foreach ($name in $sharedFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $name), [ref]$null, [ref]$null)
            $ast.FindAll($isFunction, $true) | ForEach-Object { $_.Name }
        })

    # Setup's own function with the same name would quietly replace the shared one.
    $clashes = [System.Collections.Generic.List[string]]::new()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'setup.ps1'), [ref]$null, [ref]$null)
    foreach ($function in $ast.FindAll($isFunction, $true)) {
        if ($sharedNames -contains $function.Name) { $clashes.Add(('setup.ps1 defines {0}' -f $function.Name)) }
    }
    Test-Check 'setup.ps1 defines no function that internal/shared/ already defines' (($sharedNames.Count -gt 0) -and ($clashes.Count -eq 0)) $clashes
}

# ---------------------------------------------------------------------------------------------
# README.md and docs/

function Get-MarkdownLink {
    # The target of each link in Markdown text, which is what's between the parentheses of
    # [text](target). Leaves out code, where a link is only an example, and links to the web.
    param([string[]]$Lines)
    $inCode = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
        if ($inCode) { continue }
        foreach ($match in [regex]::Matches(($line -replace '`[^`]*`', ''), '\]\(([^)\s]+)\)')) {
            $target = $match.Groups[1].Value
            if ($target -notmatch '^[a-z][a-z0-9+.-]*:') { $target }
        }
    }
}

function Get-MarkdownAnchor {
    # The anchor GitHub gives each heading: lower case, punctuation dropped, and a hyphen for
    # each space.
    param([string[]]$Lines)
    $inCode = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
        if ($inCode) { continue }
        if ($line -match '^#{1,6}\s+(.+?)\s*$') {
            ($Matches[1].ToLowerInvariant() -replace '[^a-z0-9 _-]', '') -replace ' ', '-'
        }
    }
}

function Test-Docs {
    Write-Host
    Write-Host 'README.md and docs/' -ForegroundColor Cyan
    $script:GroupFailed = $false

    # First, that the search finds each kind of link, and nothing in code or on the web.
    $sample = @('See [a page](docs/a.md), [a heading](#part-two), and [both](../b.md#top).',
        'Not `[code](docs/no.md)`, and not [the web](https://example.com/no.md).',
        '```', '[fenced](docs/no.md)', '```',
        'A link with [`code` as its text](c.md).')
    $found = @(Get-MarkdownLink -Lines $sample)
    Test-Check 'the link search finds each kind of link, and nothing in code or on the web' (($found -join ' ') -eq 'docs/a.md #part-two ../b.md#top c.md') $found

    $docsRoot = Join-Path $RepoRoot 'docs'
    $pages = @('README.md') + @(Get-ChildItem -LiteralPath $docsRoot -Recurse -Filter '*.md' -File | ForEach-Object { [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace('\', '/') })
    $missingFiles = [System.Collections.Generic.List[string]]::new()
    $missingHeadings = [System.Collections.Generic.List[string]]::new()
    $fromReadme = [System.Collections.Generic.List[string]]::new()
    foreach ($page in $pages) {
        $pagePath = Join-Path $RepoRoot $page
        foreach ($target in @(Get-MarkdownLink -Lines (Get-Content -LiteralPath $pagePath))) {
            $path, $anchor = $target -split '#', 2
            $file = if ($path) { [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pagePath) $path)) } else { $pagePath }
            if (-not (Test-Path -LiteralPath $file)) { $missingFiles.Add(('{0}: {1}' -f $page, $target)); continue }
            if ($page -eq 'README.md') { $fromReadme.Add([System.IO.Path]::GetRelativePath($RepoRoot, $file).Replace('\', '/')) }
            if ($anchor -and (@(Get-MarkdownAnchor -Lines (Get-Content -LiteralPath $file)) -notcontains $anchor)) { $missingHeadings.Add(('{0}: {1}' -f $page, $target)) }
        }
    }
    Test-Check 'every link in the README and docs/ points to a file that exists' (($pages.Count -gt 1) -and ($missingFiles.Count -eq 0)) $missingFiles
    Test-Check 'every link to a heading points to one that exists' ($missingHeadings.Count -eq 0) $missingHeadings

    # The README's table is the only list of the pages, so a page it leaves out can't be found.
    $unlisted = @($pages | Where-Object { ($_ -ne 'README.md') -and ($fromReadme -notcontains $_) })
    Test-Check 'the README links to every page under docs/' ($unlisted.Count -eq 0) $unlisted

    $skills = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'templates/skills') -Directory | ForEach-Object { $_.Name } | Sort-Object)
    $skillPages = @(Get-ChildItem -LiteralPath (Join-Path $docsRoot 'skills') -Filter '*.md' -File | ForEach-Object { $_.BaseName } | Sort-Object)
    Test-Check 'every skill in templates/skills/ has a page in docs/skills/, and every page a skill' (($skills.Count -gt 0) -and (($skills -join ' ') -eq ($skillPages -join ' '))) @(('skills: ' + ($skills -join ', ')), ('pages: ' + ($skillPages -join ', ')))

    # A skill's page is written for people and its SKILL.md for agents, so the README links to
    # the page, and the page links to the SKILL.md.
    $toSkillFile = @($fromReadme | Where-Object { $_ -like '*/SKILL.md' })
    Test-Check 'the README links to each skill''s page, never its SKILL.md' ($toSkillFile.Count -eq 0) $toSkillFile
    $noSkillLink = @(foreach ($skill in $skills) {
            $skillPage = Join-Path $docsRoot ('skills/{0}.md' -f $skill)
            if (-not (Test-Path -LiteralPath $skillPage)) { continue }
            $skillFile = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ('templates/skills/{0}/SKILL.md' -f $skill)))
            $linked = @(Get-MarkdownLink -Lines (Get-Content -LiteralPath $skillPage) | ForEach-Object { ($_ -split '#', 2)[0] } | Where-Object { $_ } | ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $skillPage) $_)) })
            if ($linked -notcontains $skillFile) { $skill }
        })
    Test-Check 'every skill''s page links to its SKILL.md' ($noSkillLink.Count -eq 0) $noSkillLink
}

# ---------------------------------------------------------------------------------------------

Write-Host ('Testing the working tree of {0}' -f $RepoRoot)
if ($Group -contains 'setup') { Test-Setup }
if ($Group -contains 'shared') { Test-Shared }
if ($Group -contains 'docs') { Test-Docs }
Write-Host
if ($script:Failures -gt 0) {
    Write-Host ('{0} of {1} checks failed.' -f $script:Failures, $script:Checks) -ForegroundColor Red
    exit 1
}
Write-Host ('All {0} checks passed.' -f $script:Checks) -ForegroundColor Green
exit 0
