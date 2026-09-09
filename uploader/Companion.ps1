<#
    LevelPace Companion — the tray app.

    Sits in the notification area, watches WoW's saved-variables file, and
    uploads the moment it changes. Right-click the icon to upload now, open
    the board, read the log, or quit.

    Needs NOTHING installed. Windows PowerShell 5.1 ships with Windows 10 and
    11, and the tray icon is plain Windows Forms.

    THE ONE LIMIT WORTH KNOWING: WoW writes its saved-variables file only on
    logout, /reload or disconnect. There is no API to make it write sooner --
    not from an addon, not from here. So "live" means "within a second or two
    of the game writing", not "while you are mid-fight". The addon tracks
    everything continuously in game regardless; this is only about getting it
    out.
#>

$ErrorActionPreference = 'Stop'
# Replaced by build.sh with the real release version. It was hardcoded and
# never bumped, so every log line said 0.4.0 no matter which build produced
# it -- which made a real user's log impossible to place against a release.
$Version  = '@@VERSION@@'
if ($Version -like '@@*') { $Version = 'dev' }
# $MyInvocation.MyCommand.Path is NULL when a script is run through
# Invoke-Expression -- which is exactly how the welded .bat runs this one.
# Combined with $ErrorActionPreference = 'Stop' set on the line above,
# `Split-Path -Parent $null` is a TERMINATING error, so the app died here, on
# line 4, before anything existed to show. The window flashed and closed and
# left nothing behind. The launcher exports the .bat path for this reason.
$Root = $null
if ($env:LEVELPACE_BAT) {
    $Root = Split-Path -Parent $env:LEVELPACE_BAT
} elseif ($MyInvocation.MyCommand.Path) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $Root) { $Root = (Get-Location).Path }
$LogPath  = Join-Path $env:LOCALAPPDATA 'LevelPace\companion.log'
$script:LastStatus = 'starting'

