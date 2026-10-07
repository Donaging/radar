# radar-tray.ps1 — indicatore di stato Radar nella tray (area di notifica di Windows)
# Avviato automaticamente al login (via VBS in Startup) con finestra nascosta.
# Uso INTERNO Windows PowerShell 5.1 (powershell.exe): con pwsh 7 il NotifyIcon da console non e' affidabile.
#
# Stati (pallino):
#   verde  = Radar attivo E cluster raggiungibile (GET /api/namespaces 200)
#   rosso  = Radar attivo ma cluster NON raggiungibile (es. tunnel VPN/SSO assente)
#   grigio = server Radar spento (porta 9280 non risponde)
# Tooltip mostra il cluster corrente (da /api/contexts isCurrent).
# Menu: Apri Radar · Avvia Radar · Cambia cluster (submenu) · Verifica aggiornamenti · Esci

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Una sola istanza dell'indicatore
$mutex = New-Object System.Threading.Mutex($false, 'Global\RadarTrayOpenCode')
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

$script:base     = 'http://localhost:9280'
$script:URL      = $script:base
$script:launcher = Join-Path $env:USERPROFILE '.radar\start-radar-silent.ps1'
$script:state    = $null     # down | clusterdown | up
$script:lastTip  = ''
$script:tc       = 0
$script:forceRefresh = $true

