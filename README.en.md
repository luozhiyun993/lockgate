# Lockgate

## Built-in proxy

Lockgate bundles the mihomo core. Add a subscription on the **订阅** page, then start the proxy, pick nodes and choose how traffic is captured on the **代理** page.

- **Subscriptions**: full Clash / mihomo profiles keep their own proxy groups and rules; node-list subscriptions (share links, usually base64) get generated groups and a rule set that proxies everything except loopback and private ranges. Manual and scheduled updates; the active profile is hot-reloaded. Local files can be imported as well: the content is copied, never auto-updated, and re-read from the original file on request.
- **Overrides**: the **覆写** page holds YAML and script overrides, applied in list order to whichever subscription is active and kept across subscription updates. YAML overrides merge with the profile using the same rules as Clash Party (maps merge recursively, other values replace; `+rules` prepends, `rules+` appends, `dns!` replaces without merging). Script overrides define `function main(config) { return config }` and run in an isolated JavaScriptCore subprocess with no file or network access, no async support and a 15-second limit. Overrides may change DNS, TUN details, rules, groups and proxies; ports, the controller, LAN access, proxy mode and the TUN switch stay enforced by Lockgate, and blocking rules are added after overrides. Results are validated by the core on save; on failure the core keeps its previous configuration.
- **Managed settings**: listening ports, LAN access, the controller, TUN and DNS are always set by Lockgate regardless of the subscription. The mixed port (default 17890) and the controller listen on 127.0.0.1 only; the controller uses a random port and secret on every start. DNS defaults to Lockgate's fake-ip configuration and can be changed with an override.
- **System proxy**: points HTTP / HTTPS / SOCKS of every enabled network service at the built-in proxy and bypasses only loopback and private ranges. It is turned off again when the proxy stops or the app quits. Lockgate watches the system proxy settings: when another proxy app or a network change moves them away, the proxy page shows a notice with a "reclaim" button; with "restore automatically" ticked it puts them back itself, pausing after more than 3 takeovers within a minute so two apps do not keep overwriting each other. The option is off by default.
- **Local files auto-reload**: an imported local config is re-imported and hot-reloaded within a few seconds of the source file being saved (toggle under 订阅 → 自动更新). If the new content fails core validation, the previous config stays in use and the reason is shown on that entry.
- **Core follows the app**: when Lockgate opens and a subscription exists, the mihomo core starts and listens on the mixed port (default `127.0.0.1:17890`); only programs that connect to that port use it. System proxy and TUN are two independent switches, both off by default, applied at core start when on. **停止代理** lasts for the current run only. When upgrading from an older version with the proxy stopped, both switches are turned off once so that the first launch does not suddenly take over traffic.
- **Viewing configs**: each subscription has a **查看** button showing the content saved on disk; **查看最终配置** (subscription and override pages) shows the full config after overrides and Lockgate's managed settings are merged — the one the core actually loaded while running, a preview otherwise. The controller secret is hidden.
- **External resources (geo data)**: the proxy page sets the download URLs for the GeoIP / GeoSite / MMDB / ASN databases, the data mode used by GEOIP rules (db / dat), auto-update and its interval, plus an **立即更新** button while the proxy is running. These are written into the core config (`geox-url`, `geodata-mode`, `geo-auto-update`, `geo-update-interval`), replacing the subscription's values; YAML overrides can still change them. `geoip.metadb` and `GeoSite.dat` are bundled; the core only loads and updates databases that the active rules reference. Auto-update is off by default.
- **TUN mode**: captures all system traffic. The first activation asks for an administrator password once and installs the core at `/Library/Application Support/Lockgate/core/mihomo` as a root-owned setuid binary executable only by the admin group. Once authorised, the core runs from this root-owned binary even while TUN is off, so toggling TUN is a config hot-reload rather than a core restart; removing the authorisation switches back to the unprivileged core. Core upgrades require re-authorisation; the authorisation can be removed from the app. Once running, the proxy page and sidebar status show the interface the core created (e.g. `utun5`).
- **Live monitor**: the **实时监控** page refreshes every second with total up / down rates and a one-minute chart, a per-outbound summary of open connections (which node, direct, or rejected), and a connection list showing destination, source process, matched rule, outbound chain and rate, with filtering, search and disconnect. Only traffic passing through the built-in proxy is counted, nothing is written to disk, and process names are best-effort. The list has two tabs: **实时连接** (open connections, sortable by clicking a column header: down / up rate, bytes transferred, start time) and **连接日志** (ended connections with totals, duration and end time, up to 1000 entries). Sampling runs once a second while the core is running; logged totals are the last sample before the connection disappeared, and sub-second connections may be missed.
- **Core upgrades**: downloaded from the official mihomo GitHub release for the local architecture, SHA256-verified and test-run before replacing the previous core. The bundled version can be restored at any time.
- **Interaction with the guard**: while protection is enabled, starting or stopping the proxy, toggling system proxy / TUN or changing the port is a network-path change and trips the lock. If the core exits unexpectedly the system proxy keeps pointing at its port, so traffic fails closed instead of going direct.

