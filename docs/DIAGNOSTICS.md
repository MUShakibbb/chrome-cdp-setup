# Diagnostics

Copy-paste checks, in the order that isolates the problem fastest.

## 1. Is Chrome listening, and on how many addresses?

```powershell
netstat -ano | findstr :9222
```

- **One** line ending in `LISTENING` → good.
- **Two** lines, one `127.0.0.1` and one `[::1]` → two Chrome instances are fighting over the port. The second one fell back to IPv6. Close both.
- Nothing → Chrome is not running with `--remote-debugging-port`.

## 2. Does DevTools answer over HTTP?

```powershell
curl.exe --noproxy "*" http://127.0.0.1:9222/json/version
```

| Result | Meaning |
|---|---|
| JSON with `webSocketDebuggerUrl` | HTTP layer is fine |
| Empty output / `404` | Chrome is on the **default** profile (Chrome 136+ blocks DevTools there) |
| Connection refused | Not listening on IPv4 — see step 1 |

Always pass `--noproxy "*"`. A configured HTTP proxy silently turns loopback requests into 404s from the proxy itself, which looks exactly like a Chrome failure.

## 3. Does the WebSocket actually upgrade?

HTTP 200 does **not** mean CDP works. Test the real handshake:

```powershell
$v = (curl.exe -s --noproxy "*" http://127.0.0.1:9222/json/version | ConvertFrom-Json)
curl.exe -i --noproxy "*" -H "Connection: Upgrade" -H "Upgrade: websocket" `
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" `
  -H "Origin: http://localhost:9222" $v.webSocketDebuggerUrl
```

| Result | Meaning |
|---|---|
| `101 WebSocket Protocol Handshake` | Working, including Origin-sending clients |
| `403 Forbidden` | Chrome lacks `--remote-allow-origins=*` — relaunch it (quit fully first) |
| `404 Not Found` | The browser UUID is stale — it changes on every launch; re-read `/json/version` |

Or just run `scripts\Test-Cdp.ps1`, which performs both checks and prints a verdict.

## 4. Is the profile the reason?

```powershell
Get-Process chrome -ErrorAction SilentlyContinue | Select-Object Id, StartTime
Get-Content "$env:LOCALAPPDATA\ChromeDebugProfile\DevToolsActivePort" -ErrorAction SilentlyContinue
```

`DevToolsActivePort` (line 1 = port, line 2 = browser path) only exists for profiles where DevTools actually started. Its absence, while the port is bound, points at the default-profile block.

## 5. Are duplicate profiles confusing things?

```powershell
$j = Get-Content "$env:LOCALAPPDATA\ChromeDebugProfile\Local State" -Raw | ConvertFrom-Json
$j.profile.info_cache.PSObject.Properties | ForEach-Object { "$($_.Name) -> $($_.Value.name) / $($_.Value.user_name)" }
$j.profile.profiles_order
```

More than one entry means the profile picker will show duplicates. Keep `Default` and remove the rest.

## 6. From WSL

```bash
curl -s -o /dev/null -w '%{http_code}\n' --noproxy '*' http://127.0.0.1:9222/json/version
```

If this returns `200` but your CDP client still times out, the bridge is not the problem — it is almost always the `Origin` header (step 3). WSL2's loopback forwarding handles WebSocket upgrades fine; `[::1]` refuses because Chrome binds IPv4 loopback only.

## Reading the port file directly

```powershell
$p = Get-Content "$env:LOCALAPPDATA\ChromeDebugProfile\DevToolsActivePort"
$p[0]   # port
$p[1]   # /devtools/browser/<uuid>
```
