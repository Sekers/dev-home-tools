#Requires -Version 7.2
<#
.SYNOPSIS
    Prepares dev-home for a skill command: syncs it, then prints the facts asked for.

.DESCRIPTION
    Called by: handoff, knowledge

    Every skill command that syncs dev-home starts with this script, so that the agent gets what
    it needs before its own work from one call. First it runs sync.ps1, which syncs dev-home with
    GitHub, checks dev-home-tools for updates, and runs setup. Then, when topics are named, it
    runs facts.ps1 with them: the copy beside this one, which that setup run has just brought up
    to date. sync.ps1's lines come first, then the facts.

    It always exits 0. Everything it has to say is in its lines: sync.ps1's status lines, the
    facts, and a PROBLEM line when facts.ps1 or this script stops. A failing exit code would make
    a tool report the whole call as failed, and an agent could stop or retry instead of doing what
    the skill says about each line.

    sync.ps1 and facts.ps1 each run in a PowerShell process of their own, so neither can change
    anything this script relies on, and each starts clean. The facts, like this script's own
    lines, are written as UTF-8; sync.ps1's lines pass through as it writes them.

    Committing is never done here: a skill commits through sync.ps1 -Message.

.PARAMETER Topic
    The facts.ps1 topics to print after the sync, separated by spaces. With none, it only syncs.

.EXAMPLE
    pwsh -NoProfile -File C:/Users/you/dev-home-tools/.generated/skill-scripts/prepare.ps1 handoff environment newer-commits

    Syncs dev-home, then prints where this project's handoff is, the computer's name, and the
    project's commits since the handoff's last check.

.EXAMPLE
    pwsh -NoProfile -File C:/Users/you/dev-home-tools/.generated/skill-scripts/prepare.ps1

    Only syncs.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Topic
)

$ErrorActionPreference = 'Stop'
# A program's failing exit code never stops this script: sync.ps1 exits 1 when the user needs to
# act, and its lines already say why.
$PSNativeCommandUseErrorActionPreference = $false

# dev-home-tools' folder, filled in by setup. A here-string, so a path with an apostrophe still
# works.
$ToolsDir = @'
{{TOOLS_DIR}}
'@

# facts.ps1 writes UTF-8, which agents read. PowerShell reads a program's output and writes its
# own in the console's code page instead, so this script reads facts.ps1's lines as UTF-8, and
# writes its own lines as UTF-8 bytes, keeping an accented letter as it is.
$Utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Utf8 {
    # Writes lines to standard output as UTF-8.
    param([AllowEmptyCollection()][string[]]$Lines)
    $stream = [Console]::OpenStandardOutput()
    $bytes = $Utf8.GetBytes((@($Lines | ForEach-Object { $_ + [System.Environment]::NewLine }) -join ''))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Write-Problem {
    # A PROBLEM line in the same format as sync.ps1's status lines, which skills already handle.
    param([Parameter(Mandatory)][string]$Message)
    Write-Utf8 -Lines ('{0,-9} {1}' -f 'PROBLEM', $Message)
}

try {
    $pwsh = [System.Environment]::ProcessPath

    # sync.ps1 prints its own lines, PROBLEM lines included, straight to this script's output.
    & $pwsh -NoProfile -File (Join-Path $ToolsDir 'sync.ps1')

    $asked = @($Topic | Where-Object { $_ })
    if ($asked.Count -gt 0) {
        # facts.ps1 prints its facts, or only a reason on its error output and exits 1. The
        # reason becomes a PROBLEM line, so it can't be taken for a fact. Changing the console's
        # encoding can also change the code page of a console the script runs in, so it goes
        # back right after.
        $ErrorActionPreference = 'Continue'
        $facts = [System.Collections.Generic.List[string]]::new()
        $reasons = [System.Collections.Generic.List[string]]::new()
        $encoding = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = $Utf8 } catch { $encoding = $null }
        try {
            & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'facts.ps1') @asked 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $reasons.Add($_.ToString().Trim()) }
                else { $facts.Add([string]$_) }
            }
            $code = $LASTEXITCODE
        }
        finally {
            if ($null -ne $encoding) { try { [Console]::OutputEncoding = $encoding } catch { } }
        }
        $ErrorActionPreference = 'Stop'
        if ($code -eq 0) {
            Write-Utf8 -Lines $facts
        }
        else {
            $reason = @(@($reasons) + @($facts) | Where-Object { $_ }) | Select-Object -First 1
            if (-not $reason) { $reason = 'it gave no reason' }
            Write-Problem ('facts.ps1 stopped, so there are no facts: {0}' -f $reason)
        }
    }
}
catch {
    Write-Problem ('prepare.ps1 stopped: {0}' -f $_.Exception.Message)
}
exit 0
