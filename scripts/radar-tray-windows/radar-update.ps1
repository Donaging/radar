# radar-update.ps1 — verifica versione Radar ed esegue l'auto-update (se più recente).
# Uso interno Windows PowerShell 5.1 (powershell.exe).
#
# Flusso:
#   versione installata -> ultima release GitHub -> se più recente: scarica, estrae,
#   backup dei binari correnti, ferma Radar, sostituisce i due binari, riavvia e
#   VERIFICA che il server torni online. In caso di errore ripristina i backup e riavvia.
#
# L'asset di release contiene UN solo binario (kubectl-radar.exe); lo stesso identico
# binario viene usato anche come radar.exe -> vanno sostituiti entrambi.
#
# Uso:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\radar-update.ps1
# Parametro -silent: usa solo il file risultato (nessuna stampa a video), per il menu tray.

param([switch]$silent)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$installDir = Join-Path $env:LOCALAPPDATA 'radar'
$radarExe   = Join-Path $installDir 'radar.exe'
$backupDir  = Join-Path $env:USERPROFILE '.radar\backup'
$resultFile = Join-Path $env:USERPROFILE '.radar\last-update-result.txt'
$launcher   = Join-Path $env:USERPROFILE '.radar\start-radar-silent.ps1'

# Rotazione/pulizia log e temporanei (evita di riempire il disco)
function Clear-StaleRadar {
    $now = Get-Date
    # cartelle temporanee di install/download/AI piu' vecchie di 7gg
    foreach ($d in @('radar-install-*', 'radar-update-*', 'radar-ai-*')) {
        Get-Item (Join-Path $env:TEMP $d) -ErrorAction SilentlyContinue |
            Where-Object { $now.Subtract($_.LastWriteTime).TotalDays -gt 7 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    # log radar espliciti in Temp\opencode piu' vecchi di 30gg
    Get-ChildItem (Join-Path $env:TEMP 'opencode') -Filter 'radar-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $now.Subtract($_.LastWriteTime).TotalDays -gt 30 } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # download parziali interrotti (.tmp) in ~/.radar/updates piu' vecchi di 2gg
    Get-ChildItem (Join-Path $env:USERPROFILE '.radar\updates') -Filter '*.tmp' -ErrorAction SilentlyContinue |
        Where-Object { $now.Subtract($_.LastWriteTime).TotalDays -gt 2 } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # tiene il file risultato sotto ~2KB (ultimi caratteri)
    if (Test-Path $resultFile) {
        $t = Get-Content $resultFile -Raw
        if ($t.Length -gt 2048) { $t.Substring($t.Length - 2048) | Set-Content $resultFile -Encoding UTF8 }
    }
}
Clear-StaleRadar

function Write-Result([string]$m) {
    $m | Set-Content -Path $resultFile -Encoding UTF8
    if (-not $silent) { Write-Output $m }
}

# Verifica che il server Radar risponda sulla porta 9280 (MCP + web UI)
function Test-RadarUp {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', 9280, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1000, $false)
        if ($ok) { $c.EndConnect($iar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}

function Compare-Version([string]$a, [string]$b) {
    $pa = @($a -split '\.' | ForEach-Object { try { [int]$_ } catch { 0 } })
    $pb = @($b -split '\.' | ForEach-Object { try { [int]$_ } catch { 0 } })
    $n  = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# Bookkeeping per un ripristino/riavvio sicuro in caso di errore
$stopped  = $false
$backedUp = $false
$backups  = @{}

try {
    # 1) Versione installata
    $verLine = (& $radarExe --version) 2>&1 | Out-String
    $instVer = '0.0.0'
    if ($verLine -match 'radar\s+v?(\d+(?:\.\d+){1,3})') { $instVer = $Matches[1] }

    # 2) Ultima release GitHub
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/skyhook-io/radar/releases/latest' -Headers @{ 'User-Agent' = 'opencode' } -TimeoutSec 60
    $latestTag = $release.tag_name -replace '^v', ''

    if ((Compare-Version $instVer $latestTag) -ge 0) {
        Write-Result "Radar già aggiornato: installata $instVer = ultima disponibile $latestTag."
        exit 0
    }

    # 3) Download ed estrazione dell'asset della nuova versione
    $assetName = "radar_v$latestTag`_windows_amd64.zip"
    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) { throw "Asset di installazione non trovato: $assetName" }

    Write-Result "Scaricamento Radar $latestTag da GitHub..."
    $tmp  = Join-Path $env:TEMP ('radar-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip  = Join-Path $tmp $assetName

    # Download robusto: curl (streaming, retry, timeout lungo). Fallback Invoke-WebRequest.
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        & $curl -L --fail --retry 4 --retry-delay 3 --connect-timeout 30 --max-time 900 --silent --output $zip $asset.browser_download_url
        if ($LASTEXITCODE -ne 0) { throw "Download fallito (curl exit $LASTEXITCODE). Riprova: probabilmente rete/proxy." }
    } else {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 900
    }
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -eq 0) { throw "File scaricato vuoto/assente." }

    $exDir = Join-Path $tmp 'ex'
    Expand-Archive -Path $zip -DestinationPath $exDir -Force
    $newBin = Get-ChildItem $exDir -Filter 'kubectl-radar.exe' -Recurse | Select-Object -First 1
    if (-not $newBin) { throw "Binario kubectl-radar.exe non trovato nell'archivio." }

    # 4) Backup dei binari correnti (per il ripristino in caso di errore)
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    foreach ($f in @('radar.exe', 'kubectl-radar.exe')) {
        $p = Join-Path $installDir $f
        if (Test-Path $p) {
            $bak = Join-Path $backupDir ("$f.$instVer.bak")
            Copy-Item $p $bak -Force
            $backups[$f] = $bak
        }
    }
    $backedUp = $true

    # 5) Ferma Radar e sostituisci entrambi i binari con il nuovo
    Get-Process -Name 'radar' -ErrorAction SilentlyContinue | Stop-Process -Force
    $stopped = $true
    Start-Sleep -Milliseconds 500
    Copy-Item $newBin.FullName (Join-Path $installDir 'kubectl-radar.exe') -Force
    Copy-Item $newBin.FullName (Join-Path $installDir 'radar.exe') -Force

    # 6) Riavvio silenzioso e verifica che il server torni online (MCP + web UI)
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $launcher + '"')) -WindowStyle Hidden
    $online = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-RadarUp) { $online = $true; break }
    }

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    if ($online) {
        Write-Result "Radar aggiornato: $instVer -> $latestTag. Server riavviato e online."
    } else {
        Write-Result "Radar aggiornato: $instVer -> $latestTag, ma il server NON risulta ripartito. Esegui start-radar-silent.ps1."
    }
    exit 0
}
catch {
    # In caso di errore, ripristina i backup e riavvia: non lasciare Radar fermo/parziale
    if ($backedUp) {
        foreach ($f in @('radar.exe', 'kubectl-radar.exe')) {
            if ($backups.ContainsKey($f) -and (Test-Path $backups[$f])) {
                Copy-Item $backups[$f] (Join-Path $installDir $f) -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($stopped -or $backedUp) {
        Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $launcher + '"')) -WindowStyle Hidden
    }
    Write-Result "Errore durante la verifica/aggiornamento: $($_.Exception.Message). Binari ripristinati e server riavviato."
    exit 1
}
