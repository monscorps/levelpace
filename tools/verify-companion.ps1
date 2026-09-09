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

param([Parameter(Mandatory = $true)][string] $Bat,
      [string] $Lua = '')

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
$tmp2 = Join-Path ([IO.Path]::GetTempPath()) ("lp-fn-" + [guid]::NewGuid().ToString("N"))
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
$env:LEVELPACE_OFFLINE = '1'
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

# 8. Call the functions the tray app calls at startup.
#
# Everything above stops at the first Windows-only line, so nothing after the
# tray icon was ever exercised -- and that is precisely where the app died:
# the startup Invoke-Sync threw AFTER the icon existed, so it appeared and
# vanished with no error anywhere.
#
# The functions are all defined before the Windows-only section, so they can
# be loaded and called here. This runs them in the worst honest case: no WoW
# installed, no addon, no network. Startup must survive all of it.
$fnPart = $payload.Substring(0, $payload.IndexOf('$icon = New-Object System.Windows.Forms.NotifyIcon'))
$fnFile = Join-Path $tmp2 'functions.ps1'
New-Item -ItemType Directory -Force -Path $tmp2 | Out-Null
[IO.File]::WriteAllText($fnFile, $fnPart)

$callSrc = @"
`$env:LEVELPACE_BAT = '$((Resolve-Path $Bat).Path)'
`$env:LOCALAPPDATA  = '$tmp2'
`$env:TEMP          = '$tmp2'
# Never touch the live server from a build. See Send-Hello.
`$env:LEVELPACE_OFFLINE = '1'
try {
    . '$fnFile'
} catch {
    Write-Output ('LOAD_FAILED::' + `$_.Exception.Message)
    exit
}
foreach (`$fn in @('Invoke-Sync','Find-WowRoots','Find-SavedVariables','Find-AddonDir','Get-Config')) {
    if (-not (Get-Command `$fn -ErrorAction SilentlyContinue)) {
        Write-Output ('MISSING::' + `$fn); continue
    }
    try { `$null = & `$fn } catch { Write-Output ('THREW::' + `$fn + '::' + `$_.Exception.Message) }
}
Write-Output 'FUNCS_OK'
"@
$callFile = Join-Path $tmp2 'call.ps1'
[IO.File]::WriteAllText($callFile, $callSrc)
$fnOut = & $pwshPath -NoProfile -File $callFile 2>&1 | Out-String
Remove-Item -Recurse -Force $tmp2 -ErrorAction SilentlyContinue

if ($fnOut -match 'LOAD_FAILED::(.+)') {
    Write-Host "the companion's functions do not even load:"
    Write-Host ("  " + $Matches[1].Trim()); exit 1
}
if ($fnOut -match 'MISSING::(\S+)') {
    Write-Host ("startup calls a function that does not exist: " + $Matches[1]); exit 1
}
if ($fnOut -match 'THREW::([^:]+)::(.+)') {
    # This is the whole point. A throw here kills the tray app AFTER its icon
    # is visible, which is indistinguishable from "it will not stay open".
    Write-Host ("{0} throws on a machine with no WoW, no addon and no network:" -f $Matches[1])
    Write-Host ("  " + $Matches[2].Trim())
    Write-Host "  That would kill the tray app at startup."
    exit 1
}
if ($fnOut -notmatch 'FUNCS_OK') {
    Write-Host "could not exercise the startup functions:"
    ($fnOut -split "`n") | Select-Object -First 4 | ForEach-Object { Write-Host ("  " + $_.TrimEnd()) }
    exit 1
}
Write-Host "  (startup functions survive a machine with no WoW, no addon, no network)"

# 9. The board the companion writes must be the board the addon reads.
#
# The Worker names its fields differently from the server this was first
# written against (name/metric/percentile, not display/parse/best). The
# mapping lives in Write-Board, and nothing but the game itself would notice
# it being wrong -- so feed it a Worker-shaped response here and read the
# result back with real Lua 5.1, the way the client will.
$tmp3 = Join-Path ([IO.Path]::GetTempPath()) ("lp-board-" + [guid]::NewGuid().ToString("N"))
$addonDir = Join-Path $tmp3 'addon'
New-Item -ItemType Directory -Force -Path $addonDir | Out-Null
$fnFile3 = Join-Path $tmp3 'functions.ps1'
[IO.File]::WriteAllText($fnFile3, $fnPart)

# Exactly what the live endpoints return today, including a population-of-one
# null percentile and a hidden realm.
[IO.File]::WriteAllText((Join-Path $tmp3 'lb.json'), @'
{"board":"levelling","scope":"overall","updated":1,"entries":[
 {"rank":1,"name":"Rickmyrolls","realm":"Icecrown","class":"DEATHKNIGHT","faction":"Horde","level":5,"metric":48.32,"percentile":null,"band":null,"levels":4},
 {"rank":2,"name":"Dan","realm":null,"class":"WARRIOR","faction":"Alliance","level":12,"metric":12.5,"percentile":75,"band":"purple","levels":11}]}
'@)
[IO.File]::WriteAllText((Join-Path $tmp3 'tw.json'), @'
{"board":"pvp","scope":"overall","updated":1,"entries":[
 {"rank":1,"name":"Ganker","realm":"Icecrown","class":"ROGUE","faction":"Horde","level":19,"metric":250,"percentile":null,"band":null,"levels":18}]}
'@)
[IO.File]::WriteAllText((Join-Path $tmp3 'base.json'), @'
{"schema":1,"fetched":1,"players":2,"overall":[48.32,12.5],"byLevel":{"1":[51.4286],"2":[102.8571,90.0]}}
'@)
[IO.File]::WriteAllText((Join-Path $tmp3 'ver.json'), @'
{"addonVersion":"9.9.9","downloadUrl":"https://example.test/dl","published":1}
'@)

$mapSrc = @"
`$env:LEVELPACE_BAT = '$((Resolve-Path $Bat).Path)'
`$env:LOCALAPPDATA  = '$tmp3'
`$env:TEMP          = '$tmp3'
`$env:LEVELPACE_OFFLINE = '1'
try { . '$fnFile3' } catch { Write-Output ('LOAD_FAILED::' + `$_.Exception.Message); exit }
try {
    `$j = { param(`$n) Get-Content -Raw (Join-Path '$tmp3' `$n) | ConvertFrom-Json }
    `$lb = & `$j 'lb.json'; `$tw = & `$j 'tw.json'; `$base = & `$j 'base.json'; `$ver = & `$j 'ver.json'
    Write-Board '$addonDir' `$lb.entries `$tw.entries `$ver 'https://api.example.test'
    Write-Baseline '$addonDir' `$base 'https://api.example.test'
    Write-Output 'MAP_OK'
} catch {
    Write-Output ('MAP_FAILED::' + `$_.Exception.Message + ' [at: ' + `$_.InvocationInfo.Line.Trim() + ']')
}
"@
$mapFile = Join-Path $tmp3 'map.ps1'
[IO.File]::WriteAllText($mapFile, $mapSrc)
$mapOut = & $pwshPath -NoProfile -File $mapFile 2>&1 | Out-String
if ($mapOut -match '(LOAD_FAILED|MAP_FAILED)::(.+)') {
    Write-Host "Write-Board / Write-Baseline fail on a Worker-shaped response:"
    Write-Host ("  " + $Matches[2].Trim())
    Remove-Item -Recurse -Force $tmp3 -ErrorAction SilentlyContinue
    exit 1
}
if ($mapOut -notmatch 'MAP_OK') {
    Write-Host "could not run the board mapping:"
    ($mapOut -split "`n") | Select-Object -First 4 | ForEach-Object { Write-Host ("  " + $_.TrimEnd()) }
    Remove-Item -Recurse -Force $tmp3 -ErrorAction SilentlyContinue
    exit 1
}

$boardLua = Join-Path $addonDir 'Board.lua'
$baseLua  = Join-Path $addonDir 'Baseline.lua'
$checkLua = Join-Path $tmp3 'check.lua'
[IO.File]::WriteAllText($checkLua, @'
local board, base = ...
dofile(board); dofile(base)
local B, S = LevelPaceBoard, LevelPaceBaseline
assert(type(B) == "table" and type(S) == "table", "globals defined")
local e = B.overall[1]
assert(e.name == "Rickmyrolls", "name comes from the Worker's 'name'")
assert(e.realm == "Icecrown" and e.level == 5 and e.class == "DEATHKNIGHT", "identity fields")
assert(e.metric == 48.32 and e.best == 48.32, "metric, and 'best' alias for the in-game board")
assert(e.percentile == nil and e.parse == nil and e.band == nil, "population of one stays nil, not 0")
assert(e.levels == 4, "levels count")
local d = B.overall[2]
assert(d.realm == nil, "hidden realm is nil")
assert(d.percentile == 75 and d.parse == 75 and d.band == "purple", "percentile, parse alias, band")
local t = B.twinks[1]
assert(t.name == "Ganker" and t.metric == 250 and t.kills == 250 and t.lifetime == 250, "pvp mapping")
assert(B.addonVersion == "9.9.9" and B.downloadUrl == "https://example.test/dl", "version.json passthrough")
assert(B.source == "https://api.example.test", "source")
assert(S.players == 2 and #S.overall == 2 and S.overall[1] == 48.32, "baseline overall")
assert(S.byLevel[1] and S.byLevel[1][1] == 51.4286, "byLevel keyed by number")
assert(S.byLevel[2] and #S.byLevel[2] == 2, "byLevel lists")
print("LUA_OK")
'@)

# Prefer a real Lua 5.1 (the one the tests use); fall back to a text check.
$luaBin = $Lua
if (-not $luaBin) {
    foreach ($c in @('luajit', 'lua5.1', 'lua51')) {
        $g = Get-Command $c -ErrorAction SilentlyContinue
        if ($g) { $luaBin = $g.Source; break }
    }
}
if ($luaBin) {
    $luaOut = & $luaBin $checkLua $boardLua $baseLua 2>&1 | Out-String
    if ($luaOut -notmatch 'LUA_OK') {
        Write-Host "the Board.lua / Baseline.lua the companion writes do not read back correctly in Lua:"
        ($luaOut -split "`n") | Select-Object -First 4 | ForEach-Object { Write-Host ("  " + $_.TrimEnd()) }
        Write-Host "  --- Board.lua ---"
        (Get-Content $boardLua) | Select-Object -First 12 | ForEach-Object { Write-Host ("  " + $_) }
        Remove-Item -Recurse -Force $tmp3 -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "  (Board.lua and Baseline.lua read back correctly in Lua 5.1)"
} else {
    $bt = Get-Content -Raw $boardLua
    foreach ($needle in @('name="Rickmyrolls"', 'metric=48.32', 'parse=nil', 'levels=4', 'band="purple"', 'addonVersion="9.9.9"')) {
        if (-not $bt.Contains($needle)) {
            Write-Host "Board.lua lacks '$needle' -- the field mapping is wrong"
            Remove-Item -Recurse -Force $tmp3 -ErrorAction SilentlyContinue
            exit 1
        }
    }
    Write-Host "  (no Lua 5.1 on this machine; Board.lua checked by text only)"
}
Remove-Item -Recurse -Force $tmp3 -ErrorAction SilentlyContinue

Write-Host "companion weld OK (payload extracts, parses, runs to the Windows-only tray code)"
exit 0
