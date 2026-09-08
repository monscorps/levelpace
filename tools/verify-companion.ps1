<#
    Verify the welded companion launcher.

    This shipped broken once. The launcher searched for a literal '#PSSTART'
    marker, but the launcher LINE ITSELF contained that literal -- so IndexOf
    found its own occurrence, PowerShell received the tail of the batch line
    followed by `exit /b`, and `exit` is a PowerShell keyword. The session
    quit on its second statement. The window flashed, closed, and left no
    icon and no error.

    Nothing about that was visible from a Mac, which is exactly why it needs
    to be a build gate rather than a thing someone remembers to check.

    Usage:  pwsh -NoProfile -File tools/verify-companion.ps1 <path-to-bat>
    Exits non-zero with a reason if the launcher would not start.
#>

param([Parameter(Mandatory = $true)][string] $Bat)

if (-not (Test-Path $Bat)) {
    Write-Host "not found: $Bat"
    exit 1
}

$s = [IO.File]::ReadAllText($Bat)
$marker = '#PS' + 'START'

# 1. The launcher line must not contain the literal marker.
$launcher = ($s -split "`r?`n") | Where-Object { $_ -like 'powershell *' } | Select-Object -First 1
if (-not $launcher) {
    Write-Host "no launcher line found"
    exit 1
}
if ($launcher.Contains($marker)) {
    Write-Host "launcher line contains the literal marker, so IndexOf will find itself"
    exit 1
}

# 2. The marker must exist exactly once.
$count = ([regex]::Matches($s, [regex]::Escape($marker))).Count
if ($count -ne 1) {
    Write-Host "expected exactly 1 marker, found $count"
    exit 1
}

# 3. Extract exactly as the launcher does.
$idx = $s.IndexOf($marker)
$payload = $s.Substring($idx)

# 4. The first executable statement must not be a batch directive. This is the
#    specific failure that shipped: `exit /b` reaching PowerShell.
$firstExec = ($payload -split "`r?`n") |
    Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') } |
    Select-Object -First 1
if ($firstExec -match '^\s*exit\b') {
    Write-Host "payload begins with '$firstExec' -- PowerShell would quit immediately"
    exit 1
}

# 5. The payload must parse as PowerShell.
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($payload, [ref] $null, [ref] $errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Host "payload has $($errs.Count) parse error(s):"
    $errs | Select-Object -First 5 | ForEach-Object {
        Write-Host ("  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message)
    }
    exit 1
}

# 6. The tray icon is the whole point; if it is not created, nothing is.
foreach ($needle in @('NotifyIcon', 'Application]::Run', 'ContextMenuStrip')) {
    if (-not $payload.Contains($needle)) {
        Write-Host "payload never references '$needle' -- there would be no tray icon"
        exit 1
    }
}

Write-Host "companion weld OK (payload extracts, parses, and builds a tray icon)"
exit 0
