# start-radar-silent.ps1
# Avvia il server Radar in background in modo SILENZIOSO (nessuna finestra di terminale).
# Pensato per essere eseguito da una Scheduled Task al login, ma funziona anche a mano:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\start-radar-silent.ps1
#
# Preserva il flag --prometheus-single-cluster (stesso del wrapper pwsh `radar`, risolve
# "Historical cluster scope could not be verified") e non apre il browser (-no-browser):
# al posto della GUI desktop, la web UI resta disponibile su http://localhost:9280 .
# La porta 9280 serve sia la web UI sia l'endpoint MCP (http://localhost:9280/mcp) usato da OpenCode.

$radarExe = Join-Path $env:LOCALAPPDATA 'radar\radar.exe'
$radarArgs = @('--prometheus-single-cluster', '-no-browser')

# Evita duplicati: se un processo radar è già attivo, non riparte.
if (Get-Process -Name 'radar' -ErrorAction SilentlyContinue) {
    exit 0
}

# -WindowStyle Hidden -> il processo parte senza finestra visibile (niente "flash" di terminale).
Start-Process -FilePath $radarExe -ArgumentList $radarArgs -WindowStyle Hidden
