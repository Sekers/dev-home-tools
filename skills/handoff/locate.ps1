#Requires -Version 7.2
<#
.SYNOPSIS
    Prints where the current project's handoff lives in dev-home.

.DESCRIPTION
    Run it in the project's folder. It reads the project's origin address from the project's own
    git config, so it needs no network and no sign-in, and prints six lines:

        service: github
        name: you/tool
        handoff: handoffs/github/you/tool/HANDOFF.md
        draft: .drafts/github/you/tool/issue.md
        link: ../dev-home/handoffs/github/you/tool/HANDOFF.md
        project: .

    The handoff and draft paths are relative to dev-home. Everything is lowercase, so two PCs
    whose addresses differ only in case get the same handoff.

    The link is the handoff, and project is the project's folder (the top of this checkout), as
    link targets for an agent's replies: an agent links a project file as project, a slash, and
    the file's path in the project. Both are percent-encoded like a URL path, so a space becomes
    %20, and both take the form that opens where the agent is running:
    - In Claude Code's CLI, file:/// URLs, such as file:///C:/Users/you/dev-home/handoffs/...: the
      CLI's terminal opens those, but not a relative path. Claude Code says where it's running in
      CLAUDE_CODE_ENTRYPOINT, which is cli there.
    - Everywhere else, paths relative to the current folder: some editors can't open a link to a
      full path that starts with a drive letter. When dev-home is on another drive, there's no
      relative path, so the link is the full path.

    A project hosted on a service in $Services gets a folder under that service's name, with the
    rest of the address after it: <owner>/<repo> for GitHub and Bitbucket, <group>/<project> for
    GitLab (plus any subgroups), and <org>/<project>/<repo> for Azure DevOps. HTTPS and SSH
    addresses give the same folder.

    Any other project is filed by its folder name plus the first 7 characters of its first
    commit, such as tools-3f9c2ab. The first commit is the same in every clone, and differs
    between unrelated repos, so two projects with the same folder name get separate handoffs.
    It goes under:
    - other: its origin is on a host not in $Services, or has a shape the script can't use.
    - local: it has no origin, or its origin is a folder rather than a network address.
    With no commits yet, in a shallow clone, or outside git, there's no first commit to use, so
    the folder name stands alone.

    A worktree uses its main checkout's origin and folder name, so it shares that checkout's
    handoff.

.EXAMPLE
    pwsh -NoProfile -File C:/Users/you/dev-home-tools/.generated/skills/handoff/locate.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Hosting services by the host name in a repo's address. To add one, add its hosts here and its
# path shape to Get-ServicePath, with a test for each address form it documents.
$Services = @{
    'github.com'        = 'github'
    'gitlab.com'        = 'gitlab'
    'bitbucket.org'     = 'bitbucket'
    'dev.azure.com'     = 'azure-devops'
    'ssh.dev.azure.com' = 'azure-devops'
}

# dev-home's folder, filled in by setup. A here-string, so a path with an apostrophe still works.
$ContentDir = @'
{{CONTENT_DIR}}
'@

# Git's messages in English, so "not a git repository" can be told apart from other failures.
$env:LC_ALL = 'C'

function Stop-Locate {
    # Stops without printing a path: a guess would file the handoff in the wrong place.
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Invoke-Git {
    # Runs git in the current folder. Returns the exit code, the first line of output, and the
    # first line of any error.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = [System.Collections.Generic.List[string]]::new()
    $err = [System.Collections.Generic.List[string]]::new()
    & git @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add($_.ToString().Trim()) }
        else { $out.Add(([string]$_).Trim()) }
    }
    $first = if ($out.Count -gt 0) { $out[0] } else { '' }
    $error1 = @($err | Where-Object { $_ }) | Select-Object -First 1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Line = $first; Error = [string]$error1 }
}

