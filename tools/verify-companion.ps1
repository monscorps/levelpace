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

# 7. RUN it.
#
# Parsing is not enough and this project learned that the expensive way: the
# payload parsed perfectly and still died on line 4, because
# $MyInvocation.MyCommand.Path is NULL under Invoke-Expression and
# `Split-Path -Parent $null` is a terminating error with $ErrorActionPreference
# set to Stop. Nothing catches that except running it.
#
# On macOS the script cannot get past the Windows-only tray icon, and that is
# the point: it must reach THAT line and fail there, not somewhere earlier. If
# it dies before Windows Forms, something is wrong that would also be wrong on
# Windows.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("lp-verify-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$payloadFile = Join-Path $tmp 'payload.ps1'
[IO.File]::WriteAllText($payloadFile, $payload)

# Run the payload and unwrap the WHOLE exception chain.
#
# Running it with -File reports this as "An error occurred while creating the
# pipeline", which names nothing. The real cause is only in the INNER
# exception, so catch it and walk the chain.
$env:LEVELPACE_BAT = (Resolve-Path $Bat).Path
$env:LOCALAPPDATA  = $tmp
$env:TEMP          = $tmp
$pwshPath = (Get-Process -Id $PID).Path

# Invoke-Expression on the STRING, exactly as the launcher does -- NOT `& file`.
# This distinction is the whole point. Run as a file, $MyInvocation.MyCommand.Path
# is populated and the script works; run through iex it is NULL, and that is
# the mode that shipped broken. A test that runs it the easy way proves nothing.
# Reproduce the launcher's execution mode EXACTLY: -Command (no script file
# at all) running Invoke-Expression on the payload string.
#
# This fidelity is the entire value of the test. Run the payload as a file,
# or iex it from inside a file, and $MyInvocation.MyCommand.Path is populated
# and the bug vanishes. Only -Command + iex leaves it NULL, and that is the
# mode that shipped broken twice.
$probeSrc = @"
try {
    `$code = [IO.File]::ReadAllText('$payloadFile')
    Invoke-Expression `$code
    Write-Output 'REACHED_END'
} catch {
    `$e = `$_.Exception
    `$chain = @()
    while (`$e) { `$chain += (`$e.GetType().Name + ': ' + `$e.Message); `$e = `$e.InnerException }
    Write-Output ('FAILED::line ' + `$_.InvocationInfo.ScriptLineNumber + '::' + (`$chain -join ' <- '))
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeSrc))
$out = & $pwshPath -NoProfile -EncodedCommand $encoded 2>&1 | Out-String
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# Windows-only surfaces. Reaching one of these on a Mac is the expected
# stopping point -- System.Drawing.Common in particular is simply unavailable
# off Windows. Stopping ANYWHERE else is a bug that would also bite on Windows.
$windowsOnly = 'PlatformNotSupported|System\.Drawing|Windows\.Forms|NotifyIcon|SystemIcons|ContextMenuStrip'

if ($out -match 'REACHED_END') {
    Write-Host "  (payload ran to completion)"
} elseif ($out -match 'FAILED::(.+)') {
    $detail = $Matches[1].Trim()
    if ($detail -match $windowsOnly) {
        Write-Host "  (runs until the Windows-only graphics code, as expected off Windows)"
    } else {
        Write-Host "payload fails BEFORE the Windows-only code:"
        Write-Host ("  " + $detail)
        Write-Host "  (that failure would happen on Windows too)"
        exit 1
    }
} else {
    Write-Host "payload produced no recognisable result:"
    ($out -split "`n") | Select-Object -First 4 | ForEach-Object { Write-Host ("  " + $_.TrimEnd()) }
    exit 1
}

Write-Host "companion weld OK (payload extracts, parses, runs to the Windows-only tray code)"
exit 0