[void][Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
[void][Reflection.Assembly]::LoadWithPartialName('System.Drawing')

# TLS 1.2 is not the default on PowerShell 5.1 and https:// fails without it.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Run something that must never take the app down with it.
#
# This exists because it already did. $ErrorActionPreference is 'Stop', the
# startup sync was called bare, and one throw inside it killed the process
# AFTER the tray icon had appeared -- so the icon flashed up and vanished with
# no window, no error and nothing in the log. A tray app must survive every
# background failure it can possibly have; the worst acceptable outcome is a
# status line saying something went wrong.
function Invoke-Safe([scriptblock] $work, [string] $what) {
    try {
        & $work
    } catch {
        $msg = $_.Exception.Message
        try { Write-Log ("{0} failed: {1}" -f $what, $msg) } catch { }
        try { $script:LastStatus = "$what failed - see log" } catch { }
    }
}

function Write-Log([string]$msg) {
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
        # Keep it bounded; this runs for weeks at a time.
        if ((Get-Item $LogPath).Length -gt 512KB) {
            $keep = Get-Content $LogPath -Tail 2000
            Set-Content -LiteralPath $LogPath -Value $keep -Encoding UTF8
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Config — server.txt sits beside this file
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Enrolment
#
# The old build shipped ONE shared token inside everybody's download, so
# anyone who opened server.txt could submit as anyone. Instead, each install
# asks the server for its own key on first run. The server keeps only a hash
# of it, so a database dump contains nothing usable, and there is no master
# secret to leak.
#
# No account, no email, no signup. The player does nothing.
#
# The key is NOT recoverable. Losing it means this machine can no longer add
# to that character's history -- the history itself stays on the board.
# ---------------------------------------------------------------------------

function Get-KeyPath {
    $dir = Join-Path $env:LOCALAPPDATA 'LevelPace'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'install.key')
}

function Get-InstallKey($server) {
    if ($env:LEVELPACE_OFFLINE) { return $null }
    $path = Get-KeyPath
    if (Test-Path $path) {
        $k = (Get-Content $path -Raw).Trim()
        if ($k) { return $k }
    }
    try {
        $res = Invoke-RestMethod -Uri ($server.TrimEnd('/') + '/api/enrol') -Method Post `
                 -UserAgent "LevelPaceCompanion/$Version" -TimeoutSec 20
        if ($res.key) {
            Set-Content -Path $path -Value $res.key -NoNewline -Encoding ascii
            Write-Log "enrolled with the leaderboard; key stored in $path"
            return $res.key
        }
    } catch {
        Write-Log ("could not enrol: {0}" -f $_.Exception.Message)
    }
    return $null
}

function Get-Config {
    $vals = @()
    foreach ($dir in @($Root, (Split-Path -Parent $Root))) {
        $f = Join-Path $dir 'server.txt'
        if (Test-Path $f) {
            foreach ($line in (Get-Content $f)) {
                $t = $line.Trim()
                if ($t -and -not $t.StartsWith('#')) { $vals += $t }
            }
            if ($vals.Count) { break }
        }
    }
    $server = if ($vals.Count -ge 1) { $vals[0] } else { 'http://localhost:8080' }
    $token  = $null
    $base   = $null
    foreach ($v in $vals[1..([Math]::Max(1, $vals.Count - 1))]) {
        if ($v -match '^https?://') { if (-not $base) { $base = $v } }
        elseif (-not $token) { $token = $v }
    }

    # The upload address can move. A Cloudflare quick tunnel gets a new URL
    # every time it restarts, and re-sending everyone a new download each
    # time is obviously untenable -- so the CURRENT address is published
    # alongside the board, and looked up here.
    #
    # The baked-in server.txt value is the fallback, used when the lookup
    # fails or is not configured. That keeps a fixed address working exactly
    # as before.
    if ($base) {
        try {
            $cfgUrl = ($base -replace '/api/baseline\.json$', '') + '/api/config.json'
            $remote = Invoke-RestMethod -Uri $cfgUrl -TimeoutSec 12 `
                        -UserAgent "LevelPaceCompanion/$Version"
            if ($remote.uploadUrl -and $remote.uploadUrl -match '^https?://') {
                if ($remote.uploadUrl -ne $server) {
                    Write-Log ("upload address from config: {0}" -f $remote.uploadUrl)
                }
                $server = $remote.uploadUrl
            }
            if ($remote.token) { $token = $remote.token }
        } catch {
            # Offline, or no config published. Fall back to server.txt.
        }
    }

    return @{ Server = $server; Token = $token; Baseline = $base }
}

# ---------------------------------------------------------------------------
# Finding WoW
# ---------------------------------------------------------------------------

# Where the player told us WoW lives. No amount of guessing beats being told,
# and private-server installs live anywhere: C:\Warmane, D:\Games\Wrath,
# a folder named after whichever server they play on.
function Get-WowPathFile {
    return (Join-Path (Split-Path -Parent $LogPath) 'wowpath.txt')
}

function Get-SavedWowRoot {
    $f = Get-WowPathFile
    if (Test-Path $f) {
        $p = (Get-Content $f -Raw).Trim()
        if ($p -and (Test-Path (Join-Path $p 'WTF'))) { return $p }
    }
    return $null
}

function Set-SavedWowRoot([string] $path) {
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -Path (Get-WowPathFile) -Value $path -NoNewline -Encoding ascii
    Write-Log "WoW folder set to $path"
}

# Accept a near miss. People pick Interface, or Interface\AddOns, or the
# folder above the real one -- all of which are obvious enough to resolve
# rather than refuse.
function Resolve-WowRoot([string] $picked) {
    if ([string]::IsNullOrWhiteSpace($picked)) { return $null }

    # This is fed straight from a folder picker, so the input is whatever the
    # player clicked: a drive root, a UNC share, something that vanished
    # between picking and checking. Every path operation here can throw on one
    # of those, and $ErrorActionPreference is Stop -- so each one is guarded
    # individually rather than trusted.
    $test = {
        param($candidate)
        if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
        try { return (Test-Path (Join-Path $candidate 'WTF')) } catch { return $false }
    }

    $candidates = @($picked)

    $up = $picked
    for ($i = 0; $i -lt 2; $i++) {
        try { $up = Split-Path -Parent $up } catch { break }
        if ([string]::IsNullOrWhiteSpace($up)) { break }
        $candidates += $up
    }

    try { $candidates += (Join-Path $picked 'World of Warcraft') } catch { }

    foreach ($c in $candidates) {
        if (& $test $c) { return $c }
    }

    # Last try: one level down, for a "C:\Games" that CONTAINS the install.
    try {
        foreach ($d in (Get-ChildItem $picked -Directory -ErrorAction SilentlyContinue)) {
            if (& $test $d.FullName) { return $d.FullName }
        }
    } catch { }

    return $null
}

function Find-WowRoots {
    # A folder the player chose always wins.
    $saved = Get-SavedWowRoot
    if ($saved) { return @($saved) }

    # Every path expression here can produce null or empty, and Join-Path
    # THROWS on those rather than returning nothing. That is not theoretical:
    # unzip the companion at C:\LevelPace and
    # `Split-Path -Parent (Split-Path -Parent $Root)` is empty, which killed
    # the whole tray app at startup with no error anywhere.
    #
    # So the list is BUILT defensively rather than trusted.
    $names = @('World of Warcraft', 'WoW', 'Wrath', 'WoW 3.3.5a', 'WoW335',
               'Wrath of the Lich King', 'Warmane', 'WotLK')

    $bases = New-Object Collections.Generic.List[string]
    $add = {
        param($v)
        if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$bases.Add($v) }
    }
    foreach ($fixed in @('C:\', 'D:\', 'E:\', 'C:\Games', 'D:\Games',
                         'C:\Program Files (x86)', 'C:\Program Files')) {
        & $add $fixed
    }
    & $add $env:USERPROFILE
    foreach ($sub in @('Desktop', 'Downloads', 'Games')) {
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            try { & $add (Join-Path $env:USERPROFILE $sub) } catch { }
        }
    }
    # Where the companion itself was unzipped, and one level above.
    $up = $Root
    for ($i = 0; $i -lt 2; $i++) {
        if ([string]::IsNullOrWhiteSpace($up)) { break }
        & $add $up
        try { $up = Split-Path -Parent $up } catch { break }
    }

    $found = New-Object Collections.Generic.List[string]
    $isWow = {
        param($dir)
        if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
        try { return (Test-Path (Join-Path $dir 'WTF\Account')) } catch { return $false }
    }

    foreach ($b in $bases) {
        if (& $isWow $b) { [void]$found.Add($b); continue }
        foreach ($n in $names) {
            try {
                $c = Join-Path $b $n
                if (& $isWow $c) { [void]$found.Add($c) }
            } catch { }
        }
    }

    # Still nothing: one shallow sweep of each drive root. One level only --
    # walking whole disks on a timer is how an uploader becomes the reason
    # someone's machine is slow.
    if ($found.Count -eq 0) {
        try {
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                try {
                    foreach ($sub in (Get-ChildItem $d.Root -Directory -ErrorAction SilentlyContinue)) {
                        if (& $isWow $sub.FullName) { [void]$found.Add($sub.FullName) }
                    }
                } catch { }
            }
        } catch { }
    }
    if ($found.Count -eq 0) {
        # 'Could not find it' is only actionable if you can see where it
        # looked. Without this, the only move left is to guess.
        Write-Log "searched for WoW and found none. Looked in:"
        foreach ($b in ($bases | Select-Object -First 8)) { Write-Log "    $b" }
        Write-Log ("    (companion is running from: {0})" -f $Root)
        Write-Log "  A folder counts only if it contains WTF\Account."
    }
    return ($found | Select-Object -Unique)
}