The setuid core means members of the local admin group can run mihomo as root without a password; this is the trade-off for password-free TUN without a Developer ID. Core lifecycle, subscriptions, node selection, hot reload and port changes are verified; **system proxy and TUN capture have not yet been accepted on a real machine**. Bundled third-party components and licences are listed in [packaging/THIRD-PARTY.md](packaging/THIRD-PARTY.md).

## Network blocking

**出口与规则 → 网络阻断** blocks through the built-in proxy. The earlier system-extension mechanism has been removed from the interface; its source remains in the repository and is described at the end of this section.

### Blocking through the built-in proxy

Works in ordinary builds with no system extension or signing. Lockgate prepends a reject / pass switch group and matching address rules to the mihomo configuration. While protection is enabled, connections to the listed addresses are rejected by the core whenever the guard is locked or has not yet passed its checks, and existing connections are dropped; they are passed on to the subscription's own rules only after the checks pass and the lock is released manually. Pausing protection stops the blocking. The switch defaults to reject, so a core start, restart or reload stays closed until Lockgate confirms again, and managed launches require the core to confirm the pass state. The proxy is fixed to rule mode while this is enabled.

Limits: matching is by address for every application using the built-in proxy, not per process. Only traffic that passes through the built-in proxy is covered (it must be running with system proxy or TUN enabled), nothing is enforced after Lockgate or the core exits (in TUN mode traffic then goes direct), and applications that resolve names themselves and connect by IP are not matched by domain rules.

### System-extension mechanism (removed from the interface)

The settings page no longer offers this switch, and saving settings turns it off. The design notes below are kept for reference.

Settings now includes an opt-in network-blocking switch, default Claude addresses, custom domain / wildcard / IP rules, and a separate option to cover other applications accessing those addresses. The switch alone does not mean filtering is active: managed launches require a fresh acknowledgement from the system extension. Ordinary ad-hoc builds show that filtering is unavailable.

The signed extension is designed to block selected Claude processes' outbound flows, including local proxy connections, after a confirmed unsafe proxy or exit. Recovery remains manual. Probe timeouts retain a previously approved connection state. Closing the window retains protection; normal pause or quit disables filtering first. Losing the host heartbeat for approximately eight seconds blocks identified protected flows. Close existing Claude sessions before first activation.

Source compilation and policy tests are verified; **signed system-extension interception has not been validated on a real system**. Unknown process identities, unavailable hostnames, pre-existing connections and proxy forwarding limit coverage. See [network filter setup and acceptance tests](docs/network-filter.md) for signing prerequisites and limitations.

[简体中文](README.md) · [English](README.en.md)

<img src="assets/icon.png" width="128" alt="Lockgate friendly padlock icon">

A native macOS desktop app that checks the proxy environment used by Claude without depending on a particular proxy client. It provides launch checks, continuous monitoring, process termination on confirmed faults, persistent lockout, and manual recovery.

## Features

- Native SwiftUI window and menu bar, with a friendly illustrated padlock icon.
- Automatic detection of static system HTTPS proxies and actual tunnel routes.
- Separate network and process-inspection status and event entries. Unavailable process inspection does not overwrite network results, but still blocks managed launching and recovery.
- Exit-country validation and optional manually pinned exit IP.
- Protected launching and monitoring for Claude Desktop and Claude Code.
- Confirmed faults terminate selected processes and lock protection until manual recovery.
- Network timeouts leave existing Claude processes running while blocking new managed launches.
- Isolated fault simulations, an explicitly confirmed real emergency-stop test, a read-only diagnostic tool, and local event history.

The current interface is in Simplified Chinese. This English README documents the same behavior.

## Build and run

Requires macOS 13 or later, Swift 5.9 or later, and a network tool providing a system tunnel or a static macOS HTTPS proxy. There are no third-party package dependencies. From the project root:

```sh
bash scripts/build-app.sh
open "dist/Lockgate.app"
```

For development, use `swift run Lockgate`. The packaged app is ad-hoc signed locally and is not notarized. The packaging script builds both arm64 and x86_64 and creates a universal Apple Silicon / Intel application.