# --- API helper ---
function Test-Radar {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', 9280, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false)
        if ($ok) { $c.EndConnect($iar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}

# Cluster raggiungibile? GET /api/namespaces deve rispondere 200
function Test-Cluster {
    try {
        $r = Invoke-WebRequest -Uri ($script:base + '/api/namespaces') -UseBasicParsing -TimeoutSec 6
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Get-Contexts {
    try { return @(Invoke-RestMethod -Uri ($script:base + '/api/contexts') -TimeoutSec 6) }
    catch { return @() }
}

function Friendly-Name([string]$arn) {
    if ($arn -match 'cluster/([^/]+)$') { return $Matches[1] }
    return $arn
}

# Cluster corrente: dal contesto isCurrent=1 (fallback: settings.json ultimo usato)
function Get-CurrentCluster {
    try {
        $ctxs = Get-Contexts
        if ($ctxs) {
            $cur = $ctxs | Where-Object { $_.isCurrent } | Select-Object -First 1
            if ($cur) { return (Friendly-Name $cur.name) }
        }
    } catch { }
    try {
        $p = Join-Path $env:USERPROFILE '.radar\settings.json'
        if (Test-Path $p) {
            $s = Get-Content $p -Raw | ConvertFrom-Json
            $n = $s.lastDesktopContext.name
            if ($n) { return (Friendly-Name $n) }
        }
    } catch { }
    return $null
}

# Cambia cluster: POST /api/contexts/<name>, poi rinfresco immediato ed esito chiaro
function Switch-RadarContext([string]$ctxName) {
    $friendly = Friendly-Name $ctxName
    try {
        $enc = [uri]::EscapeDataString($ctxName)
        # NB: su cluster irraggiungibile la POST puo' rispondere 500 ma il contesto CAMBIA comunque
        try { $null = Invoke-RestMethod -Method Post -Uri ($script:base + '/api/contexts/' + $enc) -TimeoutSec 40 } catch { }
        Start-Sleep -Milliseconds 1200
        $ctxs = Get-Contexts
        Update-State $ctxs
        Populate-ClusterMenu $ctxs
        $cur = $ctxs | Where-Object { $_.isCurrent } | Select-Object -First 1
        $target = if ($cur) { Friendly-Name $cur.name } else { $friendly }
        $up = Test-Cluster
        $esito = if ($up) { 'connesso' } else { 'NON raggiungibile' }
        $icon  = if ($up) { [System.Windows.Forms.ToolTipIcon]::Info } else { [System.Windows.Forms.ToolTipIcon]::Warning }
        $tray.ShowBalloonTip(4000, 'Radar', "Cluster: $target - $esito", $icon)
    } catch {
        $tray.ShowBalloonTip(5000, 'Radar', 'Errore cambio cluster: ' + $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
    $script:forceRefresh = $true
}

# Calcola e applica stato (grigio/rosso/verde) in base a server + connettivita' cluster
function Update-State([object[]]$ctxs = @()) {
    if (-not (Test-Radar)) {
        if ($script:state -ne 'down') {
            Set-Status $script:iconOff 'Radar: SPENTO'
            $script:state = 'down'
        }
        return
    }
    if (-not $ctxs -or $ctxs.Count -eq 0) { $ctxs = Get-Contexts }
    $cur = $ctxs | Where-Object { $_.isCurrent } | Select-Object -First 1
    $cl  = if ($cur) { Friendly-Name $cur.name } else { Get-CurrentCluster }
    $up  = Test-Cluster
    if ($up) {
        $tip = 'Radar: ATTIVO' + $(if ($cl) { ' - ' + $cl } else { '' })
        if ($script:state -ne 'up' -or $script:lastTip -ne $tip) {
            Set-Status $script:iconUp $tip
            $script:state = 'up'; $script:lastTip = $tip
        }
    } else {
        $tip = 'Radar: cluster NON raggiungibile' + $(if ($cl) { ' (' + $cl + ')' } else { '' })
        if ($script:state -ne 'clusterdown' -or $script:lastTip -ne $tip) {
            Set-Status $script:iconDown $tip
            $script:state = 'clusterdown'; $script:lastTip = $tip
        }
    }
}

# Rigenera la voce "Cambia cluster" (submenu dinamico)
function Populate-ClusterMenu([object[]]$ctxs) {
    $clusterMenu.MenuItems.Clear()
    if (-not $ctxs -or $ctxs.Count -eq 0) {
        $mi = New-Object System.Windows.Forms.MenuItem('(nessun contesto)')
        $mi.Enabled = $false
        $null = $clusterMenu.MenuItems.Add($mi)
        return
    }
    foreach ($c in $ctxs) {
        $mi = New-Object System.Windows.Forms.MenuItem((Friendly-Name $c.name))
        $mi.Checked = [bool]$c.isCurrent
        $mi.Tag = $c.name
        $mi.Add_Click({ Switch-RadarContext $this.Tag })
        $null = $clusterMenu.MenuItems.Add($mi)
    }
}

# --- icone ---
function New-TrayIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($b, 1, 1, 14, 14)
    $g.Dispose(); $b.Dispose()
    $ic = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ic
}
$script:iconUp    = New-TrayIcon ([System.Drawing.Color]::LimeGreen)
$script:iconDown  = New-TrayIcon ([System.Drawing.Color]::Firebrick)   # cluster non raggiungibile
$script:iconOff   = New-TrayIcon ([System.Drawing.Color]::Gray)       # server spento

# --- costruzione tray e menu ---
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:iconOff
$tray.Text = 'Radar: avvio in corso...'
$tray.Visible = $true

$open   = New-Object System.Windows.Forms.MenuItem('Apri Radar (web UI)')
$start  = New-Object System.Windows.Forms.MenuItem('Avvia Radar')
$script:clusterMenu = New-Object System.Windows.Forms.MenuItem('Cambia cluster')
$check  = New-Object System.Windows.Forms.MenuItem('Verifica aggiornamenti...')
$sep    = New-Object System.Windows.Forms.MenuItem('-')
$quit   = New-Object System.Windows.Forms.MenuItem('Esci')
$tray.ContextMenu = (New-Object System.Windows.Forms.ContextMenu)
$null = $tray.ContextMenu.MenuItems.AddRange(@($open, $start, $clusterMenu, $sep, $check, $quit))

$open.Add_Click({ Start-Process $script:URL })
$tray.Add_DoubleClick({ Start-Process $script:URL })

$start.Add_Click({
    if (-not (Test-Radar)) {
        Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $script:launcher) -WindowStyle Hidden
        Start-Sleep -Milliseconds 400
        $script:forceRefresh = $true
    }
})

$check.Add_Click({
    $tray.ShowBalloonTip(2000, 'Radar', 'Verifica aggiornamenti in corso...', [System.Windows.Forms.ToolTipIcon]::Info)
    $resultFile = Join-Path $env:USERPROFILE '.radar\last-update-result.txt'
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $env:USERPROFILE '.radar\radar-update.ps1'),'-silent') -WindowStyle Hidden -Wait
    Start-Sleep -Milliseconds 400
    $msg = 'Nessun risultato disponibile.'
    if (Test-Path $resultFile) { $msg = (Get-Content $resultFile -Raw).Trim() }
    if ($msg.Length -gt 140) { $msg = $msg.Substring(0, 140) + '...' }
    $tray.ShowBalloonTip(6000, 'Radar update', $msg, [System.Windows.Forms.ToolTipIcon]::Info)
})

$quit.Add_Click({
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Aggiorna icona+tooltip rigenerando l'icona (obbliga la shell a mostrare la nuova tooltip)
function Set-Status($icon, $tip) {
    $tray.Visible = $false
    $tray.Icon = $icon
    $tray.Text = $tip
    $tray.Visible = $true
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    Update-State
    $script:tc++
    if (($script:tc % 3 -eq 0) -or $script:forceRefresh) {
        Populate-ClusterMenu (Get-Contexts)
        $script:forceRefresh = $false
    }
})

# Stato iniziale immediato + primo popolamento menu
Update-State
Populate-ClusterMenu (Get-Contexts)

[System.Windows.Forms.Application]::Run()

$mutex.ReleaseMutex()