function Find-SavedVariables {
    $out = @()
    foreach ($root in (Find-WowRoots)) {
        $acct = Join-Path $root 'WTF\Account'
        if (-not (Test-Path $acct)) { continue }
        Get-ChildItem $acct -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $f = Join-Path $_.FullName 'SavedVariables\LevelPace.lua'
            if (Test-Path $f) { $out += $f }
        }
    }
    return $out
}

function Find-AddonDir {
    foreach ($root in (Find-WowRoots)) {
        $d = Join-Path $root 'Interface\AddOns\LevelPace'
        if (Test-Path $d) { return $d }
    }
    return $null
}

# ---------------------------------------------------------------------------
# The payload
#
# The addon writes its export as a JSON string, so this only has to pull one
# value out with a regex -- no Lua parser needed. WoW escapes the string when
# it serialises, so the escapes have to be undone in one pass.
# ---------------------------------------------------------------------------

function Get-Payload([string]$path) {
    $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
    $m = [regex]::Match($text, '\["exportJSON"\]\s*=\s*"((?:[^"\\]|\\.)*)"',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { return $null }
    $raw = $m.Groups[1].Value
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $raw.Length; $i++) {
        $c = $raw[$i]
        if ($c -ne '\') { [void]$sb.Append($c); continue }
        $i++
        if ($i -ge $raw.Length) { break }
        switch ($raw[$i]) {
            '"'  { [void]$sb.Append('"') }
            '\'  { [void]$sb.Append('\') }
            'n'  { [void]$sb.Append("`n") }
            'r'  { [void]$sb.Append("`r") }
            't'  { [void]$sb.Append("`t") }
            default { [void]$sb.Append($raw[$i]) }
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Writing Lua back into the addon
# ---------------------------------------------------------------------------

$Inv = [Globalization.CultureInfo]::InvariantCulture

function LuaStr($s) {
    if ($null -eq $s) { return 'nil' }
    $t = ([string]$s) -replace '\\', '\\' -replace '"', '\"'
    $t = $t -replace "`r", '' -replace "`n", ' '
    return '"' + $t + '"'
}
function LuaNum($n) {
    if ($null -eq $n -or $n -eq '') { return 'nil' }
    # InvariantCulture or a comma-decimal Windows writes invalid Lua.
    return ([double]$n).ToString('0.####', $Inv)
}
function LuaList($seq, $cap) {
    if (-not $seq) { return '{}' }
    $a = @($seq)
    if ($a.Count -gt $cap) {
        $step = $a.Count / $cap
        $a = 0..($cap - 1) | ForEach-Object { $a[[int]($_ * $step)] }
    }
    return '{' + (($a | ForEach-Object { ([double]$_).ToString('F4', $Inv) }) -join ',') + '}'
}

function Save-Lua([string]$path, [string[]]$lines) {
    $tmp = "$path.tmp"
    # UTF-8 with NO BOM: the 3.3.5a Lua loader chokes on a BOM.
    [IO.File]::WriteAllText($tmp, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Write-Baseline($addonDir, $base, $source) {
    $l = New-Object Collections.Generic.List[string]
    $l.Add('-- LevelPace :: Baseline (generated by the companion). Do not edit.')
    $l.Add('LevelPaceBaseline = {')
    $l.Add(('  fetched = {0},' -f [int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds))
    $l.Add(('  source = {0},' -f (LuaStr $source)))
    $l.Add(('  players = {0},' -f [int]$base.players))
    $l.Add(('  overall = {0},' -f (LuaList $base.overall 2000)))
    $l.Add('  byLevel = {')
    if ($base.byLevel) {
        foreach ($p in $base.byLevel.PSObject.Properties | Sort-Object { [int]$_.Name }) {
            $l.Add(('    [{0}] = {1},' -f [int]$p.Name, (LuaList $p.Value 500)))
        }
    }
    $l.Add('  },'); $l.Add('}')
    Save-Lua (Join-Path $addonDir 'Baseline.lua') $l
}

function Write-Board($addonDir, $overall, $twinks, $version, $source) {
    $l = New-Object Collections.Generic.List[string]
    $l.Add('-- LevelPace :: Board (generated by the companion). Do not edit.')
    $l.Add('LevelPaceBoard = {')
    $l.Add(('  fetched = {0},' -f [int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds))
    $l.Add(('  source = {0},' -f (LuaStr $source)))
    if ($version) {
        $l.Add(('  addonVersion = {0},' -f (LuaStr $version.addonVersion)))
        $l.Add(('  downloadUrl = {0},' -f (LuaStr $version.downloadUrl)))
    }
    $l.Add('  overall = {')
    foreach ($e in @($overall) | Select-Object -First 100) {
        $l.Add('    { rank=' + (LuaNum $e.rank) + ', name=' + (LuaStr $e.display) +
               ', realm=' + (LuaStr $e.realm) + ', class=' + (LuaStr $e.class) +
               ', level=' + (LuaNum $e.level) + ', parse=' + (LuaNum $e.parse) +
               ', levels=' + (LuaNum $e.levels) + ', best=' + (LuaNum $e.best) + ' },')
    }
    $l.Add('  },')
    $l.Add('  twinks = {')
    foreach ($e in @($twinks) | Select-Object -First 100) {
        $nem = @()
        foreach ($n in @($e.nemesis) | Select-Object -First 3) {
            if ($n) { $nem += ('{ name=' + (LuaStr $n.name) + ', count=' + (LuaNum $n.count) + ' }') }
        }
        $l.Add('    { rank=' + (LuaNum $e.rank) + ', name=' + (LuaStr $e.display) +
               ', realm=' + (LuaStr $e.realm) + ', class=' + (LuaStr $e.class) +
               ', bracket=' + (LuaNum $e.bracket) + ', ilvl=' + (LuaNum $e.item_level) +
               ', weekly=' + (LuaNum $e.weekly_kills) + ', lifetime=' + (LuaNum $e.lifetime_kills) +
               ', deaths=' + (LuaNum $e.deaths) + ', kills=' + (LuaNum $e.kills) +
               ', bestStreak=' + (LuaNum $e.best_streak) + ', kd=' + (LuaNum $e.kd) +
               ', nemesis={' + ($nem -join ',') + '} },')
    }
    $l.Add('  },'); $l.Add('}')
    Save-Lua (Join-Path $addonDir 'Board.lua') $l
}

# ---------------------------------------------------------------------------
# One cycle: send what we have, bring back the board
# ---------------------------------------------------------------------------

# Report what we can and cannot see, whether or not there is anything to
# upload.
#
# Enrolment used to happen only inside the send path, so a companion that was
# running perfectly but had nothing to send never contacted the server at all.
# From the operator's side that is indistinguishable from never being
# installed -- and it cost two days of guessing at a client that was alive the
# whole time. Now it says so.
function Send-Hello($cfg, [bool]$wow, [bool]$addon, [bool]$blob, [string]$detail) {
    # The build gate runs these functions for real to prove they survive a
    # machine with no WoW and no addon -- which, the moment this function
    # existed, meant every build wrote a junk row into the PRODUCTION client
    # table and consumed enrolment rate limit. A test that mutates the live
    # system is worse than no test.
    if ($env:LEVELPACE_OFFLINE) { return }
    try {
        $key = Get-InstallKey $cfg.Server
        if (-not $key) { return }
        $body = @{
            version = $Version; wowFound = $wow; addonFound = $addon
            blobFound = $blob; detail = $detail
        } | ConvertTo-Json -Compress
        [void](Invoke-RestMethod -Uri ($cfg.Server.TrimEnd('/') + '/api/hello') `
                 -Method Post -Body $body -ContentType 'application/json' `
                 -Headers @{ Authorization = "Bearer $key" } `
                 -UserAgent "LevelPaceCompanion/$Version" -TimeoutSec 15)
    } catch {
        # Never fatal. This is diagnostics, not the job.
    }
}

function Invoke-Sync([switch]$Quiet) {
    $cfg = Get-Config
    $sent = 0
    $ok = $true

    # --- send ---
    $payloads = @()
    foreach ($f in (Find-SavedVariables)) {
        $p = Get-Payload $f
        if ($p) { $payloads += $p }
    }

    if ($payloads.Count -eq 0) {
        $roots = Find-WowRoots
        if ($roots.Count -eq 0) {
            Write-Log "Nothing to send: could not find your World of Warcraft folder."
            Write-Log "  Right-click the tray icon and choose 'Set WoW folder...'"
            Send-Hello $cfg $false $false $false 'no WoW folder found'
        } else {
            # The commonest case by far, and not an error: WoW writes its
            # saved variables ONLY on logout or /reload. A player who just
            # installed the addon has no file yet.
            Write-Log ("Nothing to send yet. Found WoW at {0}." -f $roots[0])
            Write-Log "  Log out of WoW once (or type /reload) and this will pick it up."
            Write-Log "  Also check sharing is on: minimap button, or /lp share on"
            # INSPECT the file rather than guessing. The old code said
            # 'sharing off' for any file that produced no payload, which is
            # three different situations wearing one label. Reading the file
            # tells them apart, and turns a stale heartbeat into a fact.
            $sv = @(Find-SavedVariables)
            $detail = 'no saved-variables file yet'
            $addonHere = $false
            if (Find-AddonDir) { $addonHere = $true }

            if ($sv.Count -gt 0) {
                $raw = ''
                try { $raw = Get-Content -Raw -LiteralPath $sv[0] -Encoding UTF8 } catch { }
                $hasExport = ($raw -match 'exportJSON')
                $shareOn   = ($raw -match '\["?enabled"?\]\s*=\s*true')

                if ($hasExport) {
                    # There IS a blob; the earlier Get-Payload just did not run
                    # against this file. Force a real read so it uploads.
                    $detail = 'blob present, re-reading'
                    Write-Log ("  ({0} contains a shared blob -- re-reading it now)" -f $sv[0])
                } elseif ($shareOn) {
                    $detail = 'sharing on, addon wrote no blob'
                    Write-Log "  (sharing looks ON in the file, but the addon wrote no blob."
                    Write-Log "   Update the ADDON zip too, then /reload.)"
                } else {
                    $detail = 'sharing off in the file'
                    Write-Log ("  ({0} exists but sharing is off in it. /lp share on, then /reload)" -f $sv[0])
                }
            } else {
                Write-Log "  (no LevelPace.lua yet -- the addon has not written one)"
            }
            Send-Hello $cfg $true $addonHere ($detail -eq 'blob present, re-reading') $detail
        }
    } else {
        $merged = '[' + (($payloads | ForEach-Object { $_.Trim().TrimStart('[').TrimEnd(']') }) -join ',') + ']'
        $headers = @{}
        $key = Get-InstallKey $cfg.Server
        if ($key) {
            $headers['Authorization'] = "Bearer $key"
        } elseif ($cfg.Token) {
            # No key yet (offline during enrolment, or an older server). The
            # legacy token still gets the data accepted, but the server
            # quarantines it: stored, never ranked, until the key arrives.
            $headers['X-LevelPace-Token'] = $cfg.Token
        }
        try {
            $res = Invoke-RestMethod -Uri ($cfg.Server.TrimEnd('/') + '/api/submit') -Method Post `
                -Body $merged -ContentType 'application/json' -Headers $headers `
                -UserAgent "LevelPaceCompanion/$Version" -TimeoutSec 30
            if ($res.quarantined) {
                Write-Log "accepted but NOT ranked -- this install has not enrolled yet"
                $sent = 0
            } elseif ($res.results) {
                $sent = 0
                foreach ($r in $res.results) {
                    if ($r.error) {
                        Write-Log ("{0}: {1}" -f $r.char, $r.error)
                    } else {
                        $sent += [int]$r.accepted.levels
                        Write-Log ("{0}: {1} level(s), {2} rare kill(s), {3} rejected" -f `
                            $r.char, $r.accepted.levels, $r.accepted.rares, $r.rejected)
                    }
                }
            } else {
                $sent = [int]$res.levels
                Write-Log ("uploaded {0} level(s), {1} rejected" -f $res.levels, $res.rejected)
            }
        } catch {
            $ok = $false
            Write-Log ("upload FAILED: {0}" -f $_.Exception.Message)
        }
    }

    # --- bring back the board ---
    # Deliberately independent of the upload: the board is served publicly, so
    # a failed send should still leave current rankings in game.
    $addon = Find-AddonDir
    if (-not $addon) {
        # Three very different situations used to share one message. Saying
        # which one it is turns a dead end into an instruction.
        $roots = Find-WowRoots
        if ($roots.Count -eq 0) {
            Write-Log "Could not find your World of Warcraft folder."
            Write-Log "  Right-click the tray icon and choose 'Set WoW folder...'"
            $script:LastStatus = "WoW folder not set - right-click me"
        } elseif (-not (Test-Path (Join-Path $roots[0] 'Interface\AddOns\LevelPace'))) {
            Write-Log ("Found WoW at {0}, but the LevelPace addon is not installed there." -f $roots[0])
            Write-Log "  Unzip LevelPace.zip into Interface\AddOns so you have"
            Write-Log "  Interface\AddOns\LevelPace\LevelPace.toc"
            $script:LastStatus = "addon not installed in that WoW folder"
        } else {
            Write-Log "addon folder not found; skipped board"
            $script:LastStatus = "addon not found"
        }
        return
    }

    try {
        $baseUri = if ($cfg.Baseline) { $cfg.Baseline } else { $cfg.Server.TrimEnd('/') + '/api/baseline' }
        $isStatic = $cfg.Baseline -and ($cfg.Baseline -match '\.json$')
        $root = if ($isStatic) { $cfg.Baseline -replace '/api/baseline\.json$', '' } else { $cfg.Server.TrimEnd('/') }

        $base = Invoke-RestMethod -Uri $baseUri -UserAgent "LevelPaceCompanion/$Version" -TimeoutSec 30
        Write-Baseline $addon $base $root

        $lb = Invoke-RestMethod -Uri ($(if ($isStatic) { "$root/api/leaderboard.json" } else { "$root/api/leaderboard" })) -TimeoutSec 30
        $tw = $null; $ver = $null
        try { $tw  = Invoke-RestMethod -Uri ($(if ($isStatic) { "$root/api/twinks.json" } else { "$root/api/twinks" })) -TimeoutSec 20 } catch { }
        try { $ver = Invoke-RestMethod -Uri ($(if ($isStatic) { "$root/api/version.json" } else { "$root/api/stats" })) -TimeoutSec 20 } catch { }

        Write-Board $addon $lb.entries ($(if ($tw) { $tw.entries } else { @() })) $ver $root
        Write-Log ("board updated: {0} ranked" -f @($lb.entries).Count)
        $script:LastStatus = "sent $sent, board updated $(Get-Date -Format 'HH:mm')"
    } catch {
        Write-Log ("board fetch failed: {0}" -f $_.Exception.Message)
        $script:LastStatus = "offline — retrying"
    }
}

# ---------------------------------------------------------------------------
# Tray
# ---------------------------------------------------------------------------

Write-Log "companion $Version starting"

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Text = 'LevelPace'          # 63 char limit; keep it short
$icon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miStatus = $menu.Items.Add('Starting...')
$miStatus.Enabled = $false
[void]$menu.Items.Add('-')

$miNow = $menu.Items.Add('Upload now')
$miNow.Add_Click({
    Invoke-Safe { Invoke-Sync } 'upload'
    $icon.ShowBalloonTip(4000, 'LevelPace', $script:LastStatus,
        [System.Windows.Forms.ToolTipIcon]::Info)
})

$miBoard = $menu.Items.Add('Open the web board')
$miBoard.Add_Click({
    $cfg = Get-Config
    $url = if ($cfg.Baseline) { ($cfg.Baseline -replace '/api/baseline\.json$', '/') } else { $cfg.Server }
    Start-Process $url
})

$miWow = $menu.Items.Add('Set WoW folder...')
$miWow.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select your World of Warcraft folder (the one containing Wow.exe)'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $resolved = Resolve-WowRoot $dlg.SelectedPath
        if ($resolved) {
            Set-SavedWowRoot $resolved
            [System.Windows.Forms.MessageBox]::Show(
                ("Using: {0}" -f $resolved), 'LevelPace') | Out-Null
            Invoke-Sync
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                ("That folder has no WTF directory, so it is not a WoW install:" +
                 "`r`n`r`n{0}`r`n`r`nPick the folder that contains Wow.exe." -f $dlg.SelectedPath),
                'LevelPace') | Out-Null
        }
    }
})

