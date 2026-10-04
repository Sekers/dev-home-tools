#Requires -Version 7.2
<#
.SYNOPSIS
    Stands in for the skills' old facts.ps1, which facts.py in templates/shared-skill-scripts/
    replaced.

.DESCRIPTION
    Called by: none

    A session that loaded the handoff skill before this PC moved to facts.py still has steps
    that run this path. It prints why those steps are out of date, and no facts, and exits 1:
    the old steps show the message and stop. When the user runs the skill's command again, the
    agent loads the new steps, with no need for a new session.

    It goes in one cleanup after the move to Python, along with the other old paths.
#>

[Console]::Error.WriteLine('The handoff skill has changed since this session loaded it, so the steps this session has for it are out of date. Stop here, and ask the user to run the skill''s command again, such as /handoff in Claude Code or $handoff in Codex: that loads the new steps, with no need for a new session.')
exit 1
