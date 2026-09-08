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
$Version  = '0.4.0'
$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
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

function Find-WowRoots {
    $hints = @(
        'C:\World of Warcraft', 'C:\Games\World of Warcraft',
        'C:\Program Files (x86)\World of Warcraft',
        'C:\Program Files\World of Warcraft',
        (Join-Path $env:USERPROFILE 'World of Warcraft'),
        (Join-Path $env:USERPROFILE 'Desktop\World of Warcraft'),
        (Join-Path $env:USERPROFILE 'Games\World of Warcraft'),
        (Split-Path -Parent (Split-Path -Parent $Root))
    )
    $found = @()
    foreach ($h in $hints) {
        if ($h -and (Test-Path (Join-Path $h 'WTF\Account'))) { $found += $h }
    }
    if ($found.Count -eq 0) {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            foreach ($n in @('World of Warcraft', 'WoW', 'Wrath')) {
                $c = Join-Path $d.Root $n
                if (Test-Path (Join-Path $c 'WTF\Account')) { $found += $c }
            }
        }
    }
    return $found
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
        Write-Log "nothing to send (sharing off, or not logged out since enabling it)"
    } else {
        $merged = '[' + (($payloads | ForEach-Object { $_.Trim().TrimStart('[').TrimEnd(']') }) -join ',') + ']'
        $headers = @{}
        if ($cfg.Token) { $headers['X-LevelPace-Token'] = $cfg.Token }
        try {
            $res = Invoke-RestMethod -Uri ($cfg.Server.TrimEnd('/') + '/api/submit') -Method Post `
                -Body $merged -ContentType 'application/json' -Headers $headers `
                -UserAgent "LevelPaceCompanion/$Version" -TimeoutSec 30
            $sent = [int]$res.levels
            Write-Log ("uploaded {0} level(s), {1} rejected" -f $res.levels, $res.rejected)
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
        Write-Log "addon folder not found; skipped board"
        $script:LastStatus = if ($ok) { "sent $sent, addon not found" } else { "upload failed" }
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
    Invoke-Sync
    $icon.ShowBalloonTip(4000, 'LevelPace', $script:LastStatus,
        [System.Windows.Forms.ToolTipIcon]::Info)
})

$miBoard = $menu.Items.Add('Open the web board')
$miBoard.Add_Click({
    $cfg = Get-Config
    $url = if ($cfg.Baseline) { ($cfg.Baseline -replace '/api/baseline\.json$', '/') } else { $cfg.Server }
    Start-Process $url
})

$miLog = $menu.Items.Add('View log')
$miLog.Add_Click({
    if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath }
    else { [System.Windows.Forms.MessageBox]::Show('Nothing logged yet.', 'LevelPace') | Out-Null }
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
    Invoke-Sync
    $icon.ShowBalloonTip(4000, 'LevelPace', $script:LastStatus,
        [System.Windows.Forms.ToolTipIcon]::Info)
})

# --- watch the saved-variables files -----------------------------------------
#
# WoW writes these on logout or /reload. A FileSystemWatcher fires within
# milliseconds, so the upload happens while the player is still looking at the
# character screen. Debounced, because the client writes in more than one go.

$script:PendingAt = $null
$watchers = @()
foreach ($f in (Find-SavedVariables)) {
    $dir = Split-Path -Parent $f
    $w = New-Object IO.FileSystemWatcher $dir, 'LevelPace.lua'
    $w.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    $w.EnableRaisingEvents = $true
    Register-ObjectEvent $w Changed -Action { $script:PendingAt = Get-Date } | Out-Null
    $watchers += $w
    Write-Log "watching $f"
}
if ($watchers.Count -eq 0) {
    Write-Log "no LevelPace.lua found yet -- will keep looking"
}

# --- the pump ----------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
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
})
$timer.Start()

# One sync at startup so the board is current the moment it launches.
Invoke-Sync
$icon.ShowBalloonTip(5000, 'LevelPace is running',
    'It will upload by itself when you log out of WoW. Right-click the icon to quit.',
    [System.Windows.Forms.ToolTipIcon]::Info)

[System.Windows.Forms.Application]::Run()

foreach ($w in $watchers) { $w.EnableRaisingEvents = $false; $w.Dispose() }
$icon.Dispose()
Write-Log 'companion stopped'