The app starts in **observation mode**: it checks the environment without terminating Claude. In **Exit & Rules (出口与规则)**, confirm the target country code and optional pinned IP, save your settings, then enable protection from **Overview (保护概览)**.

**Check Now (立即检查)** appears only on Overview and refreshes the real environment. The four simulations on the test page do not change live protection state.

Overview also provides **Emergency-stop all Claude (一键急停全部 Claude)**. After confirmation, it terminates all verified Claude Desktop / Code processes owned by the current user, regardless of the selected protection toggles. It never kills an unresolved process by name alone; save your work first.

Closing the window leaves the menu bar app running. Quitting stops monitoring and process enforcement. Reopening returns to observation mode while retaining any existing lockout. This version does not install a system daemon or enable launch at login.

## Protection rules

| Condition | Existing Claude processes | Managed launch / manual unlock |
| --- | --- | --- |
| Local proxy and exit checks pass | Keep running | Allowed; an existing lock still requires manual recovery |
| IP changes within the target country, without IP pinning | Warn and keep running | Allowed |
| Exit country does not match | Terminate and lock | Blocked |
| IP pinning is enabled and the address does not match | Terminate and lock | Blocked |
| System HTTPS proxy port explicitly refuses connections | Terminate and lock | Blocked |
| No system HTTPS proxy and complete probe routes include a non-tunnel path | Terminate and lock | Blocked |
| System proxy endpoint or proxy/tunnel mode changes during protection | Terminate and lock to avoid retaining the old proxy | Blocked |
| Network unavailable, exit lookup timeout, or unusable response | Keep running, show unknown, retry | Blocked |
| Process, route, or configuration inspection is unavailable | Keep running, show unknown, retry | Blocked |

IP pinning is an additional restriction; it does not override the target country. **Use Current Exit (使用当前出口)** fills the draft setting, which must then be saved. Automatic checks never change the configured country or pinned IP.

Local checks run approximately every 2 seconds. Exit checks repeat approximately 10 seconds after the previous request finishes; requests have a timeout of approximately 10 seconds. Command execution and system scheduling add latency. Network and local monitoring run independently so a slow exit lookup does not block local checks.

A lock remains until the user requests recovery and fresh checks pass. Changing settings, pausing protection, or reopening the app does not clear it.

## Client-independent network detection

- Does not read client processes, installation paths, subscriptions, or configuration files. No external controller is required.
- Prefers a static macOS HTTPS proxy, checks its TCP endpoint, and explicitly routes the exit probe through that same proxy. Proxy rejection does not fall back to a direct request.
- With no system proxy, verifies that routes to both `1.1.1.1` and `8.8.8.8` use existing `utun`, `tun`, `ppp`, `ipsec`, or `wg` interfaces. An unrelated virtual interface alone does not pass.
- PAC/autodiscovery, SOCKS-only, HTTP-only, conflicting per-interface settings, and ambiguous bypass rules remain unknown. IP/subnet exceptions and wildcard exceptions outside `.local` are conservatively blocked. Compatibility depends on network mode, not client branding.
- Missing routes, interface transitions, and proxy timeouts wait for retry. Confirmed non-tunnel routes or connection refusal trigger a local fault.
- Reads `ip` and `loc` from `https://www.cloudflare.com/cdn-cgi/trace` over the selected transport. Path changes invalidate previous exit observations.
- In system proxy mode, launch Claude Code through this app: the launcher sets proxy environment variables and clears stale proxy/bypass variables. Externally launched CLIs may ignore system settings. Desktop applications must themselves follow the system proxy; custom application proxies and routing rules need separate validation.

## Protected applications and launching

Process identity prefers the executable path returned by `proc_pidpath`, falling back to the kernel-provided executable path in `KERN_PROCARGS2` when necessary. Mutable `argv[0]` and `ps` display names never authorize termination. Matching is limited to dynamically discovered Claude Desktop applications and Claude Code installations for the current user. Unrelated Node/Bun processes are not candidates based on their names alone; npm launches must match the actual Claude Code script. Exited or zombie candidates do not block inspection.

Unresolved Claude candidates are reported separately and block new managed launches/recovery without discarding verified targets. A confirmed network fault still terminates verified Claude targets; unresolved identities are never killed by name alone.

