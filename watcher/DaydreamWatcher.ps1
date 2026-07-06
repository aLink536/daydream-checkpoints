# =====================================================================
# Daydream Checkpoints — companion watcher
#
# Out-of-game half of the system. Polls Zomboid\Lua\ for JSON request
# files written by the DaydreamCheckpoints mod, performs the file work
# the Lua sandbox can't (snapshot / restore the save folder), and
# answers through an ack file the mod polls.
#
# Run it in a console window while playing (or via the launcher batch,
# or auto-started hidden by the Daydream dinput8 proxy with -FollowGame).
# Ctrl+C to stop. Windows PowerShell 5.1 compatible.
# =====================================================================

param(
    # Exit automatically once the game process disappears (used when the
    # proxy DLL starts us hidden, so watchers don't pile up across runs).
    [switch]$FollowGame
)

$ErrorActionPreference = "Stop"

# single instance: a second watcher would race this one on request files
$script:instanceMutex = New-Object System.Threading.Mutex($false, "DaydreamWatcherSingleton")
if (-not $script:instanceMutex.WaitOne(0)) {
    Write-Host "Another Daydream watcher is already running - exiting."
    exit 0
}

# ---- paths & tunables ------------------------------------------------
$ZomboidDir    = Join-Path $env:USERPROFILE "Zomboid"
$LuaDir        = Join-Path $ZomboidDir "Lua"
$RequestFile   = Join-Path $LuaDir "daydream_request.json"
$AckFile       = Join-Path $LuaDir "daydream_ack.json"
$MenuMarker    = Join-Path $LuaDir "daydream_menu.txt"
$BackupRoot    = Join-Path $ZomboidDir "DaydreamCheckpoints"
$LogFile       = Join-Path $BackupRoot "watcher.log"
$KeepPerWorld  = 10      # newest checkpoints kept per world
$PollMs        = 500
$UnloadWaitSec = 180     # max seconds to wait for the game to unload the save

# ---- helpers ---------------------------------------------------------
function Write-Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Write-Ack([string]$id, [bool]$ok, [string]$action, [string]$message) {
    $obj = @{ id = $id; ok = $ok; action = $action; message = $message }
    $json = ($obj.GetEnumerator() | ForEach-Object { '"{0}":{1}' -f $_.Key, $(
        if ($_.Value -is [bool]) { $_.Value.ToString().ToLower() }
        else { '"' + ($_.Value -replace '\\','\\' -replace '"','\"') + '"' }
    ) }) -join ","
    # UTF-8 without BOM so the game's Lua reader sees clean text
    [System.IO.File]::WriteAllText($AckFile, "{" + $json + "}", (New-Object System.Text.UTF8Encoding($false)))
}

# Folder names may not contain characters Windows dislikes.
function Sanitize-Name([string]$name) {
    return ($name -replace '[\\/:*?"<>|]', '_').Trim()
}

function Invoke-Backup($req) {
    $mode  = Sanitize-Name $req.gameMode
    $world = Sanitize-Name $req.worldName
    $label = Sanitize-Name $req.label

    $source = Join-Path (Join-Path (Join-Path $ZomboidDir "Saves") $mode) $world
    if (-not (Test-Path $source)) {
        throw "save folder not found: $source"
    }

    $worldKey = "{0}_{1}" -f $mode, $world
    $stamp = "{0:yyyyMMdd_HHmmss}" -f (Get-Date)
    if ($label -ne "") { $stamp = "$stamp`_$label" }
    $dest = Join-Path (Join-Path $BackupRoot $worldKey) $stamp

    Write-Log "backup: '$source' -> '$dest'"
    $null = robocopy $source $dest /E /R:2 /W:1 /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }

    # prune old checkpoints for this world
    $worldDir = Join-Path $BackupRoot $worldKey
    $old = Get-ChildItem $worldDir -Directory | Sort-Object Name -Descending | Select-Object -Skip $KeepPerWorld
    foreach ($dir in $old) {
        Write-Log "prune: $($dir.FullName)"
        Remove-Item $dir.FullName -Recurse -Force -Confirm:$false
    }

    return "checkpoint stored ($stamp)"
}

# The save may only be swapped while the game isn't holding it. Two
# signals must agree: the mod's menu heartbeat is fresh (the game is
# sitting at the main menu), and a directory rename round-trip succeeds
# (Windows refuses to rename a folder any process has files open in).
function Wait-SaveUnloaded([string]$saveDir, [datetime]$since) {
    $deadline = (Get-Date).AddSeconds($UnloadWaitSec)
    $parent = Split-Path $saveDir -Parent
    $probe = Join-Path $parent ((Split-Path $saveDir -Leaf) + "__daydream_probe")

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1000

        if (-not (Test-Path $MenuMarker)) { continue }
        $marker = Get-Item $MenuMarker
        if ($marker.LastWriteTime -le $since) { continue }
        if (((Get-Date) - $marker.LastWriteTime).TotalSeconds -gt 10) { continue }

        try {
            Rename-Item $saveDir $probe -ErrorAction Stop
            Rename-Item $probe $saveDir -ErrorAction Stop
            return $true
        } catch {
            try { if (Test-Path $probe) { Rename-Item $probe $saveDir } } catch {}
        }
    }
    return $false
}