function Split-Address {
    # Splits a remote address into its host and the path after it, dropping any scheme, user
    # name, port, and trailing .git. Returns $null for anything else, such as a local path.
    param([Parameter(Mandatory)][string]$Address)
    # A drive path, such as C:\repos\tool, would otherwise look like host:path below.
    if ($Address -match '^[A-Za-z]:[\\/]') { return $null }
    # https://host/path, ssh://user@host:port/path, and the like.
    if ($Address -match '^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/]*@)?(?<host>[^/:@]+)(?::\d+)?/(?<path>.+)$') { }
    # user@host:path, the short form SSH addresses use. A path after the colon never starts with
    # a slash, which keeps out drive paths such as C:/repos/tool.
    elseif ($Address -match '^(?:[^@/:]+@)?(?<host>[^/:@]+):(?<path>[^/].*)$') { }
    else { return $null }
    $path = $Matches['path'].TrimEnd('/')
    if ($path.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring(0, $path.Length - 4) }
    return [pscustomobject]@{ Host = $Matches['host'].ToLowerInvariant(); Path = $path }
}

function Get-ServicePath {
    # The folder names for a service's repo, from the path in its address. Returns $null when the
    # path doesn't have that service's usual shape.
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$Path
    )
    # Decoded before splitting, so an encoded slash can't hide a segment from the checks below.
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in ([System.Uri]::UnescapeDataString($Path).ToLowerInvariant() -split '/')) { $parts.Add($part) }

    if ($Service -eq 'azure-devops') {
        # SSH addresses read v3/<org>/<project>/<repo>, and HTTPS ones <org>/<project>/_git/<repo>.
        # The short HTTPS form <org>/_git/<repo> is for a repo named the same as its project.
        if ($parts[0] -eq 'v3') { $parts.RemoveAt(0) }
        $at = $parts.IndexOf('_git')
        if ($at -ge 0) {
            $parts.RemoveAt($at)
            if (($at -eq 1) -and ($parts.Count -eq 2)) { $parts.Insert(1, $parts[1]) }
        }
        if ($parts.Count -ne 3) { return $null }
    }
    elseif ($Service -eq 'gitlab') {
        if ($parts.Count -lt 2) { return $null }
    }
    elseif ($parts.Count -ne 2) {
        return $null
    }

    foreach ($part in $parts) {
        if (-not (Test-FolderName -Name $part)) { return $null }
    }
    return $parts.ToArray()
}

function Test-FolderName {
    # True when a name is safe as one folder in dev-home: no path tricks, and nothing Windows
    # refuses in a folder name.
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or ($Name -in @('.', '..'))) { return $false }
    if ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    if ($Name -match '[<>:"/\\|?*]') { return $false }
    if ($Name -match '[. ]$') { return $false }
    if ($Name -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$') { return $false }
    return $true
}

function Get-FirstCommitId {
    # The first 7 characters of the first commit on the main line. Following first parents gives
    # one answer even when unrelated histories were merged in. Returns $null with no commits yet,
    # and in a shallow clone, whose oldest commit is only where the download stopped.
    $shallow = Invoke-Git -Arguments @('rev-parse', '--is-shallow-repository')
    if ($shallow.ExitCode -ne 0) { Stop-Locate ('git could not read this repo. git: {0}' -f $shallow.Error) }
    if ($shallow.Line -eq 'true') { return $null }
    # Exit code 1, with --quiet, means there are no commits yet.
    $head = Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')
    if ($head.ExitCode -eq 1) { return $null }
    if ($head.ExitCode -ne 0) { Stop-Locate ('git could not read this repo''s commits. git: {0}' -f $head.Error) }
    $first = Invoke-Git -Arguments @('rev-list', '--first-parent', '--max-parents=0', 'HEAD')
    if (($first.ExitCode -ne 0) -or ($first.Line -notmatch '^[0-9a-f]{40,64}$')) {
        Stop-Locate ('git could not find this repo''s first commit. git: {0}' -f $first.Error)
    }
    return $first.Line.Substring(0, 7)
}

function ConvertTo-LinkTarget {
    # Percent-encodes a forward-slash path the way a URL path is written, so it works as a markdown
    # link's target: a space becomes %20. Letters, digits, and the marks a URL path allows stay as
    # they are, except parentheses, which could end the link early. A drive letter stays too.
    param([Parameter(Mandatory)][string]$Path)
    $parts = foreach ($part in ($Path -split '/')) {
        if ($part -match '^[A-Za-z]:$') { $part; continue }
        [regex]::Replace($part, '[^A-Za-z0-9._~!$&''*+,;=@-]+', { param($m) [System.Uri]::EscapeDataString($m.Value) })
    }
    return $parts -join '/'
}

