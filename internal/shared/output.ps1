#Requires -Version 7.2
<#
.SYNOPSIS
    Prints status lines and message text for setup.ps1, which loads this file. output.py, beside
    it, does the same for the Python scripts.

.DESCRIPTION
    Setup loads this file with a dot-source when it starts, so it gets the copy on disk at that
    moment. It only defines functions, and setup defines none with the same name (a test checks).
#>

function Test-UseColor {
    # Color only when a person is watching the console. Agents run the scripts with their output
    # redirected, so they get plain text. NO_COLOR turns color off too.
    return ((-not [Console]::IsOutputRedirected) -and (-not $env:NO_COLOR))
}

function Write-StatusLine {
    # One status line: the word, padded so every message starts in the same column, then the
    # message. These are the words docs/reference/scripts.md and the skills explain.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('OK', 'COMMITTED', 'PULLED', 'MERGED', 'PUSHED', 'PENDING', 'OFFLINE', 'LEFT', 'STALE', 'UPDATE',
            'TEST', 'LINKED', 'REMOVED', 'WROTE', 'CREATED', 'SET', 'CHANGE', 'PROBLEM')]
        [string]$State,
        [Parameter(Mandatory)][string]$Message
    )
    $label = '{0,-9} ' -f $State
    if (-not (Test-UseColor)) {
        Write-Output ($label + $Message)
        return
    }
    $color = switch ($State) {
        'OK' { 'Green' }
        'PROBLEM' { 'Red' }
        { $_ -in @('PENDING', 'OFFLINE', 'STALE', 'UPDATE', 'CHANGE', 'TEST') } { 'Yellow' }
        default { 'Cyan' }
    }
    Write-Host $label -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Get-FirstLine {
    # The first line with text in it, for quoting a program's message in one line.
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