function Invoke-Restore($req) {
    $mode  = Sanitize-Name $req.gameMode
    $world = Sanitize-Name $req.worldName
    $worldKey = "{0}_{1}" -f $mode, $world
    $worldDir = Join-Path $BackupRoot $worldKey

    if (-not (Test-Path $worldDir)) {
        throw "no checkpoints exist for $worldKey"
    }
    $checkpoints = Get-ChildItem $worldDir -Directory |
        Where-Object { $_.Name -notlike "_prerestore_*" } |
        Sort-Object Name -Descending
    if (-not $checkpoints) {
        throw "no checkpoints exist for $worldKey"
    }
    $chosen = $checkpoints[0]   # request label "latest"; newest wins

    $saveDir = Join-Path (Join-Path (Join-Path $ZomboidDir "Saves") $mode) $world
    if (-not (Test-Path $saveDir)) {
        throw "save folder not found: $saveDir"
    }

    Write-Log "restore: waiting for the game to unload '$saveDir'"
    $received = Get-Date
    if (-not (Wait-SaveUnloaded $saveDir $received)) {
        throw "gave up waiting for the save to unload ($UnloadWaitSec s)"
    }

    # safety net: snapshot the current (post-death) save before overwriting
    $preStamp = "_prerestore_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
    $preDir = Join-Path $worldDir $preStamp
    Write-Log "restore: safety snapshot -> '$preDir'"
    $null = robocopy $saveDir $preDir /E /R:2 /W:1 /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) { throw "safety snapshot failed (robocopy $LASTEXITCODE)" }
    # keep only the two newest safety snapshots
    Get-ChildItem $worldDir -Directory |
        Where-Object { $_.Name -like "_prerestore_*" } |
        Sort-Object Name -Descending | Select-Object -Skip 2 |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -Confirm:$false }

    Write-Log "restore: '$($chosen.FullName)' -> '$saveDir'"
    $null = robocopy $chosen.FullName $saveDir /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) {
        throw "restore copy failed (robocopy $LASTEXITCODE) - a safety snapshot is at $preDir"
    }

    return "restored checkpoint '$($chosen.Name)'"
}

# ---- main loop -------------------------------------------------------
New-Item -ItemType Directory -Force $BackupRoot | Out-Null
Write-Log "watcher started. Watching: $RequestFile (keep $KeepPerWorld per world)"
Write-Host "Daydream watcher running - leave this window open while playing. Ctrl+C to stop."

$gameSeen = $false
$lastGameCheck = Get-Date

while ($true) {
    Start-Sleep -Milliseconds $PollMs

    # -FollowGame: stop when the game we were riding along with exits
    if ($FollowGame -and ((Get-Date) - $lastGameCheck).TotalSeconds -ge 10) {
        $lastGameCheck = Get-Date
        $game = Get-Process ProjectZomboid64 -ErrorAction SilentlyContinue
        if ($game) {
            $gameSeen = $true
        } elseif ($gameSeen) {
            Write-Log "game exited - watcher stopping (FollowGame)"
            break
        }
    }

    if (-not (Test-Path $RequestFile)) { continue }

    try {
        $raw = Get-Content $RequestFile -Raw -ErrorAction Stop
    } catch {
        continue  # likely mid-write by the game; retry next poll
    }
    if (-not $raw -or $raw.Trim() -eq "") { continue }

    try { $req = $raw | ConvertFrom-Json } catch {
        Write-Log "bad request json, discarding: $raw"
        Remove-Item $RequestFile -Force -Confirm:$false
        continue
    }

    # consume the request before acting so a crash can't loop on it
    Remove-Item $RequestFile -Force -Confirm:$false
    Write-Log "request: id=$($req.id) action=$($req.action) world=$($req.gameMode)/$($req.worldName) label=$($req.label)"

    try {
        switch ($req.action) {
            "backup"  { $msg = Invoke-Backup $req }
            "restore" { $msg = Invoke-Restore $req }
            default   { throw "unknown action '$($req.action)'" }
        }
        Write-Ack $req.id $true $req.action $msg
        Write-Log "ok: $msg"
    } catch {
        $err = $_.Exception.Message
        Write-Ack $req.id $false $req.action $err
        Write-Log "FAILED: $err"
    }
}
