#Requires -Version 7.2
<#
.SYNOPSIS
    Tests setup.ps1, sync.ps1, update.ps1, and the skills' facts.ps1 and prepare.ps1 end to end,
    in throwaway copies of this repo, and checks internal/shared/, which the first three load,
    the scripts the skills share, and the links in README.md and docs/.

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
    pwsh -NoProfile -File internal/tests/Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

# This file is in internal/tests/, two folders below the repo's root.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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
    # never wait for an answer. Returns the exit code and the output lines. With -Utf8, reads the
    # output as UTF-8, as agents do, for the scripts that write it that way.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [string]$Answer = '',
        [switch]$Utf8
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith(([System.IO.Path]::GetFullPath($SandboxRoot) + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to run $full, which is not in a sandbox."
    }
    $ErrorActionPreference = 'Continue'
    $encoding = [Console]::OutputEncoding
    if ($Utf8) { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) }
    try {
        $out = @($Answer | & $Pwsh -NoProfile -File $full @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    finally { [Console]::OutputEncoding = $encoding }
    return [pscustomobject]@{ ExitCode = $code; Lines = $out }
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
        'global-rules/global-rules.md' = "# My rules`n`n- Personal rule one.`n"
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
    # Claude Code's PowerShell tool never pre-approves a command that starts another PowerShell.
    $nested = @(Get-ChildItem -LiteralPath (Join-Path $generated 'skills') -Recurse -Filter 'SKILL.md' | Select-String -Pattern 'PowerShell\(\s*pwsh')
    Test-Check 'pre-approves pwsh commands only for the Bash tool' ($nested.Count -eq 0) @($nested | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber })
    Test-Check 'points the handoff skill at its generated template' ($skill.Contains("$toolsForward/.generated/skills/handoff/template.md"))
    Test-Check 'writes the shared scripts, and their folder into the pre-approvals' ((Test-Path -LiteralPath "$generated/skill-scripts/facts.ps1" -PathType Leaf) -and (Test-Path -LiteralPath "$generated/skill-scripts/prepare.ps1" -PathType Leaf) -and $skill.Contains("Bash(pwsh -NoProfile -File $toolsForward/.generated/skill-scripts/prepare.ps1 handoff environment newer-commits)"))

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

    Copy-Item -LiteralPath (Join-Path $box.Profile '.claude/settings.json') -Destination (Join-Path $box.Root 'claude-settings.json')
    Copy-Item -LiteralPath (Join-Path $box.Profile '.codex/config.toml') -Destination (Join-Path $box.Root 'config.toml')
    Write-TextFile -Path (Join-Path $box.Profile '.claude/settings.json') -Text "{}`n"
    Write-TextFile -Path (Join-Path $box.Profile '.codex/config.toml') -Text ''
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'reports missing settings without changing them' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'additionalDirectories') -and (Test-HasLine $run.Lines 'writable_roots') -and ((Get-Content -LiteralPath (Join-Path $box.Profile '.claude/settings.json') -Raw) -eq "{}`n")) $run.Lines
    Copy-Item -LiteralPath (Join-Path $box.Root 'claude-settings.json') -Destination (Join-Path $box.Profile '.claude/settings.json') -Force
    Copy-Item -LiteralPath (Join-Path $box.Root 'config.toml') -Destination (Join-Path $box.Profile '.codex/config.toml') -Force

    $operatingTemplate = Join-Path $box.Tools 'templates/operating-rules/operating-rules.md'
    Add-Content -LiteralPath $operatingTemplate -Value '- A line added to the operating rules.'
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'a changed template reaches the generated copy and Codex''s rules' ((Get-Content -LiteralPath $codexRules -Raw).Contains('A line added to the operating rules.') -and (Get-Content -LiteralPath "$generated/operating-rules/operating-rules.md" -Raw).Contains('A line added to the operating rules.')) $run.Lines

    # A Codex rules file written by an earlier version of setup, which started with another marker.
    Write-TextFile -Path $codexRules -Text "<!-- Written by dev-home-tools setup.ps1, from its operating rules. -->`n`nOld rules.`n"
    $run = Invoke-Script -Path $setup -Arguments @('-Quiet')
    Test-Check 'replaces a Codex rules file that an earlier setup wrote' (($run.ExitCode -eq 0) -and (Get-Content -LiteralPath $codexRules -Raw).StartsWith($marker)) $run.Lines

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

    # This copy isn't a git clone. Git would otherwise use the repo around it, which here is the
    # real one, so the ceiling is a second guard.
    $ceiling = $env:GIT_CEILING_DIRECTORIES
    $env:GIT_CEILING_DIRECTORIES = $box.Root.Replace('\', '/')
    try { $run = Invoke-Script -Path (Join-Path $box.Tools 'update.ps1') } finally { $env:GIT_CEILING_DIRECTORIES = $ceiling }
    Test-Check 'update.ps1 in a copy that is not a git clone stops before running git' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines 'not a git clone')) $run.Lines

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
    $upstreamSkill = Join-Path $box.Upstream 'templates/skills/handoff/SKILL.md'

    $run = Invoke-Script -Path (Join-Path $box.Tools 'setup.ps1') -Arguments @('-Quiet')
    Test-Check 'setup runs cleanly first' ($run.ExitCode -eq 0) $run.Lines

    $run = Invoke-Script -Path $sync
    Test-Check 'a plain sync says dev-home is up to date' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines 'up to date') -and (-not (Test-HasLine $run.Lines '^(UPDATE|PROBLEM)\s'))) $run.Lines

    # A skill of the user's own, created on this PC after setup ran.
    $later = Join-Path $box.Content 'skills/later'
    Write-TextFile -Path (Join-Path $later 'SKILL.md') -Text "---`nname: later`ndescription: A personal skill added after setup.`n---`n"
    Add-Content -LiteralPath (Join-Path $box.Content 'handoffs/demo/HANDOFF.md') -Value 'Before the new skill is linked.'
    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'handoff: demo', 'handoffs/demo/HANDOFF.md')
    Test-Check 'a sync that commits, with nothing new from GitHub, leaves setup to the next plain sync' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^COMMITTED\s') -and ($null -eq (Get-LinkTarget (Join-Path $box.Profile '.claude/skills/later')))) $run.Lines
    Invoke-Script -Path $sync | Out-Null
    Test-Link 'a plain sync links a personal skill added since setup ran' (Join-Path $box.Profile '.claude/skills/later') $later
    [System.IO.Directory]::Delete($later, $true)

    Add-Content -LiteralPath (Join-Path $box.Content 'handoffs/demo/HANDOFF.md') -Value 'A new line.'
    Write-TextFile -Path (Join-Path $box.Content 'notes.md') -Text "someone else's file`n"
    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'handoff: demo', 'handoffs/demo/HANDOFF.md')
    $pushed = (Invoke-Git @('-C', $box.Remote, 'log', '-1', '--format=%s', 'main'))[0]
    $untracked = Invoke-Git @('-C', $box.Content, 'status', '--porcelain')
    Test-Check 'commits and pushes only the named file' (($run.ExitCode -eq 0) -and ($pushed -eq 'handoff: demo') -and (Test-HasLine $untracked '^\?\? notes\.md')) $run.Lines
    Test-Check 'lists the other new file as LEFT' (Test-HasLine $run.Lines '^LEFT\s+notes\.md') $run.Lines
    [System.IO.File]::Delete((Join-Path $box.Content 'notes.md'))

    # A committed file deleted just now along with its folder, which leaves no time of its own.
    Write-TextFile -Path (Join-Path $box.Content 'archive/old-note.md') -Text "an old note`n"
    Invoke-Git @('-C', $box.Content, 'add', '--', 'archive/old-note.md') | Out-Null
    Invoke-Git @('-C', $box.Content, 'commit', '--quiet', '-m', 'archive: old note') | Out-Null
    Invoke-Git @('-C', $box.Content, 'push', '--quiet') | Out-Null
    [System.IO.Directory]::Delete((Join-Path $box.Content 'archive'), $true)
    $run = Invoke-Script -Path $sync
    Test-Check 'a file deleted just now with its folder is LEFT, dated by the folder above' (Test-HasLine $run.Lines '^LEFT\s+archive/old-note\.md \(deleted, under a minute ago\)') $run.Lines
    Invoke-Git @('-C', $box.Content, 'add', '--', 'archive/old-note.md') | Out-Null
    Invoke-Git @('-C', $box.Content, 'commit', '--quiet', '-m', 'archive: remove old note') | Out-Null
    Invoke-Git @('-C', $box.Content, 'push', '--quiet') | Out-Null

    # Another PC pushes a new skill. A sync that commits brings it in, so it runs setup as well.
    $otherPc = Join-Path $box.Root 'other-pc'
    Invoke-Git @('clone', '--quiet', $box.Remote, $otherPc) | Out-Null
    Write-TextFile -Path (Join-Path $otherPc 'skills/from-other-pc/SKILL.md') -Text "---`nname: from-other-pc`ndescription: A skill pushed from another PC.`n---`n"
    Invoke-Git @('-C', $otherPc, 'add', '--', 'skills/from-other-pc/SKILL.md') | Out-Null
    Invoke-Git @('-C', $otherPc, 'commit', '--quiet', '-m', 'skills: from another PC') | Out-Null
    Invoke-Git @('-C', $otherPc, 'push', '--quiet') | Out-Null
    Add-Content -LiteralPath (Join-Path $box.Content 'handoffs/demo/HANDOFF.md') -Value 'While another PC pushed.'
    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'handoff: demo', 'handoffs/demo/HANDOFF.md')
    Test-Check 'a sync that commits and brings in new commits runs setup, so a skill from another PC gets linked' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^(PULLED|MERGED)\s') -and ($null -ne (Get-LinkTarget (Join-Path $box.Profile '.claude/skills/from-other-pc')))) $run.Lines

    Add-Content -LiteralPath $upstreamSkill -Value 'Upstream change one.'
    Invoke-Git @('-C', $box.Upstream, 'commit', '--quiet', '-am', 'handoff: change one') | Out-Null
    Invoke-Git @('-C', $box.Upstream, 'push', '--quiet') | Out-Null
    $run = Invoke-Script -Path $sync
    Test-Check 'with autoUpdate off, reports a waiting update and pulls nothing' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^UPDATE\s') -and (-not (Get-Content -LiteralPath $generatedSkill -Raw).Contains('Upstream change one.'))) $run.Lines

    Add-Content -LiteralPath (Join-Path $box.Content 'handoffs/demo/HANDOFF.md') -Value 'While an update waits.'
    $run = Invoke-Script -Path $sync -Arguments @('-Message', 'handoff: demo', 'handoffs/demo/HANDOFF.md')
    Test-Check 'a sync that commits skips the update check, which the plain sync before it just made' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^COMMITTED\s') -and (-not (Test-HasLine $run.Lines '^UPDATE\s'))) $run.Lines

    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $settings.autoUpdate = $true
    Write-TextFile -Path $settingsPath -Text ($settings | ConvertTo-Json)
    $run = Invoke-Script -Path $sync
    Test-Check 'with autoUpdate on, pulls the update and sets it up' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^PULLED\s+1 commit to dev-home-tools') -and (Get-Content -LiteralPath $generatedSkill -Raw).Contains('Upstream change one.')) $run.Lines

    # An automatic install never overwrites a local edit to a file the update changes.
    Add-Content -LiteralPath $upstreamSkill -Value 'Upstream change one-b.'
    Invoke-Git @('-C', $box.Upstream, 'commit', '--quiet', '-am', 'handoff: change one-b') | Out-Null
    Invoke-Git @('-C', $box.Upstream, 'push', '--quiet') | Out-Null
    $localSkill = Join-Path $box.Tools 'templates/skills/handoff/SKILL.md'
    $localBytes = [System.IO.File]::ReadAllBytes($localSkill)
    Add-Content -LiteralPath $localSkill -Value 'A local edit.'
    $run = Invoke-Script -Path $sync
    Test-Check 'with autoUpdate on, an update that would overwrite a local edit is not installed, and the edit stays' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^UPDATE\s.*not installed') -and (Get-Content -LiteralPath $localSkill -Raw).Contains('A local edit.')) $run.Lines
    [System.IO.File]::WriteAllBytes($localSkill, $localBytes)
    $run = Invoke-Script -Path $sync
    Test-Check 'once the local edit is gone, the next sync installs the update' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^PULLED\s') -and (Get-Content -LiteralPath $generatedSkill -Raw).Contains('Upstream change one-b.')) $run.Lines
    $settings.autoUpdate = $false
    Write-TextFile -Path $settingsPath -Text ($settings | ConvertTo-Json)

    $run = Invoke-Script -Path $update
    Test-Check 'update.ps1 with nothing waiting says so' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines 'up to date')) $run.Lines

    Add-Content -LiteralPath $upstreamSkill -Value 'Upstream change two.'
    Invoke-Git @('-C', $box.Upstream, 'commit', '--quiet', '-am', 'handoff: change two') | Out-Null
    Invoke-Git @('-C', $box.Upstream, 'push', '--quiet') | Out-Null

    # A broken update.ps1 can't stop the rest of a sync: setup still runs after it.
    $updateBytes = [System.IO.File]::ReadAllBytes($update)
    Write-TextFile -Path $update -Text "throw 'broken on purpose'`n"
    $probe = Join-Path $box.Content 'skills/probe'
    Write-TextFile -Path (Join-Path $probe 'SKILL.md') -Text "---`nname: probe`ndescription: A personal skill for this check.`n---`n"
    $run = Invoke-Script -Path $sync
    [System.IO.File]::WriteAllBytes($update, $updateBytes)
    Test-Check 'a broken update.ps1 is reported, and setup still runs after it' (($run.ExitCode -eq 1) -and (Test-HasLine $run.Lines '^PROBLEM\s.*update\.ps1 stopped') -and ($null -ne (Get-LinkTarget (Join-Path $box.Profile '.claude/skills/probe')))) $run.Lines
    [System.IO.Directory]::Delete($probe, $true)

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

    # A clone with a commit of its own can't simply move forward, and update.ps1 would refuse.
    Write-TextFile -Path (Join-Path $box.Tools 'local-note.md') -Text "a local change`n"
    Invoke-Git @('-C', $box.Tools, 'add', '--', 'local-note.md') | Out-Null
    Invoke-Git @('-C', $box.Tools, 'commit', '--quiet', '-m', 'local: note') | Out-Null
    $run = Invoke-Script -Path $sync
    Test-Check 'with commits of its own, the notice says to merge by hand, not to run update.ps1' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^UPDATE\s.*merge them by hand') -and (-not (Test-HasLine $run.Lines 'update\.ps1'))) $run.Lines

    # GitHub can't be reached for dev-home-tools, though it can for dev-home.
    $toolsUrl = (Invoke-Git @('-C', $box.Tools, 'remote', 'get-url', 'origin'))[0]
    Invoke-Git @('-C', $box.Tools, 'remote', 'set-url', 'origin', (Join-Path $box.Root 'missing.git')) | Out-Null
    $run = Invoke-Script -Path $sync
    Invoke-Git @('-C', $box.Tools, 'remote', 'set-url', 'origin', $toolsUrl) | Out-Null
    Test-Check 'when dev-home-tools can''t be checked, a sync says OFFLINE for it alone and still succeeds' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^OFFLINE\s.*dev-home-tools') -and (@($run.Lines | Where-Object { $_ -match '^OFFLINE\s' }).Count -eq 1)) $run.Lines

    # And the other way around: GitHub can't be reached for dev-home.
    $contentUrl = (Invoke-Git @('-C', $box.Content, 'remote', 'get-url', 'origin'))[0]
    Invoke-Git @('-C', $box.Content, 'remote', 'set-url', 'origin', (Join-Path $box.Root 'missing.git')) | Out-Null
    $run = Invoke-Script -Path $sync
    Invoke-Git @('-C', $box.Content, 'remote', 'set-url', 'origin', $contentUrl) | Out-Null
    Test-Check 'when dev-home can''t be synced, its OFFLINE line names dev-home, and the sync still succeeds' (($run.ExitCode -eq 0) -and (Test-HasLine $run.Lines '^OFFLINE\s+Could not reach GitHub, so dev-home may be behind') -and (@($run.Lines | Where-Object { $_ -match '^OFFLINE\s' }).Count -eq 1)) $run.Lines

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

    Test-RealProfile -Box $box
    Complete-Group -Box $box
}

