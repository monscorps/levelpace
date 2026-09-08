<#
    LevelPace uploader (PowerShell)

    Needs NOTHING installed. Windows PowerShell 5.1 ships with Windows 10 and
    11, so a player can send their stats without installing Python or anything
    else. That matters: asking a random WoW player to install a runtime is
    where adoption dies.

    It works because the addon writes its payload as a JSON string, not just a
    Lua table -- so this only has to pull one string out with a regex rather
    than implement a Lua parser in PowerShell.

    Usage (normally via run-uploader.bat, which handles execution policy):

        .\LevelPaceUpload.ps1 -Server http://example.com:8080
        .\LevelPaceUpload.ps1 -DryRun
        .\LevelPaceUpload.ps1 -Watch

    Nothing is sent unless sharing is enabled IN THE ADDON. With it off the
    addon writes no payload and this finds nothing to send.
#>

[CmdletBinding()]
param(
    [string]$Server,
    # Where to READ the global baseline from. Defaults to the upload server,
    # but pointing it at a GitHub Pages URL means the baseline still arrives
    # when the upload server is off -- Pages is static and always up.
    [string]$BaselineUrl,
    # Shared submission secret, if the board requires one. Normally read from
    # the second line of server.txt rather than typed.
    [string]$Token,
    [string]$WowPath,
    [string]$File,
    [string]$AddonPath,
    [switch]$DryRun,
    [switch]$NoBaseline,
    [switch]$Watch,
    [int]$IntervalSeconds = 60,
    [string]$Forget
)

$ErrorActionPreference = 'Stop'
$Version = '0.2.0'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# TLS 1.2 is not the default on Windows PowerShell 5.1, and https:// fails
# without it against most modern hosts.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# server.txt holds the address on the first non-comment line, and optionally
# a submission token on the second. One file to edit before handing the folder
# out; the recipient never touches it.
function Get-ConfiguredLines {
    foreach ($dir in @($Root, (Split-Path -Parent $Root))) {
        $f = Join-Path $dir 'server.txt'
        if (Test-Path $f) {
            $vals = @()
            foreach ($line in (Get-Content $f)) {
                $t = $line.Trim()
                if ($t -and -not $t.StartsWith('#')) { $vals += $t }
            }
            if ($vals.Count) { return $vals }
        }
    }
    return @()
}

function Get-ConfiguredServer {
    $v = Get-ConfiguredLines
    if ($v.Count -ge 1) { return $v[0] }
    return 'http://localhost:8080'
}

function Get-ConfiguredToken {
    $v = Get-ConfiguredLines
    # A URL on line 2 means the token was omitted, not that the token is a URL.
    if ($v.Count -ge 2 -and $v[1] -notmatch '^https?://') { return $v[1] }
    return $null
}

# Where to READ the board from. This needs no server of your own: GitHub Pages
# serves it publicly, so /lp board works in game even when nothing is hosted.
function Get-ConfiguredBaseline {
    $v = Get-ConfiguredLines
    foreach ($line in $v[1..([Math]::Max(1, $v.Count - 1))]) {
        if ($line -match '^https?://') { return $line }
    }
    return $null
}

function Find-WowRoots {
    if ($WowPath) { return @($WowPath) }
    $hints = @(
        'C:\World of Warcraft', 'C:\Games\World of Warcraft',
        'C:\Program Files (x86)\World of Warcraft',
        'C:\Program Files\World of Warcraft',
        (Join-Path $env:USERPROFILE 'World of Warcraft'),
        (Join-Path $env:USERPROFILE 'Desktop\World of Warcraft'),
        (Join-Path $env:USERPROFILE 'Games\World of Warcraft')
    )
    $found = @()
    foreach ($h in $hints) {
        if ($h -and (Test-Path (Join-Path $h 'WTF\Account'))) { $found += $h }
    }
    # Last resort: any drive root with a WoW-looking folder. Cheap enough,
    # and it saves the player hunting for a path.
    if ($found.Count -eq 0) {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $cand = Join-Path $d.Root 'World of Warcraft'
            if (Test-Path (Join-Path $cand 'WTF\Account')) { $found += $cand }
        }
    }
    return $found
}

function Find-SavedVariables {
    if ($File) { return @($File) }
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
    if ($AddonPath) { return $AddonPath }
    foreach ($root in (Find-WowRoots)) {
        $d = Join-Path $root 'Interface\AddOns\LevelPace'
        if (Test-Path $d) { return $d }
    }
    return $null
}

<#
    Pull the JSON payload out of the SavedVariables file.

    WoW writes Lua string literals, so our JSON arrives double-escaped: a
    quote inside the JSON is written as \" and a backslash as \\. Undo exactly
    those, in one pass, so a literal \\" in the file does not turn into an
    unbalanced quote.