$miLog = $menu.Items.Add('View log')
$miLog.Add_Click({
    if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath }
    else { [System.Windows.Forms.MessageBox]::Show('Nothing logged yet.', 'LevelPace') | Out-Null }
})

# Sending the log back is the ONLY way anyone finds out why this failed on a
# machine none of us can see. "Open the folder under %LOCALAPPDATA% and attach
# the file" is three steps too many for someone doing you a favour, so both
# routes are one click.

$miCopyLog = $menu.Items.Add('Copy log (for Discord)')
$miCopyLog.Add_Click({
    if (-not (Test-Path $LogPath)) {
        [System.Windows.Forms.MessageBox]::Show('Nothing logged yet.', 'LevelPace') | Out-Null
        return
    }
    try {
        # Discord cuts a message off at 2000 characters, so send the tail --
        # which is where the failure is anyway -- rather than a truncated head
        # that stops before anything interesting happened.
        $lines = Get-Content $LogPath -Tail 60
        $text = ($lines -join "`r`n")
        if ($text.Length -gt 1800) { $text = $text.Substring($text.Length - 1800) }
        [System.Windows.Forms.Clipboard]::SetText("``````" + "`r`n" + $text + "`r`n" + "``````")
        [System.Windows.Forms.MessageBox]::Show(
            'Copied the last 60 lines. Paste it into Discord with Ctrl+V.',
            'LevelPace') | Out-Null
    } catch {
        # Clipboard access needs an STA thread. The launcher asks for one, but
        # if someone runs this script another way it can fail -- so point at
        # the route that always works rather than leaving them stuck.
        [System.Windows.Forms.MessageBox]::Show(
            ('Could not copy to the clipboard ({0}).' -f $_.Exception.Message) +
            "`r`n`r`n" + 'Use "Show log file (to attach)" instead and drag the file.',
            'LevelPace') | Out-Null
    }
})