Claude Desktop and Claude Code can be selected independently. Desktop discovery uses the product bundle ID, system application registration, and outer app metadata from running executables; directory and app name are not fixed. Monitoring and launching share the discovery result. CLI discovery checks the current PATH, common native/Homebrew/npm locations, and nvm/asdf/mise/fnm/Volta layouts, keeping multiple native versions observable. npm scripts are identified through the product package name and `bin.claude` declaration rather than a fixed `cli.js` filename; common Node options and scripts relative to the process working directory are supported.

For shell aliases, unresolved shims or other layouts, enter a trusted `.app` or CLI command path in **Exit & Rules → Installation Location**; absolute paths and `~/` are accepted, while empty fields use automatic discovery. Product IDs, package names, and bounded installer layouts remain matching conventions, not signature authentication. Shell shims are not themselves termination targets. macOS access restrictions and unknown runtime options can still cause misses; use `lockgate-diagnostics --list-installations --list-processes` to verify coverage.

Desktop launches use the system application API. Claude Code launches in Terminal and checks the lockgate heartbeat, lock, settings, local proxy, and exit again immediately before execution. Terminal determines the initial working directory. For a particular project, change directories in Terminal and run:

```sh
"/your/path/Lockgate.app/Contents/MacOS/Lockgate" --guarded-cli
```

While protection is enabled and locked, matching processes launched elsewhere are also terminated after detection. Direct launches bypass the pre-launch gate and the original CLI remains available. Emergency termination sends TERM first, then KILL to remaining processes whose identity still matches. Work in progress may be interrupted.

## Testing

Use `swift run lockgate-diagnostics --list-processes` to inspect matched PIDs and local executable paths. It does not terminate processes or print session arguments.

```sh
swift test --disable-sandbox
bash scripts/verify-discovery.sh
swift run lockgate-diagnostics --list-installations
swift run lockgate-diagnostics --network
```

Tests cover country/IP policy, unknown network states, persistent locks, manual recovery, stale observations, process matching, and identity revalidation. The automated termination test only terminates a disposable `/bin/sleep` child that the test itself created.

Diagnostics do not launch or terminate Claude and do not write protection state. Network requests are disabled by default; `--network` enables the Cloudflare lookup. Public IP output is hidden unless `--show-ip` is also provided.

The **Protection Tests (保护测试)** page offers:

1. **Safe simulation:** core exit, country drift, pinned-IP mismatch, and network timeout. Uses the real policy and lock model with isolated state and no process termination. This does not replace testing actual network failures.
2. **Real emergency-stop test:** after protection is enabled, explicit confirmation terminates the selected real Claude processes and locks protection. Save your work first. Return to Overview to check and unlock afterward.

Additional acceptance steps and verification results are in [docs/testing.md](docs/testing.md) and [docs/verification.md](docs/verification.md), currently in Chinese.

## Project structure

```text
Sources/LockgateCore/          Inspection, process matching, policy, persistence
Sources/LockgateApp/           SwiftUI interface, monitoring, protected launches
Sources/LockgateDiagnostics/   Read-only diagnostic CLI
Tests/LockgateCoreTests/       Policy and process termination tests
scripts/                      App packaging and icon rendering
packaging/                    macOS bundle metadata
assets/                       README icon
docs/                         Requirements, test procedures, verification notes
```

The source repository excludes `.build/`, `dist/`, personal protection settings, and runtime logs. Build the application locally using the commands above.

## Data and limitations

Settings and lock state are stored in `~/Library/Application Support/Lockgate/state.json`; on first run, existing settings and lock state are copied from the former `AgentAccountGuardian` directory. Events are stored in `events.json` in the same directory, with up to 200 entries. The directory uses mode 0700 and files use 0600. Settings contain the expected IP and last observed IP; events do not record account credentials, subscription URLs, or complete process arguments. The app does not read Claude passwords, cookies, or Keychain items.

Ordinary builds retain process-level protection. Packets may be sent between a fault and process termination. Without an active signed filter extension, protection is unavailable when the app is not running, is forcibly stopped, or the system is asleep. The optional experimental filter has the limitations described above. Continuing to run during an unknown network state is an intentional availability trade-off, not a guarantee against direct connections.

Cloudflare's country classification may differ from the service provider's. A lookup validates only that request's path, and two route probes do not validate every Claude domain. This version does not comprehensively check DNS, STUN/WebRTC, IPv6 bypass, or all proxy routing rules. It does not implement account switching, fingerprint changes, timezone changes, or a root daemon. IP pinning is not a substitute for network isolation.

## Acknowledgments

The launch-check and emergency-stop ideas were inspired by [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher). This is an independent Swift / SwiftUI implementation, not a complete port. It does not guarantee that an account will remain unrestricted.