# ---------------------------------------------------------------------------------------------
# The skills' facts.ps1

function Invoke-Facts {
    # Runs facts.ps1, or prepare.ps1, in a folder, for the handoff topic unless others are named.
    # Returns the exit code, the output lines, the values printed, and their keys in the order
    # printed. A key printed more than once keeps its last value.
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Folder,
        [string[]]$Topics = @('handoff')
    )
    Push-Location -LiteralPath $Folder
    try { $run = Invoke-Script -Path $Script -Arguments $Topics -Utf8 } finally { Pop-Location }
    $values = @{}
    $keys = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $run.Lines) {
        if ($line -match '^([\w-]+): (.*)$') {
            $values[$Matches[1]] = $Matches[2]
            $keys.Add($Matches[1])
        }
    }
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Lines = $run.Lines; Values = $values; Keys = $keys }
}

function Get-TestFirstCommit {
    # The start of a repo's first commit on the main line, worked out here without facts.ps1.
    param([Parameter(Mandatory)][string]$Repo)
    return (Invoke-Git @('-C', $Repo, 'rev-list', '--first-parent', '--max-parents=0', 'HEAD'))[0].Substring(0, 7)
}

function Test-Facts {
    Write-Host
    Write-Host 'skill scripts: facts.ps1' -ForegroundColor Cyan
    $script:GroupFailed = $false
    $box = New-Sandbox -Name 'facts'
    $run = Invoke-Script -Path (Join-Path $box.Tools 'setup.ps1') -Arguments @('-Quiet')
    Test-Check 'setup runs cleanly first' ($run.ExitCode -eq 0) $run.Lines
    $facts = Join-Path $box.Tools '.generated/skill-scripts/facts.ps1'

    # Git also looks for a repo in parent folders, and the sandbox is inside this repo.
    $ceiling = $env:GIT_CEILING_DIRECTORIES
    $env:GIT_CEILING_DIRECTORIES = $box.Root.Replace('\', '/')
    # facts.ps1 picks the link form from CLAUDE_CODE_ENTRYPOINT, which the session running the
    # tests may have set. The checks run without it, except where they set it.
    $entrypoint = $env:CLAUDE_CODE_ENTRYPOINT
    $env:CLAUDE_CODE_ENTRYPOINT = $null
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
            $result = Invoke-Facts -Script $facts -Folder $repo
            Test-Check ('files {0} under {1}' -f $address, $folder) (($result.ExitCode -eq 0) -and ($result.Values['handoff'] -ceq "handoffs/$folder/HANDOFF.md")) $result.Lines
        }

        Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', 'https://github.com/You/Tool.git') | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $repo
        $v = $result.Values
        Test-Check 'prints the service, the name, and the draft path' (($v['service'] -ceq 'github') -and ($v['name'] -ceq 'you/tool') -and ($v['draft'] -ceq '.drafts/github/you/tool/issue.md')) $result.Lines
        Test-Check 'the handoff topic prints its six lines, in order, and nothing else' (($result.Lines.Count -eq 6) -and (($result.Keys -join ' ') -ceq 'service name handoff draft link project')) $result.Lines

        # The other topic, and how topics are asked for.
        $environmentLine = 'environment: {0}' -f [System.Environment]::MachineName
        $result = Invoke-Facts -Script $facts -Folder $repo -Topics @('environment')
        Test-Check 'the environment topic prints this computer''s name, and nothing else' (($result.ExitCode -eq 0) -and ($result.Lines.Count -eq 1) -and ($result.Lines[0] -ceq $environmentLine)) $result.Lines
        $result = Invoke-Facts -Script $facts -Folder $repo -Topics @('environment', 'handoff')
        Test-Check 'two topics print in the order asked' (($result.ExitCode -eq 0) -and (($result.Keys -join ' ') -ceq 'environment service name handoff draft link project')) $result.Lines
        $result = Invoke-Facts -Script $facts -Folder $repo -Topics @()
        Test-Check 'with no topic, stops and names the topics' (($result.ExitCode -eq 1) -and ($result.Keys.Count -eq 0) -and (Test-HasLine $result.Lines 'at least one topic: handoff, environment, newer-commits')) $result.Lines
        $result = Invoke-Facts -Script $facts -Folder $repo -Topics @('environment', 'weather')
        Test-Check 'an unknown topic stops it before any fact is printed' (($result.ExitCode -eq 1) -and ($result.Keys.Count -eq 0) -and (Test-HasLine $result.Lines 'No such topic: weather')) $result.Lines
        # The sandbox keeps dev-home beside the sample repo.
        Test-Check 'prints the handoff and the project folder relative to the current folder' (($v['link'] -ceq '../dev-home/handoffs/github/you/tool/HANDOFF.md') -and ($v['project'] -ceq '.')) $result.Lines

        # A repo named with an accent, a space, #, %, and parentheses: a link target can't hold them as is.
        Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', 'https://dev.azure.com/Org/My%20Project/_git/R%C3%A9po%20%231%20(100%25)') | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $repo
        Test-Check 'the link percent-encodes what a link target can''t hold' ($result.Values['link'] -ceq '../dev-home/handoffs/azure-devops/org/my%20project/r%C3%A9po%20%231%20%28100%25%29/HANDOFF.md') $result.Lines
        $accented = 'handoffs/azure-devops/org/my project/r{0}po #1 (100%)/HANDOFF.md' -f [char]0xE9
        Test-Check 'writes an accented letter as UTF-8, so the handoff path reaches the agent as it is' ($result.Values['handoff'] -ceq $accented) (@("expected: $accented") + $result.Lines)

        Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', 'https://git.example.com/team/app.git') | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $repo
        $v = $result.Values
        Test-Check 'another host: service other, named by folder and first commit' (($v['service'] -ceq 'other') -and ($v['name'] -ceq "sample repo-$id") -and ($v['draft'] -ceq ".drafts/other/sample repo-$id/issue.md")) $result.Lines

        Invoke-Git @('-C', $repo, 'remote', 'remove', 'origin') | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $repo
        $v = $result.Values
        Test-Check 'no origin: service local, named by folder and first commit' (($v['service'] -ceq 'local') -and ($v['name'] -ceq "sample repo-$id") -and ($v['handoff'] -ceq "handoffs/local/sample repo-$id/HANDOFF.md")) $result.Lines
        Test-Check 'the link writes a space in the folder name as %20' ($v['link'] -ceq "../dev-home/handoffs/local/sample%20repo-$id/HANDOFF.md") $result.Lines

        $sub = Join-Path $repo 'docs'
        New-Item -ItemType Directory -Path $sub | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $sub
        Test-Check 'in a subfolder, the links lead up to the handoff and the project folder' (($result.Values['link'] -ceq "../../dev-home/handoffs/local/sample%20repo-$id/HANDOFF.md") -and ($result.Values['project'] -ceq '..')) $result.Lines

        # Claude Code's CLI shows replies in a terminal, which opens file:/// URLs but not relative
        # paths. Git may spell the project folder's drive letter in another case.
        $env:CLAUDE_CODE_ENTRYPOINT = 'cli'
        try { $result = Invoke-Facts -Script $facts -Folder $sub } finally { $env:CLAUDE_CODE_ENTRYPOINT = $null }
        $handoffUrl = 'file:///{0}/handoffs/local/sample%20repo-{1}/HANDOFF.md' -f $box.Content.Replace('\', '/'), $id
        $projectUrl = 'file:///{0}' -f $repo.Replace('\', '/').Replace(' ', '%20')
        Test-Check 'in Claude Code''s CLI, the links are file:/// URLs, and project is the top of the checkout' (($result.Values['link'] -ceq $handoffUrl) -and ($result.Values['project'] -eq $projectUrl)) $result.Lines

        $env:CLAUDE_CODE_ENTRYPOINT = 'claude-vscode'
        try { $result = Invoke-Facts -Script $facts -Folder $repo } finally { $env:CLAUDE_CODE_ENTRYPOINT = $null }
        Test-Check 'anywhere else Claude Code runs, the links stay relative' (($result.Values['link'] -ceq "../dev-home/handoffs/local/sample%20repo-$id/HANDOFF.md") -and ($result.Values['project'] -ceq '.')) $result.Lines

        # Merging in unrelated history gives the repo a second first commit.
        Invoke-Git @('-C', $repo, 'checkout', '--quiet', '--orphan', 'other-history') | Out-Null
        Invoke-Git @('-C', $repo, 'commit', '--quiet', '--allow-empty', '-m', 'test: other history') | Out-Null
        Invoke-Git @('-C', $repo, 'checkout', '--quiet', 'main') | Out-Null
        Invoke-Git @('-C', $repo, 'merge', '--quiet', '--no-ff', '--allow-unrelated-histories', '-m', 'test: merge', 'other-history') | Out-Null
        $roots = Invoke-Git @('-C', $repo, 'rev-list', '--max-parents=0', 'HEAD')
        $result = Invoke-Facts -Script $facts -Folder $repo
        Test-Check 'merged-in unrelated history keeps the main line''s first commit' (($roots.Count -eq 2) -and ($result.Values['handoff'] -ceq "handoffs/local/sample repo-$id/HANDOFF.md")) (@($roots) + $result.Lines)

        $empty = Join-Path $box.Root 'Empty Repo'
        Invoke-Git @('init', '--quiet', '-b', 'main', $empty) | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $empty
        Test-Check 'a repo with no commits yet goes by its folder name alone' ($result.Values['handoff'] -ceq 'handoffs/local/empty repo/HANDOFF.md') $result.Lines

        # A shallow clone's oldest commit is only where the download stopped, not the first one.
        $source = Join-Path $box.Root 'shallow-source'
        Invoke-Git @('init', '--quiet', '-b', 'main', $source) | Out-Null
        Invoke-Git @('-C', $source, 'commit', '--quiet', '--allow-empty', '-m', 'test: one') | Out-Null
        Invoke-Git @('-C', $source, 'commit', '--quiet', '--allow-empty', '-m', 'test: two') | Out-Null
        $shallow = Join-Path $box.Root 'Shallow Clone'
        Invoke-Git @('clone', '--quiet', '--depth', '1', ('file:///' + $source.Replace('\', '/')), $shallow) | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $shallow
        Test-Check 'a shallow clone goes by its folder name alone' ($result.Values['handoff'] -ceq 'handoffs/local/shallow clone/HANDOFF.md') $result.Lines

        $plain = Join-Path $box.Root 'Plain Folder'
        New-Item -ItemType Directory -Path $plain | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $plain
        Test-Check 'a folder outside git goes under local, by its name, and is the project folder' (($result.Values['handoff'] -ceq 'handoffs/local/plain folder/HANDOFF.md') -and ($result.Values['project'] -ceq '.')) $result.Lines

        $main = Join-Path $box.Root 'Main Checkout'
        $worktree = Join-Path $box.Root 'worktree'
        Invoke-Git @('init', '--quiet', '-b', 'main', $main) | Out-Null
        Invoke-Git @('-C', $main, 'commit', '--quiet', '--allow-empty', '-m', 'test: main') | Out-Null
        Invoke-Git @('-C', $main, 'worktree', 'add', '--quiet', $worktree) | Out-Null
        $mainId = Get-TestFirstCommit -Repo $main
        $result = Invoke-Facts -Script $facts -Folder $worktree
        Test-Check 'a worktree with no origin uses its main checkout''s folder name and first commit' ($result.Values['handoff'] -ceq "handoffs/local/main checkout-$mainId/HANDOFF.md") $result.Lines
        Invoke-Git @('-C', $main, 'remote', 'add', 'origin', 'git@github.com:you/tool.git') | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $worktree
        Test-Check 'a worktree uses its main checkout''s origin' ($result.Values['handoff'] -ceq 'handoffs/github/you/tool/HANDOFF.md') $result.Lines

        # The newer-commits topic, which reads the State line of the handoff in the sandbox's
        # dev-home.
        $newer = Join-Path $box.Root 'Newer Repo'
        Invoke-Git @('init', '--quiet', '-b', 'main', $newer) | Out-Null
        Invoke-Git @('-C', $newer, 'commit', '--quiet', '--allow-empty', '-m', 'test: checked') | Out-Null
        Invoke-Git @('-C', $newer, 'remote', 'add', 'origin', 'https://github.com/you/newer.git') | Out-Null
        $checkedId = (Invoke-Git @('-C', $newer, 'rev-parse', '--short=7', 'HEAD'))[0]
        $newerHandoff = Join-Path $box.Content 'handoffs/github/you/newer/HANDOFF.md'
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        Test-Check 'with no handoff yet, newer-commits prints none and unknown, and nothing else' (($result.ExitCode -eq 0) -and (($result.Lines -join '|') -ceq 'checked: none|newer: unknown|behind: unknown')) $result.Lines

        # A State line over two lines: a word of hex letters and a number, neither a commit here,
        # then the checked commit.
        $state = ('**State as of 2026-01-02.** Checked against `deadbee` and `1234567`, then' + "`n" + 'against `{0}`, with 140 tests passing.') -f $checkedId
        Write-TextFile -Path $newerHandoff -Text ("# newer handoff`n`n---`n`n" + $state + "`n`n## Next up`n`n- Nothing yet.`n")
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        Test-Check 'takes the hash the repo has, takes neither a hex word nor a number for a missing one, and counts nothing newer or behind yet' (($result.ExitCode -eq 0) -and (($result.Lines -join '|') -ceq "checked: $checkedId|newer: 0|behind: 0")) $result.Lines

        Invoke-Git @('-C', $newer, 'commit', '--quiet', '--allow-empty', '-m', 'test: second') | Out-Null
        Invoke-Git @('-C', $newer, 'commit', '--quiet', '--allow-empty', '-m', 'test: third') | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        $listed = @($result.Lines | Where-Object { $_ -like 'newer-commit: *' })
        Test-Check 'lists each newer commit, newest first, with its short hash and subject' (($result.Values['newer'] -ceq '2') -and ($listed.Count -eq 2) -and ($listed[0] -match '^newer-commit: [0-9a-f]{7,} test: third$') -and ($listed[1] -match '^newer-commit: [0-9a-f]{7,} test: second$')) $result.Lines

        foreach ($n in 1..10) { Invoke-Git @('-C', $newer, 'commit', '--quiet', '--allow-empty', '-m', "test: more $n") | Out-Null }
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        $listed = @($result.Lines | Where-Object { $_ -like 'newer-commit: *' })
        Test-Check 'lists at most ten newer commits, and counts them all' (($result.Values['newer'] -ceq '12') -and ($listed.Count -eq 10) -and ($listed[0] -match 'test: more 10$')) $result.Lines

        $subject = 'test: r{0}sum{0}' -f [char]0xE9
        Invoke-Git @('-C', $newer, 'commit', '--quiet', '--allow-empty', '-m', $subject) | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        $listed = @($result.Lines | Where-Object { $_ -like 'newer-commit: *' })
        Test-Check 'reads a commit subject with an accented letter as it is' (($listed.Count -gt 0) -and $listed[0].EndsWith(" $subject", [System.StringComparison]::Ordinal)) $result.Lines

        # Naming the latest commit after an earlier one: the latest is the one checked.
        $headId = (Invoke-Git @('-C', $newer, 'rev-parse', '--short=7', 'HEAD'))[0]
        $state = ('**State as of 2026-01-03.** Started from `{0}`, then checked against `{1}`.' -f $checkedId, $headId)
        Write-TextFile -Path $newerHandoff -Text ("# newer handoff`n`n" + $state + "`n")
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        Test-Check 'of two commits the State line names, takes the one with the fewest commits after it' (($result.Lines -join '|') -ceq "checked: $headId|newer: 0|behind: 0") $result.Lines

        # This checkout falls behind the checked commit, as a PC does before it pulls.
        Invoke-Git @('-C', $newer, 'reset', '--quiet', '--hard', 'HEAD~2') | Out-Null
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        Test-Check 'counts the commits the checked one has that this checkout doesn''t' (($result.Lines -join '|') -ceq "checked: $headId|newer: 0|behind: 2") $result.Lines

        # A commit named in backticks that this checkout doesn't have at all, even beside one it has.
        $state = ('**State as of 2026-01-04.** Checked against `abc1234`, after `{0}`.' -f $checkedId)
        Write-TextFile -Path $newerHandoff -Text ("# newer handoff`n`n" + $state + "`n")
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        Test-Check 'a named commit this checkout lacks is missing, and nothing is counted' (($result.Lines -join '|') -ceq 'checked: missing abc1234|newer: unknown|behind: unknown') $result.Lines

        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('handoff', 'environment', 'newer-commits')
        Test-Check 'prints after the other topics when asked last' (($result.ExitCode -eq 0) -and ((@($result.Keys | Select-Object -First 10) -join ' ') -ceq 'service name handoff draft link project environment checked newer behind')) $result.Lines

        Write-TextFile -Path $newerHandoff -Text ("# newer handoff`n`n**State as of 2026-01-02.** Nothing checked yet.`n`n## Next up`n`n" + ('- Start from `{0}`.' -f $checkedId) + "`n")
        $result = Invoke-Facts -Script $facts -Folder $newer -Topics @('newer-commits')
        Test-Check 'a hash outside the State line doesn''t count' (($result.ExitCode -eq 0) -and (($result.Lines -join '|') -ceq 'checked: none|newer: unknown|behind: unknown')) $result.Lines

        # History git can't walk: the checked commit is there, but one after it is missing.
        $gap = Join-Path $box.Root 'Gap Repo'
        Invoke-Git @('init', '--quiet', '-b', 'main', $gap) | Out-Null
        Invoke-Git @('-C', $gap, 'remote', 'add', 'origin', 'https://github.com/you/gap.git') | Out-Null
        foreach ($n in 1..3) { Invoke-Git @('-C', $gap, 'commit', '--quiet', '--allow-empty', '-m', "test: gap $n") | Out-Null }
        $gapFirst = (Invoke-Git @('-C', $gap, 'rev-parse', 'HEAD~2'))[0]
        $gapMiddle = (Invoke-Git @('-C', $gap, 'rev-parse', 'HEAD~1'))[0]
        # Git makes its object files read-only.
        $object = Join-Path $gap ('.git/objects/{0}/{1}' -f $gapMiddle.Substring(0, 2), $gapMiddle.Substring(2))
        [System.IO.File]::SetAttributes($object, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($object)
        Write-TextFile -Path (Join-Path $box.Content 'handoffs/github/you/gap/HANDOFF.md') -Text ('**State as of 2026-01-02.** Checked against `{0}`.' -f $gapFirst.Substring(0, 7))
        $result = Invoke-Facts -Script $facts -Folder $gap -Topics @('handoff', 'newer-commits')
        Test-Check 'when git can''t count, says unknown, and the other topics still print' (($result.ExitCode -eq 0) -and ($result.Values['handoff'] -ceq 'handoffs/github/you/gap/HANDOFF.md') -and ($result.Values['checked'] -ceq $gapFirst.Substring(0, 7)) -and ($result.Values['newer'] -ceq 'unknown') -and ($result.Values['behind'] -ceq 'unknown')) $result.Lines

        # A repo with SHA-256 hashes, named in full.
        $sha256 = Join-Path $box.Root 'Sha256 Repo'
        Invoke-Git @('init', '--quiet', '--object-format=sha256', '-b', 'main', $sha256) | Out-Null
        Invoke-Git @('-C', $sha256, 'remote', 'add', 'origin', 'https://github.com/you/sha256.git') | Out-Null
        Invoke-Git @('-C', $sha256, 'commit', '--quiet', '--allow-empty', '-m', 'test: first') | Out-Null
        $longId = (Invoke-Git @('-C', $sha256, 'rev-parse', 'HEAD'))[0]
        Write-TextFile -Path (Join-Path $box.Content 'handoffs/github/you/sha256/HANDOFF.md') -Text ('**State as of 2026-01-02.** Checked against `{0}`.' -f $longId)
        $result = Invoke-Facts -Script $facts -Folder $sha256 -Topics @('newer-commits')
        Test-Check 'finds a full SHA-256 hash in the State line' (($longId.Length -eq 64) -and (($result.Lines -join '|') -ceq ('checked: {0}|newer: 0|behind: 0' -f $longId.Substring(0, 7)))) (@("hash: $longId") + $result.Lines)

        # When git fails, a guessed path would file the handoff in the wrong place.
        $broken = Join-Path $box.Root 'Broken Repo'
        Invoke-Git @('init', '--quiet', '-b', 'main', $broken) | Out-Null
        Invoke-Git @('-C', $broken, 'commit', '--quiet', '--allow-empty', '-m', 'test: first') | Out-Null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[broken'
        $result = Invoke-Facts -Script $facts -Folder $broken
        Test-Check 'in a repo git can''t read, stops with git''s error instead of guessing' (($result.ExitCode -eq 1) -and (-not $result.Values.ContainsKey('handoff')) -and (Test-HasLine $result.Lines 'bad config')) $result.Lines
        $result = Invoke-Facts -Script $facts -Folder $broken -Topics @('environment', 'handoff')
        Test-Check 'when one topic fails, prints no fact from the others either' (($result.ExitCode -eq 1) -and ($result.Keys.Count -eq 0)) $result.Lines

        $path = $env:PATH
        $env:PATH = (@($path -split ';' | Where-Object { $_ -and (-not (Test-Path -LiteralPath (Join-Path $_ 'git.exe'))) }) -join ';')
        try { $result = Invoke-Facts -Script $facts -Folder $main } finally { $env:PATH = $path }
        Test-Check 'without git, stops with a message instead of guessing' (($result.ExitCode -eq 1) -and (-not $result.Values.ContainsKey('handoff')) -and (Test-HasLine $result.Lines 'git was not found')) $result.Lines
    }
    finally {
        $env:GIT_CEILING_DIRECTORIES = $ceiling
        $env:CLAUDE_CODE_ENTRYPOINT = $entrypoint
    }

    Test-RealProfile -Box $box
    Complete-Group -Box $box
}

# ---------------------------------------------------------------------------------------------
# The skills' prepare.ps1

function Test-Prepare {
    Write-Host
    Write-Host 'skill scripts: prepare.ps1' -ForegroundColor Cyan
    $script:GroupFailed = $false
    $box = New-Sandbox -Name 'prepare' -ToolsRepo
    $run = Invoke-Script -Path (Join-Path $box.Tools 'setup.ps1') -Arguments @('-Quiet')
    Test-Check 'setup runs cleanly first' ($run.ExitCode -eq 0) $run.Lines
    $prepare = Join-Path $box.Tools '.generated/skill-scripts/prepare.ps1'
    $settingsPath = Join-Path $box.Tools 'local-settings.json'

    # As for facts.ps1: git stops at the sandbox, and the links are the relative form.
    $ceiling = $env:GIT_CEILING_DIRECTORIES
    $env:GIT_CEILING_DIRECTORIES = $box.Root.Replace('\', '/')
    $entrypoint = $env:CLAUDE_CODE_ENTRYPOINT
    $env:CLAUDE_CODE_ENTRYPOINT = $null
    try {
        $repo = Join-Path $box.Root 'project'
        Invoke-Git @('init', '--quiet', '-b', 'main', $repo) | Out-Null
        Invoke-Git @('-C', $repo, 'commit', '--quiet', '--allow-empty', '-m', 'test: first') | Out-Null
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', 'https://github.com/you/tool.git') | Out-Null

        $result = Invoke-Facts -Script $prepare -Folder $repo -Topics @('handoff', 'environment', 'newer-commits')
        $lines = [string[]]$result.Lines
        $syncAt = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -match '^OK\s+dev-home is up to date' })
        $factsAt = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -match '^service: ' })
        Test-Check 'syncs first, then prints the facts asked for, in order, and exits 0' (($result.ExitCode -eq 0) -and ($syncAt -ge 0) -and ($factsAt -gt $syncAt) -and (($result.Keys -join ' ') -ceq 'service name handoff draft link project environment checked newer behind')) $result.Lines

        $result = Invoke-Facts -Script $prepare -Folder $repo -Topics @()
        Test-Check 'with no topics, only syncs' (($result.ExitCode -eq 0) -and (Test-HasLine $result.Lines '^OK\s+dev-home is up to date') -and ($result.Keys.Count -eq 0)) $result.Lines

        # Accented letters reach the output as they are, through both scripts.
        Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', 'https://dev.azure.com/Org/Proj/_git/R%C3%A9po') | Out-Null
        $result = Invoke-Facts -Script $prepare -Folder $repo -Topics @('handoff')
        Invoke-Git @('-C', $repo, 'remote', 'set-url', 'origin', 'https://github.com/you/tool.git') | Out-Null
        $accented = 'handoffs/azure-devops/org/proj/r{0}po/HANDOFF.md' -f [char]0xE9
        Test-Check 'passes on an accented letter in a fact as it is' ($result.Values['handoff'] -ceq $accented) (@("expected: $accented") + $result.Lines)

        $result = Invoke-Facts -Script $prepare -Folder $repo -Topics @('handoff', 'weather')
        Test-Check 'when facts.ps1 stops, says why on a PROBLEM line, prints no fact, and still exits 0' (($result.ExitCode -eq 0) -and (Test-HasLine $result.Lines '^PROBLEM\s+facts\.ps1 stopped.*No such topic: weather') -and ($result.Keys.Count -eq 0)) $result.Lines

        # sync.ps1 stops and exits 1 without local-settings.json, before it could run setup.
        $hidden = $settingsPath + '.off'
        [System.IO.File]::Move($settingsPath, $hidden)
        try { $result = Invoke-Facts -Script $prepare -Folder $repo -Topics @('environment') }
        finally { [System.IO.File]::Move($hidden, $settingsPath) }
        Test-Check 'when the sync reports a problem, still prints the facts and exits 0' (($result.ExitCode -eq 0) -and (Test-HasLine $result.Lines '^PROBLEM\s.*not set up on this PC') -and ($result.Keys -contains 'environment')) $result.Lines

        # A changed template reaches the facts in the same run, because the sync's setup writes
        # the new copy before facts.ps1 runs.
        $template = Join-Path $box.Tools 'templates/skill-scripts/facts.ps1'
        $text = [System.IO.File]::ReadAllText($template)
        Write-TextFile -Path $template -Text $text.Replace("'environment: {0}' -f", "'environment: {0} (new copy)' -f")
        $result = Invoke-Facts -Script $prepare -Folder $repo -Topics @('environment')
        Test-Check 'runs the facts.ps1 copy that the sync''s setup has just written' (($result.ExitCode -eq 0) -and ($result.Values['environment'] -like '* (new copy)')) $result.Lines
    }
    finally {
        $env:GIT_CEILING_DIRECTORIES = $ceiling
        $env:CLAUDE_CODE_ENTRYPOINT = $entrypoint
    }

    Test-RealProfile -Box $box
    Complete-Group -Box $box
}

# ---------------------------------------------------------------------------------------------
# internal/shared/, read without running anything

function Find-ProcessWideChange {
    # Where a script changes what its whole process shares: environment variables, the current
    # folder, or a static property such as [Console]::OutputEncoding. Read from the parsed script
    # rather than its text, so an alias such as cd counts too.
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
    # Definition, not ResolvedCommandName, which stays empty until the command's module loads.
    $aliases = @{}
    foreach ($alias in @(Get-Alias)) { $aliases[$alias.Name] = $alias.Definition }
    $folderCommands = @('Set-Location', 'Push-Location', 'Pop-Location')
    $itemWriters = @('Set-Item', 'New-Item', 'Remove-Item', 'Clear-Item', 'Rename-Item', 'Move-Item', 'Copy-Item', 'Set-Content', 'Add-Content', 'Clear-Content')
    foreach ($node in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $command = $node.GetCommandName()
        if (-not $command) { continue }
        if ($aliases.ContainsKey($command)) { $command = $aliases[$command] }
        $toEnv = @($node.CommandElements | Where-Object { $_.Extent.Text -match '^[''"]?env:' }).Count -gt 0
        if (($folderCommands -contains $command) -or (($itemWriters -contains $command) -and $toEnv)) { $node }
    }
    foreach ($node in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $left = $node.Left
        if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if (($left -is [System.Management.Automation.Language.VariableExpressionAst]) -and ($left.VariablePath.DriveName -eq 'env')) {
            $node
            continue
        }
        # A static property, or a property of one, such as [Console]::Out.NewLine.
        while ($left -is [System.Management.Automation.Language.MemberExpressionAst]) {
            if ($left.Static) {
                $node
                break
            }
            $left = $left.Expression
        }
    }
    foreach ($node in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($node.Static -and (@('SetEnvironmentVariable', 'SetCurrentDirectory') -contains $node.Member.Value)) { $node }
    }
}

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

    # A script's own function with the same name would quietly replace the shared one.
    $clashes = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('setup.ps1', 'sync.ps1', 'update.ps1')) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $name), [ref]$null, [ref]$null)
        foreach ($function in $ast.FindAll($isFunction, $true)) {
            if ($sharedNames -contains $function.Name) { $clashes.Add(('{0} defines {1}' -f $name, $function.Name)) }
        }
    }
    Test-Check 'no script defines a function that internal/shared/ already defines' (($sharedNames.Count -gt 0) -and ($clashes.Count -eq 0)) $clashes

    # sync.ps1 runs these inside its own process, so a change they made to what the whole process
    # shares would carry over into the rest of the sync. First, that the search finds each kind
    # of change, and no reads.
    $planted = @('cd C:/', 'Push-Location C:/', 'Set-Item env:PLANTED 1', '$env:PLANTED = 1',
        '[System.Environment]::SetEnvironmentVariable(''PLANTED'', ''1'')', '[Environment]::CurrentDirectory = ''C:/''',
        '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8')
    $reads = @('$read = $env:PLANTED', 'Get-Item env:PLANTED', '$read = [Console]::IsOutputRedirected', 'Get-Location')
    $sample = [System.Management.Automation.Language.Parser]::ParseInput((($planted + $reads) -join "`n"), [ref]$null, [ref]$null)
    $caught = @(Find-ProcessWideChange -Ast $sample | ForEach-Object { $_.Extent.Text })
    Test-Check 'the search for process-wide changes finds each kind, aliases included, and no reads' (($caught.Count -eq $planted.Count) -and (@($planted | Where-Object { $caught -notcontains $_ }).Count -eq 0)) $caught

    $leaks = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($sharedFiles + @('update.ps1'))) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $name), [ref]$null, [ref]$null)
        foreach ($node in @(Find-ProcessWideChange -Ast $ast)) {
            $leaks.Add(('{0}:{1}: {2}' -f $name, $node.Extent.StartLineNumber, $node.Extent.Text))
        }
    }
    Test-Check 'what sync.ps1 runs in its own process changes nothing the whole process shares' ($leaks.Count -eq 0) $leaks

    # pwsh -File keeps sync.ps1's top-level variables in the global scope, where a script it runs
    # in its own process can see them. So such a script sets every variable it reads: one it left
    # unset would quietly pick up sync's variable of the same name.
    $automatic = @('_', 'args', 'input', 'PSItem', 'true', 'false', 'null', 'this', 'PSScriptRoot', 'PSCommandPath',
        'MyInvocation', 'PSCmdlet', 'PSBoundParameters', 'LASTEXITCODE', 'Matches', 'HOME', 'PWD', 'PID', 'Host',
        'ErrorActionPreference', 'WhatIfPreference', 'IsWindows', 'PSVersionTable', 'Error')
    $isVariable = { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }
    $unset = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($sharedFiles + @('update.ps1'))) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $name), [ref]$null, [ref]$null)
        $set =[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $targets = @(foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) { $node.Left.FindAll($isVariable, $true) }) +
            @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { $_.Name }) +
            @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable })
        foreach ($variable in $targets) { [void]$set.Add(($variable.VariablePath.UserPath -replace '^(script|global|local|private):', '')) }
        foreach ($variable in $ast.FindAll($isVariable, $true)) {
            if ($variable.VariablePath.IsDriveQualified) { continue }
            $read = $variable.VariablePath.UserPath -replace '^(script|global|local|private):', ''
            if ((-not $set.Contains($read)) -and ($automatic -notcontains $read)) { $unset.Add(('{0}:{1}: ${2}' -f $name, $variable.Extent.StartLineNumber, $read)) }
        }
    }
    Test-Check 'what sync.ps1 runs in its own process reads only variables it sets itself' ($unset.Count -eq 0) $unset
}