$miShowLog = $menu.Items.Add('Show log file (to attach)')
$miShowLog.Add_Click({
    if (Test-Path $LogPath) {
        # /select opens the folder with the file already highlighted, ready to
        # drag into Discord. Better than a paste for a long log.
        Start-Process explorer.exe ("/select," + $LogPath)
    } else {
        [System.Windows.Forms.MessageBox]::Show('Nothing logged yet.', 'LevelPace') | Out-Null
    }
})

[void]$menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit LevelPace')
$miQuit.Add_Click({
    Write-Log 'quit from tray menu'
    $icon.Visible = $false
    $icon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$icon.ContextMenuStrip = $menu
$icon.Add_MouseDoubleClick({
    Invoke-Safe { Invoke-Sync } 'upload'
    $icon.ShowBalloonTip(4000, 'LevelPace', $script:LastStatus,
        [System.Windows.Forms.ToolTipIcon]::Info)
})

# --- watch the saved-variables files -----------------------------------------
#
# WoW writes these on logout or /reload. A FileSystemWatcher fires within
# milliseconds, so the upload happens while the player is still looking at the
# character screen. Debounced, because the client writes in more than one go.

$script:PendingAt = $null

# $script: on purpose, and it matters. These lines run inside an Invoke-Safe
# scriptblock, which PowerShell executes in a CHILD scope -- so a bare
# `$watchers += $w` reads the parent's value and then creates a local copy.
# The parent's array stayed empty, the watcher objects were collected, and
# nothing was ever watched. Everything looked fine; no upload ever happened.
$script:watchers   = @()
$script:watchedDirs = @{}

# Re-scan, rather than looking once at startup and calling it a day.
#
# The saved-variables file does not exist until the player has logged out or
# reloaded WITH sharing switched on -- which is almost always after they
# started this program. Scanning only at launch meant the normal sequence of
# events guaranteed the file was never found, while the log cheerfully said
# "will keep looking" and then did not.
function Update-Watchers {
    $added = 0
    foreach ($f in (Find-SavedVariables)) {
        $dir = Split-Path -Parent $f
        if ($script:watchedDirs.ContainsKey($dir)) { continue }
        try {
            $w = New-Object IO.FileSystemWatcher $dir, 'LevelPace.lua'
            $w.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
            $w.EnableRaisingEvents = $true
            Register-ObjectEvent $w Changed -Action { $script:PendingAt = Get-Date } | Out-Null
            $script:watchers += $w
            $script:watchedDirs[$dir] = $true
            $added++
            Write-Log "watching $f"
        } catch {
            Write-Log ("could not watch {0}: {1}" -f $dir, $_.Exception.Message)
        }
    }
    return $added
}

Invoke-Safe { [void](Update-Watchers) } 'file watcher setup'
if ($script:watchers.Count -eq 0) {
    Write-Log "no LevelPace.lua yet -- rechecking every minute"
    Write-Log "  (it appears the first time you log out or /reload with sharing on)"
}

# --- the pump ----------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$script:Ticks = 0
$script:LastSweep = Get-Date

$timer.Add_Tick({
  Invoke-Safe {
    $script:Ticks++

    # Every twelve ticks (~60s): look for saved-variables files that did not
    # exist when this started.
    if ($script:Ticks % 12 -eq 0) { [void](Update-Watchers) }

    # And sync on a slow schedule regardless of whether any watcher is
    # working. Watching is an optimisation -- it makes the upload happen
    # seconds after logout instead of minutes. If it silently fails, as it
    # just did, the data should still arrive rather than never.
    if (((Get-Date) - $script:LastSweep).TotalMinutes -ge 5) {
        $script:LastSweep = Get-Date
        Invoke-Sync -Quiet
    }

    # Debounce: wait for the file to settle before reading it.
    if ($script:PendingAt -and ((Get-Date) - $script:PendingAt).TotalSeconds -ge 3) {
        $script:PendingAt = $null
        Write-Log 'saved variables changed -- syncing'
        Invoke-Sync
        $icon.ShowBalloonTip(4000, 'LevelPace', $script:LastStatus,
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
    $miStatus.Text = $script:LastStatus
    # Tooltip is capped at 63 characters or it silently fails to set.
    $t = "LevelPace - $($script:LastStatus)"
    if ($t.Length -gt 62) { $t = $t.Substring(0, 62) }
    $icon.Text = $t
  } 'timer tick'
})
$timer.Start()

# One sync at startup so the board is current the moment it launches.
#
# Guarded, because this line used to kill the app. It runs network calls, file
# scans and a drive sweep, any of which can fail on a machine we have never
# seen -- and failing here, after the icon exists but before the message loop
# starts, looks exactly like "it will not stay open".
Invoke-Safe { Invoke-Sync } 'startup sync'

Invoke-Safe {
    $icon.ShowBalloonTip(5000, 'LevelPace is running',
        'It will upload by itself when you log out of WoW. Right-click the icon to quit.',
        [System.Windows.Forms.ToolTipIcon]::Info)
} 'startup notification'

[System.Windows.Forms.Application]::Run()

foreach ($w in $watchers) { $w.EnableRaisingEvents = $false; $w.Dispose() }
$icon.Dispose()
Write-Log 'companion stopped'