function ConvertTo-FileUrl {
    # A full path as a file:/// URL, percent-encoded as ConvertTo-LinkTarget does. A network path,
    # such as //server/share, becomes file://server/share.
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).Replace('\', '/').TrimEnd('/')
    if ($full.StartsWith('//')) { return 'file:' + (ConvertTo-LinkTarget -Path $full) }
    return 'file:///' + (ConvertTo-LinkTarget -Path $full)
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Stop-Locate 'git was not found, so the handoff can''t be found. Install Git, or add it to PATH.'
}

# The project's folder: the one holding the main .git, so a worktree gets its main checkout's
# name. Outside a git repo, the current folder. Any other failure stops the script, because
# treating a repo git can't read as a plain folder would give the wrong handoff.
$folder = Split-Path -Leaf $PWD.ProviderPath
$common = Invoke-Git -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
$inRepo = ($common.ExitCode -eq 0) -and $common.Line
if ($inRepo) {
    $folder = Split-Path -Leaf (Split-Path -Parent $common.Line)
}
elseif ($common.Error -notmatch 'not a git repository') {
    Stop-Locate ('git could not read this folder, so the handoff can''t be found. git: {0}' -f $common.Error)
}

$folderName = $folder.ToLowerInvariant()
if (-not (Test-FolderName -Name $folderName)) {
    Stop-Locate ('No handoff can be named after the folder "{0}". Run this in a project folder.' -f $folder)
}

# Where the project is hosted, from its origin address.
$service = 'local'
$parts = $null
if ($inRepo) {
    # Exit code 2 means there's no origin.
    $origin = Invoke-Git -Arguments @('remote', 'get-url', 'origin')
    if (($origin.ExitCode -ne 0) -and ($origin.ExitCode -ne 2)) {
        Stop-Locate ('git could not read this project''s origin. git: {0}' -f $origin.Error)
    }
    if (($origin.ExitCode -eq 0) -and $origin.Line) {
        $address = Split-Address -Address $origin.Line
        if ($null -ne $address) {
            $service = 'other'
            if ($Services.ContainsKey($address.Host)) {
                $servicePath = Get-ServicePath -Service $Services[$address.Host] -Path $address.Path
                if ($null -ne $servicePath) {
                    $service = $Services[$address.Host]
                    $parts = $servicePath
                }
            }
        }
    }
}

# Not on a service in the list: the folder name, and the first commit when there is one.
if ($null -eq $parts) {
    $name = $folderName
    if ($inRepo) {
        $id = Get-FirstCommitId
        if ($id) { $name = '{0}-{1}' -f $folderName, $id }
    }
    $parts = @($name)
}

$relative = (@($service) + $parts) -join '/'
$handoff = 'handoffs/{0}/HANDOFF.md' -f $relative

# The project's folder: the top of this checkout, or the current folder outside one, such as in
# a bare repo.
$projectRoot = $PWD.ProviderPath
if ($inRepo) {
    $top = Invoke-Git -Arguments @('rev-parse', '--show-toplevel')
    if (($top.ExitCode -eq 0) -and $top.Line) { $projectRoot = $top.Line }
}

$handoffPath = '{0}/{1}' -f $ContentDir, $handoff
if ($env:CLAUDE_CODE_ENTRYPOINT -ceq 'cli') {
    $link = ConvertTo-FileUrl -Path $handoffPath
    $project = ConvertTo-FileUrl -Path $projectRoot
}
else {
    $link = ConvertTo-LinkTarget -Path ([System.IO.Path]::GetRelativePath($PWD.ProviderPath, $handoffPath).Replace('\', '/'))
    $project = ConvertTo-LinkTarget -Path ([System.IO.Path]::GetRelativePath($PWD.ProviderPath, $projectRoot).Replace('\', '/'))
}
Write-Output ('service: {0}' -f $service)
Write-Output ('name: {0}' -f ($parts -join '/'))
Write-Output ('handoff: {0}' -f $handoff)
Write-Output ('draft: .drafts/{0}/issue.md' -f $relative)
Write-Output ('link: {0}' -f $link)
Write-Output ('project: {0}' -f $project)
