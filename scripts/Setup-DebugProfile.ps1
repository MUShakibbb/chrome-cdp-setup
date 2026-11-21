#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a separate Chrome profile for CDP debugging, copied from your main profile.

.DESCRIPTION
    Chrome 136+ refuses DevTools on the default user-data-dir, so a dedicated profile is required.
    This script copies your existing profile (bookmarks, extensions, settings - caches excluded),
    renames it, and removes duplicate profile entries so the picker shows a single profile.

    IMPORTANT: Chrome must be fully closed. Do not run this against a profile that is in use, and
    never point Chrome at your live profile through a junction - app-bound encryption will make
    the cookies undecryptable and Chrome will delete them.

.EXAMPLE
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    .\Setup-DebugProfile.ps1
#>
[CmdletBinding()]
param(
    [string] $Source      = "$env:LOCALAPPDATA\Google\Chrome\User Data",
    [string] $Destination = "$env:LOCALAPPDATA\ChromeDebugProfile",
    [string] $ProfileName = 'NotebookLM Debug',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

# --- Preflight ---------------------------------------------------------------

if (Get-Process chrome -ErrorAction SilentlyContinue) {
    throw "Chrome is running. Close every Chrome window first (a copy of a live profile is unsafe)."
}
if (-not (Test-Path $Source)) { throw "Source profile not found: $Source" }

if ((Test-Path $Destination) -and (Get-ChildItem $Destination -Force | Select-Object -First 1)) {
    if (-not $Force) {
        throw "Destination already exists: $Destination`nRe-run with -Force to overwrite, or pick another -Destination."
    }
    Write-Warn "Overwriting existing destination: $Destination"
}

# --- Copy (caches excluded: ~750 MB of pure cache in a typical profile) ------

Write-Step "Copying profile: $Source -> $Destination"
$excludeDirs = @(
    'Cache', 'Code Cache', 'GPUCache', 'DawnWebGPUCache', 'DawnGraphiteCache',
    'GraphiteDawnCache', 'ShaderCache', 'GrShaderCache', 'GPUPersistentCache',
    'Service Worker', 'Media Cache', 'component_crx_cache', 'extensions_crx_cache',
    'Crashpad', 'BrowserMetrics'
)
$excludeFiles = @('DevToolsActivePort', 'CrashpadMetrics-active.pma', 'SingletonLock', 'SingletonCookie', 'SingletonSocket')

$robocopyArgs = @($Source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1', '/XD') + $excludeDirs + @('/XF') + $excludeFiles
& robocopy @robocopyArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

# --- Sanitise profile registry ----------------------------------------------

$localState = Join-Path $Destination 'Local State'
$prefs      = Join-Path $Destination 'Default\Preferences'

Copy-Item $localState "$localState.bak" -Force
if (Test-Path $prefs) { Copy-Item $prefs "$prefs.bak" -Force }

Write-Step "Renaming profile to '$ProfileName' and removing duplicate entries"

$json = Get-Content $localState -Raw | ConvertFrom-Json
$cache = $json.profile.info_cache

if (-not $cache.PSObject.Properties['Default']) {
    throw "Unexpected Local State: no 'Default' profile entry."
}

$cache.Default.name = $ProfileName
$cache.Default.shortcut_name = $ProfileName

foreach ($name in @($cache.PSObject.Properties.Name)) {
    if ($name -ne 'Default') {
        $cache.PSObject.Properties.Remove($name)
        $dir = Join-Path $Destination $name
        if (Test-Path $dir) {
            Rename-Item $dir "$name.disabled" -Force
            Write-Warn "Disabled duplicate profile directory: $name"
        }
    }
}

$json.profile.last_used = 'Default'
$json.profile.last_active_profiles = @('Default')
if ($json.profile.PSObject.Properties['profiles_order']) { $json.profile.profiles_order = @('Default') }

$json | ConvertTo-Json -Depth 100 | Set-Content $localState -Encoding UTF8

if (Test-Path $prefs) {
    $p = Get-Content $prefs -Raw | ConvertFrom-Json
    if ($p.profile) { $p.profile.name = $ProfileName }
    $p | ConvertTo-Json -Depth 100 | Set-Content $prefs -Encoding UTF8
}

Write-Step "Done."
Write-Host ""
Write-Host "Next:" -ForegroundColor Green
Write-Host "  .\Start-DebugChrome.ps1 -ProfileDir `"$Destination`""
Write-Host "  .\Test-Cdp.ps1"
Write-Host ""
Write-Host "Then sign in to your account ONCE in the new window - it persists from then on."
