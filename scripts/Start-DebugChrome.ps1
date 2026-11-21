#Requires -Version 5.1
<#
.SYNOPSIS
    Launches a debuggable Chrome instance on a dedicated profile and waits until CDP answers.

.DESCRIPTION
    Flags only take effect when a browser process starts. If Chrome is already running on the same
    profile, the new process just forwards a "new window" request to it and exits - the flags are
    silently ignored. This script refuses to start in that situation.

.EXAMPLE
    .\Start-DebugChrome.ps1
    .\Start-DebugChrome.ps1 -Port 9333 -ProfileDir "$env:LOCALAPPDATA\ChromeDebugProfile"
#>
[CmdletBinding()]
param(
    [int]    $Port       = 9222,
    [string] $ProfileDir = "$env:LOCALAPPDATA\ChromeDebugProfile",
    [string] $ChromePath,
    [switch] $AllowAnyOrigin = $true
)

$ErrorActionPreference = 'Stop'
function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

if (-not $ChromePath) {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $ChromePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $ChromePath) { throw "chrome.exe not found. Pass -ChromePath explicitly." }
}

# A stale listener is the #1 cause of "flags had no effect" and of port splitting.
$holder = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($holder) {
    $proc = Get-Process -Id $holder.OwningProcess -ErrorAction SilentlyContinue
    throw "Port $Port is already in use by PID $($holder.OwningProcess) ($($proc.ProcessName)).`n" +
          "Close that Chrome completely, or use -Port with a free port. Flags cannot be changed on a running browser."
}

if (-not (Test-Path $ProfileDir)) {
    throw "Profile not found: $ProfileDir`nRun .\Setup-DebugProfile.ps1 first."
}

$chromeArgs = @(
    "--remote-debugging-port=$Port",
    "--user-data-dir=$ProfileDir",
    "--no-first-run",
    "--no-default-browser-check"
)
if ($AllowAnyOrigin) { $chromeArgs += '--remote-allow-origins=*' }

Write-Step "Launching: $ChromePath"
Write-Step "Profile:   $ProfileDir"
Write-Step "Port:      $Port"
Start-Process -FilePath $ChromePath -ArgumentList $chromeArgs | Out-Null

# Wait for the DevTools HTTP endpoint.
function Get-DevToolsJson([int]$p) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $p)
        $stream = $client.GetStream()
        $req = "GET /json/version HTTP/1.1`r`nHost: localhost:$p`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        $reader = New-Object System.IO.StreamReader($stream)
        $raw = $reader.ReadToEnd()
        $parts = $raw -split "`r`n`r`n", 2
        if ($parts.Count -lt 2) { return $null }
        return $parts[1] | ConvertFrom-Json
    } catch { return $null } finally { $client.Close() }
}

$deadline = (Get-Date).AddSeconds(30)
$info = $null
while ((Get-Date) -lt $deadline) {
    $info = Get-DevToolsJson $Port
    if ($info) { break }
    Start-Sleep -Milliseconds 700
}

if (-not $info) {
    throw "DevTools did not answer on port $Port within 30s.`n" +
          "If the port is bound but returns 404, Chrome is using the DEFAULT profile (Chrome 136+ blocks DevTools there)."
}

Write-Step "DevTools is up."
Write-Host "  Browser : $($info.Browser)" -ForegroundColor Green
Write-Host "  WS URL  : $($info.webSocketDebuggerUrl)" -ForegroundColor Green
Write-Host ""
Write-Host "This WebSocket URL changes on every launch - never cache it." -ForegroundColor Yellow
Write-Host "Run .\Test-Cdp.ps1 to verify the WebSocket handshake (HTTP 200 alone is not enough)."