#>
function Get-PayloadFromFile([string]$path) {
    $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
    $m = [regex]::Match($text,
        '\["exportJSON"\]\s*=\s*"((?:[^"\\]|\\.)*)"',
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

function Write-Baseline([string]$addonDir, $baseline, [string]$source) {
    # Numbers MUST be formatted with InvariantCulture. '{0:F4}' uses the
    # machine's locale, so on a German or French Windows it emits "1,2345"
    # with a comma -- which is not a Lua number, and Baseline.lua would fail
    # to load with a syntax error the player could never diagnose.
    $inv = [Globalization.CultureInfo]::InvariantCulture

    function Fmt($seq, $cap) {
        if (-not $seq) { return '{}' }
        $a = @($seq)
        if ($a.Count -gt $cap) {
            $step = $a.Count / $cap
            $a = 0..($cap - 1) | ForEach-Object { $a[[int]($_ * $step)] }
        }
        return '{' + (($a | ForEach-Object {
            ([double]$_).ToString('F4', $inv)
        }) -join ',') + '}'
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('-- LevelPace :: Baseline (generated)')
    $lines.Add('--')
    $lines.Add('-- WRITTEN BY THE LEVELPACE UPLOADER. Do not hand-edit; it is overwritten.')
    $lines.Add(('-- Fetched {0} from {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $source))
    $lines.Add('')
    $lines.Add('LevelPaceBaseline = {')
    # Not Get-Date -UFormat %s: it returns a locale-formatted decimal string
    # on Windows PowerShell 5.1, which parses wrong wherever the decimal
    # separator is a comma. Subtracting two dates is locale-proof.
    $epoch = [int]((Get-Date).ToUniversalTime() -
                   (Get-Date '1970-01-01 00:00:00')).TotalSeconds
    $lines.Add(('  fetched = {0},' -f $epoch))
    $lines.Add(('  source = "{0}",' -f ($source -replace '"', '\"')))
    $lines.Add(('  players = {0},' -f [int]$baseline.players))
    $lines.Add(('  overall = {0},' -f (Fmt $baseline.overall 2000)))
    $lines.Add('  byLevel = {')
    if ($baseline.byLevel) {
        foreach ($p in $baseline.byLevel.PSObject.Properties | Sort-Object { [int]$_.Name }) {
            $lines.Add(('    [{0}] = {1},' -f [int]$p.Name, (Fmt $p.Value 500)))
        }
    }
    $lines.Add('  },')
    $lines.Add('}')
    $lines.Add('')

    $target = Join-Path $addonDir 'Baseline.lua'
    $tmp = "$target.tmp"
    # Write UTF-8 WITHOUT a BOM: the 3.3.5a Lua loader chokes on a BOM.
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tmp, ($lines -join "`r`n"), $enc)
    Move-Item -LiteralPath $tmp -Destination $target -Force
    return $target
}

<#
    Write the rankings into the addon folder as Lua, so the board can be read
    in game without opening a browser. Same mechanism as Baseline.lua: the
    addon cannot fetch, so we fetch and it loads the file on next /reload.
#>
function Write-Board([string]$addonDir, $overall, $twinks, [string]$source, $version) {
    $inv = [Globalization.CultureInfo]::InvariantCulture

    function LuaStr($s) {
        if ($null -eq $s) { return 'nil' }
        # Escape backslash first, then quote, or the escapes escape each other.
        $t = ([string]$s) -replace '\\', '\\' -replace '"', '\"'
        $t = $t -replace "`r", '' -replace "`n", ' '
        return '"' + $t + '"'
    }
    function LuaNum($n) {
        if ($null -eq $n -or $n -eq '') { return 'nil' }
        return ([double]$n).ToString('0.####', $inv)
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('-- LevelPace :: Board (generated)')
    $lines.Add('--')
    $lines.Add('-- WRITTEN BY THE LEVELPACE UPLOADER. Do not hand-edit.')
    $lines.Add(('-- Fetched {0} from {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $source))
    $lines.Add('')
    $epoch = [int]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01 00:00:00')).TotalSeconds
    $lines.Add('LevelPaceBoard = {')
    $lines.Add(('  fetched = {0},' -f $epoch))
    $lines.Add(('  source = {0},' -f (LuaStr $source)))
    if ($version) {
        # The addon has no way to check for updates itself, so the version it
        # should be on rides along with the board.
        $lines.Add(('  addonVersion = {0},' -f (LuaStr $version.addonVersion)))
        $lines.Add(('  downloadUrl = {0},' -f (LuaStr $version.downloadUrl)))
    }

    $lines.Add('  overall = {')
    foreach ($e in @($overall) | Select-Object -First 100) {
        $lines.Add(('    { rank=%RANK%, name=%NAME%, realm=%REALM%, class=%CLASS%, level=%LVL%, parse=%PARSE%, levels=%N%, best=%BEST% },' `
            -replace '%RANK%', (LuaNum $e.rank) -replace '%NAME%', (LuaStr $e.display) `
            -replace '%REALM%', (LuaStr $e.realm) -replace '%CLASS%', (LuaStr $e.class) `
            -replace '%LVL%', (LuaNum $e.level) -replace '%PARSE%', (LuaNum $e.parse) `
            -replace '%N%', (LuaNum $e.levels) -replace '%BEST%', (LuaNum $e.best)))
    }
    $lines.Add('  },')

    $lines.Add('  twinks = {')
    foreach ($e in @($twinks) | Select-Object -First 100) {
        $nem = @()
        foreach ($n in @($e.nemesis) | Select-Object -First 3) {
            if ($n) { $nem += ('{ name=' + (LuaStr $n.name) + ', count=' + (LuaNum $n.count) + ' }') }
        }
        $lines.Add(('    { rank=%RANK%, name=%NAME%, realm=%REALM%, class=%CLASS%, bracket=%BR%, ilvl=%ILVL%, weekly=%WK%, lifetime=%LT%, deaths=%D%, kd=%KD%, nemesis={%NEM%} },' `
            -replace '%RANK%', (LuaNum $e.rank) -replace '%NAME%', (LuaStr $e.display) `
            -replace '%REALM%', (LuaStr $e.realm) -replace '%CLASS%', (LuaStr $e.class) `
            -replace '%BR%', (LuaNum $e.bracket) -replace '%ILVL%', (LuaNum $e.item_level) `
            -replace '%WK%', (LuaNum $e.weekly_kills) -replace '%LT%', (LuaNum $e.lifetime_kills) `
            -replace '%D%', (LuaNum $e.deaths) -replace '%KD%', (LuaNum $e.kd) `
            -replace '%NEM%', ($nem -join ',')))
    }
    $lines.Add('  },')
    $lines.Add('}')
    $lines.Add('')

    $target = Join-Path $addonDir 'Board.lua'
    $tmp = "$target.tmp"
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tmp, ($lines -join "`r`n"), $enc)
    Move-Item -LiteralPath $tmp -Destination $target -Force
    return $target
}

function Invoke-Once {
    $files = Find-SavedVariables
    if (-not $files -or $files.Count -eq 0) {
        Write-Host ''
        Write-Host '  Could not find LevelPace.lua.' -ForegroundColor Yellow
        Write-Host '  Point at your WoW folder with  -WowPath "C:\path\to\World of Warcraft"'
        Write-Host ''
        return 1
    }

    $payloads = @()
    foreach ($f in $files) {
        $p = Get-PayloadFromFile $f
        if ($p) {
            Write-Host ("  found: {0}" -f $f) -ForegroundColor DarkGray
            $payloads += $p
        } else {
            Write-Host ("  no shared data in {0}" -f (Split-Path -Leaf $f)) -ForegroundColor DarkGray
        }
    }

    if ($payloads.Count -eq 0) {
        Write-Host ''
        Write-Host '  Nothing to upload.' -ForegroundColor Yellow
        Write-Host '  Either sharing is off in the addon, or you have not logged out'
        Write-Host '  since you switched it on. WoW only writes the file on logout'
        Write-Host '  or /reload -- never while you are playing.'
        Write-Host ''
    }
    elseif ($DryRun) {
        Write-Host ''
        Write-Host '  DRY RUN -- this is exactly what would be sent, and nothing was:' -ForegroundColor Cyan
        Write-Host ''
        foreach ($p in $payloads) {
            if ($p.Length -gt 4000) { Write-Host ($p.Substring(0, 4000) + ' ...(truncated)') }
            else { Write-Host $p }
        }
        Write-Host ''
    }
    else {
        # Each payload is already a JSON array of characters; merge them.
        $merged = '[' + (($payloads | ForEach-Object { $_.Trim().TrimStart('[').TrimEnd(']') }) -join ',') + ']'
        $headers = @{}
        if ($Token) { $headers['X-LevelPace-Token'] = $Token }
        try {
            $res = Invoke-RestMethod -Uri ($Server.TrimEnd('/') + '/api/submit') `
                -Method Post -Body $merged -ContentType 'application/json' `
                -Headers $headers `
                -UserAgent "LevelPaceUploader/$Version" -TimeoutSec 30
            Write-Host ("  uploaded: {0} level(s) accepted, {1} rejected" -f $res.levels, $res.rejected) -ForegroundColor Green
            foreach ($e in $res.errors) { Write-Host ("  ! server: {0}" -f $e) -ForegroundColor Red }
        } catch {
            # Deliberately NOT a hard exit. Reading the board and sending
            # stats are independent: the board comes from GitHub Pages, which
            # is up regardless. A failed upload should still leave you with
            # current rankings in game.
            Write-Host ("  ! upload failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "    (carrying on -- the board below is fetched separately)" -ForegroundColor DarkGray
        }
    }

    if ($NoBaseline) { return 0 }
    $addon = Find-AddonDir
    if (-not $addon) {
        Write-Host '  ! addon folder not found; skipping baseline (use -AddonPath)' -ForegroundColor DarkGray
        return 0
    }
    # A Pages URL serves a flat file, so the path ends .json; a live server
    # answers the API path.
    $baseUri = if ($BaselineUrl) { $BaselineUrl } else { $Server.TrimEnd('/') + '/api/baseline' }
    try {
        $base = Invoke-RestMethod -Uri $baseUri `
            -UserAgent "LevelPaceUploader/$Version" -TimeoutSec 30
        $out = Write-Baseline $addon $base $Server
        Write-Host ("  baseline written: {0} ({1} players)" -f $out, $base.players) -ForegroundColor Green
    } catch {
        Write-Host ("  ! baseline fetch failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
    }

    # The rankings themselves, so the board can be read in game.
    try {
        $root = if ($BaselineUrl) { ($BaselineUrl -replace '/api/baseline\.json$', '') } else { $Server.TrimEnd('/') }
        $isStatic = $BaselineUrl -and ($BaselineUrl -match '\.json$')
        $lbUrl = if ($isStatic) { "$root/api/leaderboard.json" } else { "$root/api/leaderboard" }
        $twUrl = if ($isStatic) { "$root/api/twinks.json" }      else { "$root/api/twinks" }

        $lb = Invoke-RestMethod -Uri $lbUrl -UserAgent "LevelPaceUploader/$Version" -TimeoutSec 30
        $tw = $null
        try { $tw = Invoke-RestMethod -Uri $twUrl -UserAgent "LevelPaceUploader/$Version" -TimeoutSec 30 } catch { }

        $ver = $null
        $verUrl = if ($isStatic) { "$root/api/version.json" } else { "$root/api/stats" }
        try { $ver = Invoke-RestMethod -Uri $verUrl -UserAgent "LevelPaceUploader/$Version" -TimeoutSec 15 } catch { }

        $out = Write-Board $addon $lb.entries ($(if ($tw) { $tw.entries } else { @() })) $root $ver
        Write-Host ("  board written: {0} ({1} ranked)" -f $out, @($lb.entries).Count) -ForegroundColor Green
        if ($ver -and $ver.addonVersion) {
            Write-Host ("  current addon version: {0}" -f $ver.addonVersion) -ForegroundColor DarkGray
        }
    } catch {
        Write-Host ("  ! board fetch failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
    }

    Write-Host '  /reload in game, then /lp board'
    return 0
}

# ---- main -------------------------------------------------------------------

if (-not $Server)      { $Server      = Get-ConfiguredServer }
if (-not $Token)       { $Token       = Get-ConfiguredToken }
if (-not $BaselineUrl) { $BaselineUrl = Get-ConfiguredBaseline }

if ($Forget) {
    try {
        $r = Invoke-RestMethod -Uri ($Server.TrimEnd('/') + '/api/forget') -Method Post `
            -Body (@{ id = $Forget } | ConvertTo-Json) -ContentType 'application/json'
        Write-Host ("deleted: {0}" -f $r.deleted)
        exit 0
    } catch {
        Write-Host ("failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 2
    }
}

Write-Host ''
Write-Host '  LevelPace uploader' -ForegroundColor Cyan
Write-Host ("  server: {0}" -f $Server) -ForegroundColor DarkGray
Write-Host ''

if (-not $Watch) { exit (Invoke-Once) }

Write-Host '  Watching for changes. Ctrl-C to stop.'
Write-Host '  (WoW writes the file on logout or /reload, so nothing changes mid-session.)'
$seen = @{}
while ($true) {
    $changed = $false
    foreach ($f in (Find-SavedVariables)) {
        try { $m = (Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks } catch { continue }
        if ($seen[$f] -ne $m) { $seen[$f] = $m; $changed = $true }
    }
    if ($changed) {
        Write-Host ''
        Write-Host ("[{0}] change detected" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
        [void](Invoke-Once)
    }
    Start-Sleep -Seconds ([Math]::Max(5, $IntervalSeconds))
}
