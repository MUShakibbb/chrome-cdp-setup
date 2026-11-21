#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that Chrome's DevTools endpoint is reachable AND that the WebSocket handshake succeeds.

.DESCRIPTION
    HTTP 200 on /json/version does not mean CDP works. This script also performs a real WebSocket
    upgrade - both with and without an Origin header - because clients that send Origin are rejected
    unless Chrome was started with --remote-allow-origins=*.

.EXAMPLE
    .\Test-Cdp.ps1
    .\Test-Cdp.ps1 -Port 9333
#>
[CmdletBinding()]
param([int] $Port = 9222)

$ErrorActionPreference = 'Stop'

function Invoke-RawRequest {
    param([int] $Port, [string] $Path, [hashtable] $Headers = @{}, [int] $TimeoutMs = 6000)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $TimeoutMs

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("GET $Path HTTP/1.1`r`n")
        [void]$sb.Append("Host: 127.0.0.1:$Port`r`n")
        foreach ($k in $Headers.Keys) { [void]$sb.Append("${k}: $($Headers[$k])`r`n") }
        [void]$sb.Append("`r`n")

        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $buffer = New-Object byte[] 8192
        $sbIn = New-Object System.Text.StringBuilder
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            [void]$sbIn.Append([Text.Encoding]::ASCII.GetString($buffer, 0, $read))
            if ($sbIn.ToString() -match "`r`n`r`n") { break }
        }
        return $sbIn.ToString()
    } catch {
        return $null
    } finally {
        $client.Close()
    }
}

function Get-StatusLine($raw) {
    if (-not $raw) { return $null }
    return ($raw -split "`r`n")[0]
}

Write-Host "Testing CDP on port $Port" -ForegroundColor Cyan
Write-Host ""

# --- 1. HTTP -----------------------------------------------------------------
$http = Invoke-RawRequest -Port $Port -Path '/json/version'
$status = Get-StatusLine $http

if (-not $status) {
    Write-Host "FAIL  no response on 127.0.0.1:$Port" -ForegroundColor Red
    Write-Host "      Chrome is not running with --remote-debugging-port, or the port is wrong."
    exit 1
}

Write-Host "HTTP  $status"
if ($status -notmatch '200') {
    Write-Host ""
    Write-Host "FAIL  DevTools rejected the HTTP request." -ForegroundColor Red
    if ($status -match '404') {
        Write-Host "      404 with an empty body means Chrome is running on the DEFAULT profile." -ForegroundColor Yellow
        Write-Host "      Chrome 136+ blocks DevTools there - pass a dedicated --user-data-dir." -ForegroundColor Yellow
    }
    exit 1
}

$body = ($http -split "`r`n`r`n", 2)[1]
$info = $null
try { $info = $body | ConvertFrom-Json } catch { }
if (-not $info) {
    Write-Host "FAIL  could not parse /json/version body." -ForegroundColor Red
    exit 1
}
Write-Host "      Browser: $($info.Browser)"
Write-Host "      WS URL : $($info.webSocketDebuggerUrl)"
Write-Host ""

$wsPath = $info.webSocketDebuggerUrl -replace '^ws://[^/]+', ''

# --- 2. WebSocket without Origin --------------------------------------------
$wsHeaders = @{
    'Connection'            = 'Upgrade'
    'Upgrade'               = 'websocket'
    'Sec-WebSocket-Version' = '13'
    'Sec-WebSocket-Key'     = 'dGhlIHNhbXBsZSBub25jZQ=='
}
$plain = Get-StatusLine (Invoke-RawRequest -Port $Port -Path $wsPath -Headers $wsHeaders)
Write-Host "WS    (no Origin)   $plain"

# --- 3. WebSocket with Origin (what real clients send) ----------------------
$originHeaders = $wsHeaders.Clone()
$originHeaders['Origin'] = "http://localhost:$Port"
$withOrigin = Get-StatusLine (Invoke-RawRequest -Port $Port -Path $wsPath -Headers $originHeaders)
Write-Host "WS    (with Origin) $withOrigin"
Write-Host ""

$okPlain  = $plain      -match '101'
$okOrigin = $withOrigin -match '101'

if ($okPlain -and $okOrigin) {
    Write-Host "PASS  CDP is fully working, including clients that send an Origin header." -ForegroundColor Green
    exit 0
}
if ($okPlain -and -not $okOrigin) {
    Write-Host "PARTIAL  Handshake works, but Origin is rejected (403)." -ForegroundColor Yellow
    Write-Host "         Clients like chrome-devtools / Puppeteer will time out." -ForegroundColor Yellow
    Write-Host "         Relaunch Chrome with --remote-allow-origins=* (fully quit it first)." -ForegroundColor Yellow
    exit 2
}
Write-Host "FAIL  WebSocket upgrade refused." -ForegroundColor Red
Write-Host "      Check for a second Chrome instance on this port: netstat -ano | findstr :$Port" -ForegroundColor Yellow
exit 1
