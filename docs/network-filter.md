# Experimental network filter / 实验性网络过滤

## Status / 状态

The settings UI, controller, content-filter provider, signing packager and policy tests are implemented. The ordinary `bash scripts/build-app.sh` build is ad-hoc signed and deliberately does not embed the extension. It cannot activate network blocking. No real system-extension activation, packet-level interception, notarization or distribution acceptance has been completed.

设置、控制器、扩展源码及策略测试已实现。普通打包版本明确显示不可用；不能把开关已保存、系统授权完成或单元测试通过当作真实拦截验收。

## Behavior / 行为

| Situation / 情况 | Intended filter behavior / 过滤行为 |
| --- | --- |
| Switch off / 默认关闭 | No filter installation; existing process protection remains available / 不安装过滤扩展，原进程保护可用 |
| Enabled, no valid safety decision yet / 尚未检查通过 | Block identified protected flows / 阻断能识别的受保护流量 |
| Confirmed safe / 确认安全 | Allow protected flows; continue tracking / 放行并持续跟踪 |
| Probe timeout after approval / 已通过后普通探针超时 | Preserve previous approval; managed launches still need fresh checks / 保留原放行，受管启动仍需检查 |
| Confirmed unsafe proxy or exit / 确认代理或出口异常 | Lock, drop tracked protected flows and reject new matching flows / 锁定并阻断 |
| Network restored / 网络恢复 | Remain locked until manual recovery succeeds / 保持锁定直到手动恢复 |
| Window closed / 关闭窗口 | Continue / 继续保护 |
| Normal pause or quit / 正常停止或退出 | Disable filter configuration and confirm before completing / 确认停用后再结束 |
| Host crash or forced termination / 主程序崩溃或强退 | Lease expires after 8 seconds; provider blocks identified protected flows / 8 秒租约到期后阻断受保护连接 |

Claude process protection covers all outbound socket flows the provider identifies, including `127.0.0.1` and `::1`. Address rules apply additionally to other applications only when the separate option is enabled, scoped to the current user. `*.example.com` matches subdomains but not the apex. Rules do not accept URLs, ports or paths. No hosts, DNS, proxy, PF rules or TLS certificates are modified. Payload bytes are passed through without inspection or logging.

默认按当前用户及已知 Claude 可执行路径识别。地址规则仅在额外开关打开时扩展到其他应用。未识别流量放行，避免阻断整机网络。过滤器失联不等于 VPN 不稳定：前者使过滤策略租约到期；后者仅在确认不安全时锁定。

## Signing build / 签名构建

Requires a Developer ID Application signing identity, two matching Developer ID provisioning profiles and the relevant Apple capabilities. The host bundle ID is `dev.local.agent-account-guardian`; the extension is `dev.local.agent-account-guardian.filter`.

Both profiles must authorize `content-filter-provider-systemextension` and the shared application group `<TEAM_ID>.dev.local.agent-account-guardian`. The host also needs `com.apple.developer.system-extension.install`. The packager validates these values before embedding profiles or signing. Keep identities, profiles and credentials out of Git.

```sh
export GUARDIAN_WITH_FILTER=1
export GUARDIAN_TEAM_ID='YOURTEAMID'
export GUARDIAN_SIGN_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)'
export GUARDIAN_APP_PROFILE='/absolute/path/host.provisionprofile'
export GUARDIAN_FILTER_PROFILE='/absolute/path/filter.provisionprofile'
bash scripts/build-app.sh
```

The script signs the extension first and the host second, with hardened runtime and timestamps. It does not notarize automatically. Complete notarization and staple the ticket before distributing; validate on a separate Mac. Install under `/Applications`, close existing Claude sessions, save the switch, approve macOS prompts, and require a live provider acknowledgement in the UI. If macOS reports a reboot is needed, restart before retrying.

普通版本无法激活扩展，不应关闭 SIP 或绕过系统签名校验。安装失败时仍保留用户的偏好，但显示未就绪并关闭受管启动门禁。若旧签名版已经安装扩展，新版本无法确认停用时会阻止正常退出；可在 macOS 的网络过滤设置中先停用 Account Guardian，再重试退出。

## Acceptance tests / 实机验收（待签名环境执行）

Use a disposable account and test sessions. Do not use live work sessions for destructive tests.

1. Start with filtering off; confirm other apps and existing process protection work. Refuse system authorization, then verify the UI never claims filtering is effective and managed launches remain blocked.
2. Enable the signed filter with no Claude sessions open. Check that both native Claude CLI and Desktop are recognized. Repeat with the supported Node entrypoint. Check localhost HTTP proxy and tunnel paths separately.
3. Establish a long-lived protected connection, then induce a confirmed wrong pinned IP or unsafe proxy. Verify both the existing flow and new attempts fail, including IPv4, IPv6, TCP and UDP/QUIC where supported. Observe actual packets or server-side requests; a UI counter alone is insufficient.
4. Restore the VPN. Verify traffic stays blocked until successful manual recovery. Simulate only a probe timeout after prior approval; verify it does not lock or terminate existing sessions.
5. Leave address protection for other apps off and verify unrelated apps remain online. Turn it on and test exact domains, wildcard boundaries, literal IPs, browsers and proxy-forwarded requests. Record unavailable-hostname cases as uncovered.
6. Close the window, reopen from Dock and confirm continuity. Pause and quit normally; verify the system filter is disabled. Force-terminate the host only in the test environment and verify lease expiry blocks matching flows while unrelated traffic remains available.
7. Test sleep/wake, provider restart, host restart, denied permissions, stalled XPC, simultaneous settings changes and quit, and unsigned downgrade with a previously installed extension. Confirm stale acknowledgements never reopen the launch gate.

## Limits / 边界

- Fault detection is periodic. Traffic can pass before detection or lease expiry. This is not a zero-leak guarantee.
- Flows established before filter activation may not be intercepted; close and reopen Claude first. Newly added address rules apply to new flows. Unrelated flows already allowed are not retrospectively discovered.
- `remoteHostname` is not available for every flow. No TLS/SNI parsing or DNS correlation is implemented. Proxy multiplexing and browser helper processes need real-world coverage testing.
- Missing audit identity or executable metadata is allowed, not guessed. Nonstandard CLI locations/arguments and changes to installed executable paths can evade matching. The GUI and diagnostics process count alone cannot prove provider identity lookup works inside its sandbox.
- Only the owning user is covered. This is not a system-wide multi-user firewall.
- A failed provider, disabled extension, OS restart or administrator changes are outside the host-heartbeat guarantee. Provider restart uses the most recently saved configuration and starts blocked until a fresh heartbeat.

## References / 依据

- [Apple: Filtering network traffic](https://developer.apple.com/documentation/networkextension/filtering-network-traffic)
- [Apple: Applying provider settings](https://developer.apple.com/documentation/networkextension/nefilterdataprovider/apply(_:completionhandler:))
- [Apple: System extensions](https://developer.apple.com/documentation/systemextensions)
- [Anthropic: Network configuration](https://code.claude.com/docs/en/network-config)