# ---------------------------------------------------------------------------------------------
# templates/skill-scripts/, read without running anything

function Find-ChangeOrNetworkUse {
    # Where a script changes something or reaches the network, as far as its text can show: a
    # command that writes, removes, downloads, or starts another program; output sent to a file;
    # a .NET call that writes a file or uses the network; a command whose name is worked out as
    # it runs; or git, unless it goes through Invoke-Git with a subcommand that only reads. Read
    # from the parsed script, so an alias such as rm counts too. Returns each statement found.
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
    $aliases = @{}
    foreach ($alias in @(Get-Alias)) { $aliases[$alias.Name] = $alias.Definition }
    $banned = @('Set-Content', 'Add-Content', 'Clear-Content', 'Out-File', 'New-Item', 'Remove-Item', 'Move-Item', 'Copy-Item',
        'Rename-Item', 'Set-Item', 'Clear-Item', 'Set-ItemProperty', 'Export-Csv', 'Export-Clixml', 'Start-Process',
        'Invoke-Expression', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'Test-Connection',
        'Test-NetConnection', 'gh', 'curl', 'wget', 'ssh', 'scp', 'pwsh', 'powershell', 'cmd')
    # What Invoke-Git may be given: the first word, or first two, of a git command that only reads.
    $gitReads = @('rev-parse', 'rev-list', 'remote get-url')
    $isString = { $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }

    $found = [System.Collections.Generic.List[System.Management.Automation.Language.Ast]]::new()
    foreach ($node in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $command = $node.GetCommandName()
        if (-not $command) { $found.Add($node); continue }
        if ($aliases.ContainsKey($command)) { $command = $aliases[$command] }
        $command = $command -replace '\.exe$', ''
        if ($banned -contains $command) { $found.Add($node); continue }
        if ($command -eq 'git') {
            # Only the function that wraps git may run it. What that function is given is checked
            # where it's called.
            $function = $node.Parent
            while ($function -and ($function -isnot [System.Management.Automation.Language.FunctionDefinitionAst])) { $function = $function.Parent }
            if ((-not $function) -or ($function.Name -ne 'Invoke-Git')) { $found.Add($node) }
            continue
        }
        if ($command -eq 'Invoke-Git') {
            $words = @()
            for ($i = 0; $i -lt ($node.CommandElements.Count - 1); $i++) {
                $element = $node.CommandElements[$i]
                if (($element -is [System.Management.Automation.Language.CommandParameterAst]) -and ($element.ParameterName -eq 'Arguments')) {
                    $words = @($node.CommandElements[$i + 1].FindAll($isString, $true) | ForEach-Object { $_.Value })
                }
            }
            $firstTwo = @($words | Select-Object -First 2) -join ' '
            if (($words.Count -eq 0) -or (($gitReads -notcontains $words[0]) -and ($gitReads -notcontains $firstTwo))) { $found.Add($node) }
        }
    }
    foreach ($node in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)) {
        if ($node.Location.Extent.Text -ne '$null') { $found.Add($node) }
    }
    foreach ($node in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ((-not $node.Static) -or ($node.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst])) { continue }
        if (($node.Expression.TypeName.FullName -match '(^|\.)(File|Directory)$') -and ($node.Member.Value -notmatch '^(Exists|Read\w*|Get\w*|Enumerate\w*)$')) { $found.Add($node) }
    }
    foreach ($node in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] }, $true)) {
        if ($node.TypeName.FullName -match '(^|\.)(Net|Diagnostics)\.|Registry') { $found.Add($node) }
    }

    # The whole statement each one is in, once each.
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($node in $found) {
        $statement = $node
        while ($statement.Parent -and ($statement -isnot [System.Management.Automation.Language.PipelineAst])) { $statement = $statement.Parent }
        if ($statement -isnot [System.Management.Automation.Language.PipelineAst]) { $statement = $node }
        if ($seen.Add($statement.Extent.StartOffset)) { $statement }
    }
}

