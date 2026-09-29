#Requires -Version 7.2
<#
.SYNOPSIS
    Runs git for setup.ps1, sync.ps1, and update.ps1, which each load this file.

.DESCRIPTION
    Each script loads this file with a dot-source when it starts, so each gets the copy on disk
    at that moment. After an update, the next script to start uses the new copy, and one that is
    already running keeps the copy it loaded.

    It only defines functions. Nothing here keeps state or changes anything the whole process
    shares, such as environment variables or the current folder, because sync.ps1 runs
    update.ps1 inside its own process.
#>

function Invoke-Git {
    # Runs git in a repo. Returns the exit code, the output and error lines, whether another git
    # process still held a lock, and how many tries it took. A command that finds a lock held by
    # another git process is tried again, 2 seconds apart, up to 5 times. A lock file is never
    # deleted: it may belong to a git that is still running.
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $ErrorActionPreference = 'Continue'
    $maxTries = 5
    for ($try = 1; ; $try++) {
        $out = [System.Collections.Generic.List[string]]::new()
        $err = [System.Collections.Generic.List[string]]::new()
        & git -C $Repo @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add($_.ToString()) }
            else { $out.Add([string]$_) }
        }
        $code = $LASTEXITCODE
        $locked = ($code -ne 0) -and (($err -join "`n") -match "Unable to create '[^']*\.lock'|cannot lock ref|index\.lock|could not lock config file")
        if ((-not $locked) -or ($try -ge $maxTries)) {
            return [pscustomobject]@{ ExitCode = $code; Out = $out.ToArray(); Err = $err.ToArray(); Locked = $locked; Tries = $try }
        }
        Start-Sleep -Seconds 2
    }
}
