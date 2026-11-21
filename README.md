# chrome-cdp-setup

Set up a **debuggable Chrome** on Windows and drive it over CDP — from Windows, from WSL, or from an MCP client like `chrome-devtools`, Puppeteer, or Playwright.

Everything here was verified against **Chrome 158.0.8127.36** on Windows 11. Every trap listed below was hit in practice, not guessed.

---

## TL;DR

```powershell
# 1. Fully quit Chrome first (flags only apply at process start)
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force

# 2. Launch a debuggable instance on a dedicated profile
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --remote-debugging-port=9222 `
  --remote-allow-origins=* `
  --user-data-dir="$env:LOCALAPPDATA\ChromeDebugProfile"

# 3. Verify — expect HTTP 200 and then a 101 WebSocket handshake
.\scripts\Test-Cdp.ps1
```

Then sign in to your Google account **once** in that window. It persists.

---

## Why this is not just "add a flag"

Three independent Chrome behaviors combine to make this painful:

### 1. Chrome 136+ refuses DevTools on the *default* profile

If you run `chrome.exe --remote-debugging-port=9222` with no `--user-data-dir`, Chrome still **binds the port** — but the DevTools HTTP handler answers `404` with an empty body to every path:

```
HTTP/1.1 404 Not Found
Content-Length:0
Content-Type:text/html
```

So the port looks open and `netstat` looks healthy, but nothing works. The fix is a separate `--user-data-dir`.

> Diagnostic: `404` + `Content-Length:0` on `/json/version` = wrong profile, not a network problem.

### 2. Chrome 127+ app-bound encryption binds cookies to the profile *path*

Cookies are encrypted with a key tied to the exact user-data-dir path. If you **copy** or **junction** a profile to another location:

- Cookies cannot be decrypted
- Chrome **deletes** them from that database
- The account appears signed out

**Never clone or junction a live profile.** This silently destroys the original session — the deletion happens in the database Chrome opened, which for a junction is your real profile.

The only reliable route is: use a separate profile and sign in once.

### 3. Clients that send an `Origin` header get a 403

Modern CDP clients (MCP servers, browser-automation tooling) send an `Origin` header. Chrome rejects the handshake:

```
HTTP/1.1 403 Forbidden

Rejected an incoming WebSocket connection from the http://localhost:9222 origin.
Use the command line flag --remote-allow-origins=* to allow all origins.
```

Many clients retry until their deadline, so the error surfaces as **"timed out waiting for the WebSocket connection"** even though HTTP works fine.

---

## Symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| `/json/version` returns `404`, empty body | DevTools disabled on the default profile (Chrome 136+) | Pass a dedicated `--user-data-dir` |
| HTTP `200`, but WS hangs and times out | Client sends `Origin`; Chrome 403s the upgrade | Add `--remote-allow-origins=*` |
| Still `403` **after** adding the flag | Chrome was already running; the new process forwarded to the existing browser and exited — flags ignored | Fully quit Chrome so port 9222 is free, then relaunch |
| Two listeners on 9222, one on `[::1]` | A second instance started; it fell back to IPv6 and split the port | Run exactly one instance |
| WS works on `127.0.0.1` but `[::1]` refuses | Chrome binds IPv4 loopback only | Expected — use `127.0.0.1` or `localhost` |
| Profile picker shows the same account twice | You copied `User Data`, duplicating profile identities (same gaia IDs) | Strip the extra profiles (see below) |
| Profile looks right but Google asks you to sign in | Copied cookies can't decrypt (app-bound encryption) | Sign in once in the debug profile |

---

## Setup from scratch

Use `scripts/Setup-DebugProfile.ps1` **with Chrome fully closed**. It copies your profile (so bookmarks, extensions, and settings come along), excludes the multi-hundred-MB caches, renames the profile, and removes duplicate profile entries.

```powershell
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
.\scripts\Setup-DebugProfile.ps1
```

Then start and verify:

```powershell
.\scripts\Start-DebugChrome.ps1
.\scripts\Test-Cdp.ps1
```

Sign in to your account once in the new window. The login is then permanent for that profile.

### If the profile picker shows duplicates

Chrome reads profiles from `Local State` → `profile.info_cache`. Remove the entries you do not want, and move the matching directories aside:

```powershell
$root = "$env:LOCALAPPDATA\ChromeDebugProfile"
$ls = "$root\Local State"
$j = Get-Content $ls -Raw | ConvertFrom-Json
$j.profile.info_cache.PSObject.Properties.Remove('Profile 1')
$j.profile.profiles_order = @('Default')
$j | ConvertTo-Json -Depth 100 | Set-Content $ls -Encoding UTF8
Rename-Item "$root\Profile 1" "Profile 1.disabled"
```

Always back up `Local State` and `Default\Preferences` before editing them.

---

## Connecting

### Puppeteer

```js
const browser = await puppeteer.connect({ browserURL: 'http://127.0.0.1:9222' });
```

### Raw CDP (Node 22+, built-in WebSocket)

```js
const v = await (await fetch('http://127.0.0.1:9222/json/version')).json();
const ws = new WebSocket(v.webSocketDebuggerUrl);   // ws://127.0.0.1:9222/devtools/browser/<uuid>
```

The browser UUID changes on **every** launch. Never cache the WebSocket URL — always re-read `/json/version`.

### From WSL

The WSL2 loopback bridge works for both HTTP and WebSocket:

```
http://127.0.0.1:9222          -> 200
ws://127.0.0.1:9222/...        -> 101
ws://localhost:9222/...        -> 101
ws://[::1]:9222/...            -> connection refused (IPv4-only listener)
```

No port forwarding needed. If a client fails from WSL but works from Windows, it is almost always the `Origin` header (see above), not the bridge.

---

## Rules of thumb

1. **One instance only.** A second Chrome on the same profile is absorbed silently; a second on a different profile steals the port.
2. **Flags apply at launch.** Changing a flag requires quitting Chrome completely.
3. **Never cache the browser UUID.** It is regenerated every launch.
4. **Never clone or junction a live profile.** It destroys the session.
5. **Verify with a real handshake**, not just `/json/version` — HTTP 200 does not mean the WebSocket works.

---

## License

MIT — see [LICENSE](LICENSE).