function Test-SkillScripts {
    Write-Host
    Write-Host 'templates/skill-scripts/' -ForegroundColor Cyan
    $script:GroupFailed = $false
    $scriptsRoot = Join-Path $RepoRoot 'templates/skill-scripts'
    $shared = @(Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File)
    # A skill is a folder with a SKILL.md, as setup sees it.
    $skills = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'templates/skills') -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })

    # Each script's description names the skills that run it, so whoever changes the script knows
    # what depends on it. A skill runs it when any of the skill's files holds its path.
    $wrongCallers = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $shared) {
        $listed = @()
        if ((Get-Content -LiteralPath $file.FullName -Raw) -match '(?m)^\s*Called by:\s*(.+?)\s*$') { $listed = @($Matches[1] -split '\s*,\s*' | Sort-Object) }
        $path = '{{SKILL_SCRIPTS_DIR}}/' + $file.Name
        $callers = @($skills | Where-Object {
                @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Where-Object { ([string](Get-Content -LiteralPath $_.FullName -Raw)).Contains($path) }).Count -gt 0
            } | ForEach-Object { $_.Name } | Sort-Object)
        if (($listed -join ', ') -cne ($callers -join ', ')) {
            $wrongCallers.Add(('{0} says "Called by: {1}", but these skills run it: {2}' -f $file.Name, ($listed -join ', '), ($callers -join ', ')))
        }
    }
    Test-Check 'each shared script lists exactly the skills that run it' (($shared.Count -gt 0) -and ($wrongCallers.Count -eq 0)) $wrongCallers

    # A skill writes each command in full, and pre-approves that exact text, so a command that
    # differs by one word would ask the user first.
    $commands = 0
    $wrongCommands = [System.Collections.Generic.List[string]]::new()
    foreach ($skill in $skills) {
        $text = [string](Get-Content -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -Raw)
        $allowed = if ($text -match '(?m)^allowed-tools:\s*"(.*)"\s*$') { $Matches[1] } else { '' }
        foreach ($match in [regex]::Matches($text, '`(pwsh -NoProfile -File \{\{SKILL_SCRIPTS_DIR\}\}/([^\s`]+)[^`]*)`')) {
            $commands++
            if (-not (Test-Path -LiteralPath (Join-Path $scriptsRoot $match.Groups[2].Value) -PathType Leaf)) {
                $wrongCommands.Add(('{0} runs {1}, which is not in templates/skill-scripts/' -f $skill.Name, $match.Groups[2].Value))
            }
            if (-not $allowed.Contains(('Bash({0})' -f $match.Groups[1].Value))) {
                $wrongCommands.Add(('{0} does not pre-approve: {1}' -f $skill.Name, $match.Groups[1].Value))
            }
        }
    }
    Test-Check 'each shared-script command in a skill names a script that exists, and is pre-approved word for word' (($commands -gt 0) -and ($wrongCommands.Count -eq 0)) $wrongCommands

    # facts.ps1 only reports, and only from this PC, which is what lets a skill run it without
    # asking. First, that the search finds each kind of change and network use, and no reads.
    $planted = @('Set-Content x.txt 1', 'rm x.txt', '"a" > x.txt', '[System.IO.File]::WriteAllText(''x'', ''y'')',
        'Invoke-WebRequest https://example.com', '[System.Net.WebClient]::new()', 'gh issue list', 'git fetch',
        'Invoke-Git -Arguments @(''fetch'', ''origin'')', '& $anything')
    $reads = @('Get-Content x.txt', '$read = [System.IO.File]::ReadAllText(''x'')', 'Test-Path x', '$read = "a" 2>$null',
        '[regex]::Replace(''a'', ''b'', ''c'')', 'Invoke-Git -Arguments @(''rev-parse'', ''HEAD'')',
        'Invoke-Git -Arguments @(''remote'', ''get-url'', ''origin'')', 'function Invoke-Git { param($Arguments) & git @Arguments }')
    $sample = [System.Management.Automation.Language.Parser]::ParseInput((($planted + $reads) -join "`n"), [ref]$null, [ref]$null)
    $caught = @(Find-ChangeOrNetworkUse -Ast $sample | ForEach-Object { $_.Extent.Text })
    Test-Check 'the search for changes and network use finds each kind, aliases included, and no reads' (($caught.Count -eq $planted.Count) -and (@($planted | Where-Object { $caught -notcontains $_ }).Count -eq 0)) $caught

    $uses = [System.Collections.Generic.List[string]]::new()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'facts.ps1'), [ref]$null, [ref]$null)
    foreach ($node in @(Find-ChangeOrNetworkUse -Ast $ast)) {
        $uses.Add(('facts.ps1:{0}: {1}' -f $node.Extent.StartLineNumber, $node.Extent.Text))
    }
    Test-Check 'facts.ps1 changes nothing and never uses the network' ($uses.Count -eq 0) $uses
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
Test-Setup
Test-Sync
Test-Facts
Test-Prepare
Test-Shared
Test-SkillScripts
Test-Docs
Write-Host
if ($script:Failures -gt 0) {
    Write-Host ('{0} of {1} checks failed.' -f $script:Failures, $script:Checks) -ForegroundColor Red
    exit 1
}
Write-Host ('All {0} checks passed.' -f $script:Checks) -ForegroundColor Green
exit 0
