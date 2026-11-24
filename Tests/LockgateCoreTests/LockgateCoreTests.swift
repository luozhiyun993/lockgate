import XCTest
@testable import LockgateCore
import Darwin

final class LockgatePolicyTests: XCTestCase {
    private let healthy = LocalHealth.healthy(interface: "utun1500")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func exit(_ ip: String = "8.8.8.8", _ country: String = "JP") -> ExitHealth {
        .known(ExitObservation(ip: ip, country: country, timestamp: now))
    }

    func testMatchingCountryAllowsLaunchAndIPChangeOnlyWarns() {
        let settings = LockgateSettings()
        XCTAssertEqual(LockgatePolicy.evaluate(settings: settings, local: healthy, exit: exit(), now: now), .allow)
        let changed = LockgatePolicy.evaluate(settings: settings, local: healthy, exit: exit(), previousIP: "1.1.1.1", now: now)
        guard case .warn = changed else { return XCTFail("Same-country changes must only warn") }
        XCTAssertTrue(changed.mayLaunch)
    }

    func testWrongCountryTrips() {
        let result = LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy, exit: exit("8.8.8.8", "US"), now: now)
        guard case .trip = result else { return XCTFail("Country mismatch must trip") }
        XCTAssertFalse(result.mayLaunch)
    }

    func testPinnedMismatchTripsWithinSameCountry() {
        var settings = LockgateSettings()
        settings.pinEnabled = true
        settings.pinnedIP = "1.1.1.1"
        guard case .trip = LockgatePolicy.evaluate(settings: settings, local: healthy, exit: exit(), now: now) else {
            return XCTFail("Pinned IP must match even within target country")
        }
    }

    func testPinnedMatchDoesNotOverrideWrongCountry() {
        var settings = LockgateSettings()
        settings.pinEnabled = true
        settings.pinnedIP = "8.8.8.8"
        guard case .trip = LockgatePolicy.evaluate(settings: settings, local: healthy, exit: exit("8.8.8.8", "US"), now: now) else {
            return XCTFail("Pinning adds a constraint; it does not bypass country checks")
        }
    }

    func testTimeoutDoesNotTripButBlocksLaunch() {
        let result = LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy, exit: .unknown("timeout"), now: now)
        XCTAssertEqual(result, .wait("timeout"))
        var state = ProtectionState()
        state.enabled = true
        state.observe(result)
        XCTAssertNil(state.lockedReason)
        XCTAssertFalse(result.mayLaunch)
    }

    func testConfirmedKernelFailureTripsEvenWhenNetworkIsUnknown() {
        let result = LockgatePolicy.evaluate(settings: LockgateSettings(), local: .unsafe("kernel stopped"), exit: .unknown("timeout"), now: now)
        XCTAssertEqual(result, .trip("kernel stopped"))
    }

    func testUnknownLocalDoesNotHideConfirmedExitMismatch() {
        let result = LockgatePolicy.evaluate(settings: LockgateSettings(), local: .unknown("route unavailable"), exit: exit("8.8.8.8", "US"), now: now)
        guard case .trip = result else { return XCTFail("Confirmed exit violation must trip") }
    }

    func testUnknownProcessesBlockLaunchWithoutChangingHealthyNetwork() {
        let processes = ProcessHealth(targets: nil)
        XCTAssertNil(processes.count)
        let result = LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy,
            exit: exit(), processes: processes, now: now)
        XCTAssertEqual(result, .wait(processes.summary))
        XCTAssertEqual(healthy.summary, "网络路径已确认 · utun1500")
        XCTAssertEqual(LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy,
            exit: exit(), now: now), .allow)
        var state = ProtectionState()
        state.enabled = true
        state.heartbeat = now
        state.observe(result)
        XCTAssertNil(state.lockedReason)
        XCTAssertFalse(state.permitsLaunch(result, now: now))
        state.lockedReason = "existing lock"
        XCTAssertFalse(state.recover(result))
        XCTAssertEqual(state.lockedReason, "existing lock")
    }

    func testZeroProcessesAreSuccessfulInspectionNotUnknown() {
        let processes = ProcessHealth(targets: [])
        XCTAssertEqual(processes, .healthy(count: 0))
        XCTAssertEqual(processes.count, 0)
        XCTAssertEqual(processes.summary, "进程检查已完成 · 已识别 0 个受保护进程")
        XCTAssertEqual(LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy,
            exit: exit(), processes: processes, now: now), .allow)
        let target = ProcessIdentity(pid: 100, uid: 501, started: "today", executable: "/bin/sleep")
        XCTAssertEqual(ProcessHealth(targets: [target]), .healthy(count: 1))
    }

    func testUnknownProcessesDoNotHideConfirmedNetworkOrExitFaults() {
        let processes = ProcessHealth(targets: nil)
        XCTAssertEqual(LockgatePolicy.evaluate(settings: LockgateSettings(), local: .unsafe("proxy refused"),
            exit: .unknown("timeout"), processes: processes, now: now), .trip("proxy refused"))
        guard case .trip = LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy,
            exit: exit("8.8.8.8", "US"), processes: processes, now: now) else {
            return XCTFail("Unknown processes must not hide a confirmed country mismatch")
        }
        var settings = LockgateSettings()
        settings.pinEnabled = true
        settings.pinnedIP = "1.1.1.1"
        guard case .trip = LockgatePolicy.evaluate(settings: settings, local: healthy,
            exit: exit(), processes: processes, now: now) else {
            return XCTFail("Unknown processes must not hide a confirmed IP mismatch")
        }
    }

    func testSeparateProcessStatusPreservesLegacyGateDecisions() {
        var pinned = LockgateSettings()
        pinned.pinEnabled = true
        pinned.pinnedIP = "1.1.1.1"
        let staleExit = ExitHealth.known(ExitObservation(ip: "8.8.8.8", country: "JP",
            timestamp: now.addingTimeInterval(-26)))
        for settings in [LockgateSettings(), pinned] {
            for local in [healthy, .unknown("route unavailable"), .unsafe("proxy refused")] {
                for observation in [exit(), exit("8.8.8.8", "US"), .unknown("timeout"), staleExit] {
                    for processes in [ProcessHealth.healthy(count: 0), ProcessHealth(targets: nil)] {
                        var legacyLocal = local
                        if case .healthy = local, case .unknown(let reason) = processes {
                            legacyLocal = .unknown(reason)
                        }
                        let legacy = LockgatePolicy.evaluate(settings: settings, local: legacyLocal,
                            exit: observation, previousIP: "1.1.1.1", now: now)
                        let separated = LockgatePolicy.evaluate(settings: settings, local: local,
                            exit: observation, processes: processes, previousIP: "1.1.1.1", now: now)
                        XCTAssertEqual(separated, legacy)
                    }
                }
            }
        }
    }

    func testPartialProcessesBlockLaunchButKeepVerifiedCountAndNetworkFaultPriority() {
        let processes = ProcessHealth.partial(count: 2, reason: "Claude candidate unresolved")
        XCTAssertEqual(processes.count, 2)
        let result = LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy,
            exit: exit(), processes: processes, now: now)
        XCTAssertEqual(result, .wait("Claude candidate unresolved"))
        XCTAssertEqual(LockgatePolicy.evaluate(settings: LockgateSettings(), local: .unsafe("proxy refused"),
            exit: exit(), processes: processes, now: now), .trip("proxy refused"))
    }

    func testStaleOrFutureObservationCannotLaunch() {
        for timestamp in [now.addingTimeInterval(-26), now.addingTimeInterval(10)] {
            let result = LockgatePolicy.evaluate(settings: LockgateSettings(), local: healthy,
                exit: .known(ExitObservation(ip: "8.8.8.8", country: "JP", timestamp: timestamp)), now: now)
            guard case .wait = result else { return XCTFail("Unusable observations cannot authorize launch") }
        }
    }

    func testObservationModeDoesNotLockOrAllowLaunch() {
        var state = ProtectionState()
        state.heartbeat = now
        state.observe(.trip("wrong country"))
        XCTAssertNil(state.lockedReason)
        XCTAssertFalse(state.permitsLaunch(.allow, now: now))
    }

    func testRecoveryRequiresManualSuccessfulCheckAndEnabledProtection() {
        var state = ProtectionState()
        state.enabled = true
        state.heartbeat = now
        state.observe(.trip("wrong country"))
        state.observe(.allow)
        XCTAssertEqual(state.lockedReason, "wrong country")
        XCTAssertFalse(state.permitsLaunch(.allow, now: now))
        XCTAssertFalse(state.recover(.wait("timeout")))
        state.enabled = false
        XCTAssertFalse(state.recover(.allow))
        state.enabled = true
        XCTAssertTrue(state.recover(.allow))
        XCTAssertTrue(state.permitsLaunch(.allow, now: now))
        XCTAssertFalse(state.permitsLaunch(.allow, now: now.addingTimeInterval(9)))
    }

    func testIPv6CanonicalEquality() {
        var settings = LockgateSettings()
        settings.pinEnabled = true
        settings.pinnedIP = "2606:4700:4700:0000:0000:0000:0000:1111"
        XCTAssertEqual(LockgatePolicy.evaluate(settings: settings, local: healthy,
            exit: exit("2606:4700:4700::1111"), now: now), .allow)
    }

    func testTraceRejectsMalformedDuplicateAndUnknownData() {
        for text in ["<html>blocked</html>", "ip=8.8.8.8\nloc=XX", "ip=127.0.0.1\nloc=JP",
                     "ip=8.8.8.8\nloc=JP\nloc=US", "ip=abc\nloc=JP", "ip=8.8.8.8"] {
            XCTAssertNil(ExitObservation.parse(text))
        }
        XCTAssertEqual(ExitObservation.parse("fl=test\nip=8.8.8.8\nloc=JP\n", now: now)?.country, "JP")
    }

    func testInvalidSettingsBlock() {
        var settings = LockgateSettings()
        settings.country = "Japan"
        XCTAssertNotNil(settings.validationError)
        settings.country = "JP"
        settings.pinEnabled = true
        for value in ["", "127.0.0.1", "198.18.0.1", "10.0.0.1", "1.1.1.1:7890", "::1"] {
            settings.pinnedIP = value
            XCTAssertNotNil(settings.validationError)
        }
    }

    func testLockAndSettingsPersistAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(directory: directory)
        var state = ProtectionState()
        state.enabled = true
        state.settings.pinEnabled = true
        state.settings.pinnedIP = "1.1.1.1"
        state.observe(.trip("pinned mismatch"))
        try store.save(state)
        let restored = try store.load()
        XCTAssertEqual(restored.lockedReason, "pinned mismatch")
        XCTAssertEqual(restored.settings, state.settings)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

final class InspectionTests: XCTestCase {
    func testInstallationDiscoveryAcrossCustomLayouts() throws {
        XCTAssertGreaterThan(try discoveryRegressionChecks(), 25)
    }

    func testRouteParserReadsActualInterface() {
        XCTAssertEqual(LocalInspector.routeInterface(from: "gateway: 10.0.0.1\n  interface: utun7\n"), "utun7")
        XCTAssertNil(LocalInspector.routeInterface(from: "route: not in table"))
    }

    func testProcessSnapshotDoesNotDependOnLocaleOrTimeZone() throws {
        // 曾经解析 ps 的 lstart 文本：zh_TW 等区域设置下字段数不同，所有进程行解析失败、识别数恒为 0。
        let saved = ["LANG", "LC_ALL", "TZ"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            tzset()
        }
        func parent() throws -> ProcessIdentity {
            try XCTUnwrap(ProcessInspector.snapshot()?.first { $0.pid == getppid() })
        }
        setenv("LANG", "zh_TW.UTF-8", 1); setenv("LC_ALL", "zh_TW.UTF-8", 1); setenv("TZ", "Asia/Taipei", 1); tzset()
        let first = try parent()
        setenv("LANG", "ar_SA.UTF-8", 1); setenv("LC_ALL", "ar_SA.UTF-8", 1); setenv("TZ", "America/Los_Angeles", 1); tzset()
        XCTAssertEqual(try parent(), first)
        XCTAssertNotNil(first.started.range(of: #"^[0-9]+\.[0-9]{6}$"#, options: .regularExpression))
    }

    func testStartIdentityKeepsMicrosecondPrecision() {
        XCTAssertEqual(ProcessInspector.startIdentity(seconds: 1_795_000_000, microseconds: 42), "1795000000.000042")
        XCTAssertNotEqual(ProcessInspector.startIdentity(seconds: 1, microseconds: 10),
                          ProcessInspector.startIdentity(seconds: 1, microseconds: 100))
    }

    func testNativeCLIWithShortProcessTitleUsesKernelPath() throws {
        let raw = ProcessIdentity(pid: 94272, uid: 501, started: "1.000000", executable: "claude", executableVerified: false)
        let installed = "/Users/example/.local/share/claude/versions/2.1.319"
        XCTAssertFalse(raw.executableVerified)
        let resolved = raw.resolvingExecutable(installed)
        XCTAssertEqual(resolved.pid, raw.pid)
        XCTAssertEqual(resolved.started, raw.started)
        XCTAssertTrue(ProcessInspector.isProtected(resolved, settings: LockgateSettings(), uid: 501, cliExecutable: installed))
        var settings = LockgateSettings()
        settings.protectCLI = false
        XCTAssertFalse(ProcessInspector.isProtected(resolved, settings: settings, uid: 501, cliExecutable: installed))
    }

    func testMisleadingProcessTitleCannotAuthorizeTermination() throws {
        let installed = "/Users/example/.local/share/claude/versions/2.1.319"
        let raw = ProcessIdentity(pid: 94272, uid: 501, started: "1.000000", executable: installed, executableVerified: false)
        XCTAssertFalse(ProcessInspector.isProtected(raw, settings: LockgateSettings(), uid: 501, cliExecutable: installed))
        let resolved = raw.resolvingExecutable("/bin/sleep")
        XCTAssertFalse(ProcessInspector.isProtected(resolved, settings: LockgateSettings(), uid: 501, cliExecutable: installed))
    }

    func testUnresolvedCandidateIsUnknownInsteadOfZeroTargets() throws {
        let raw = ProcessIdentity(pid: 94272, uid: 501, started: "1.000000", executable: "claude", executableVerified: false)
        XCTAssertTrue(ProcessInspector.hasUnresolvedCandidate(raw.resolvingExecutable(nil), settings: LockgateSettings(), uid: 501))
        XCTAssertTrue(ProcessInspector.hasUnresolvedCandidate(raw.resolvingExecutable("claude"), settings: LockgateSettings(), uid: 501))
        XCTAssertFalse(ProcessInspector.hasUnresolvedCandidate(raw, settings: LockgateSettings(), uid: 502))
        XCTAssertFalse(ProcessInspector.hasUnresolvedCandidate(raw.resolvingExecutable("/bin/sleep"), settings: LockgateSettings(), uid: 501))
    }

    func testDesktopMainAndHelperPathsRemainRecognized() throws {
        for path in ["/Applications/Claude.app/Contents/MacOS/Claude",
                     "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"] {
            let raw = ProcessIdentity(pid: 94272, uid: 501, started: "1.000000", executable: "Claude", executableVerified: false)
            XCTAssertTrue(ProcessInspector.isProtected(raw.resolvingExecutable(path), settings: LockgateSettings(), uid: 501,
                installations: ClaudeInstallations(desktopApplications: [URL(fileURLWithPath: "/Applications/Claude.app")])) )
        }
    }

    func testMatcherDoesNotSelectOtherUsersOrSimilarNames() {
        let settings = LockgateSettings()
        func process(_ path: String, uid: UInt32 = 501) -> ProcessIdentity {
            ProcessIdentity(pid: 100, uid: uid, started: "today", executable: path)
        }
        let desktopInstallations = ClaudeInstallations(desktopApplications: [URL(fileURLWithPath: "/Applications/Claude.app")])
        XCTAssertTrue(ProcessInspector.isProtected(process("/Applications/Claude.app/Contents/MacOS/Claude"), settings: settings, uid: 501, installations: desktopInstallations))
        XCTAssertFalse(ProcessInspector.isProtected(process("/Applications/Claude.app/Contents/MacOS/Claude", uid: 502), settings: settings, uid: 501))
        XCTAssertFalse(ProcessInspector.isProtected(process("/tmp/Claude.app/Contents/MacOS/Claude"), settings: settings, uid: 501))
        XCTAssertFalse(ProcessInspector.isProtected(process("/Applications/Claude.app.fake/Contents/MacOS/Claude"), settings: settings, uid: 501))
        XCTAssertFalse(ProcessInspector.isProtected(process("/usr/local/bin/claude-helper"), settings: settings, uid: 501, cliExecutable: "/usr/local/bin/claude"))
    }

    func testNodeMatchingRequiresActualEntrypointNotMentionInEval() {
        let path = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let identity = ProcessIdentity(pid: 100, uid: 501, started: "today", executable: "/opt/homebrew/bin/node")
        XCTAssertTrue(ProcessInspector.isProtected(identity, settings: LockgateSettings(), uid: 501, cliExecutable: path, arguments: ["node", path]))
        XCTAssertFalse(ProcessInspector.isProtected(identity, settings: LockgateSettings(), uid: 501, cliExecutable: path, arguments: ["node", "-e", path]))
    }

    func testRenamedNodeProcessStillRequiresClaudeEntrypoint() throws {
        let path = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let raw = ProcessIdentity(pid: 94272, uid: 501, started: "1.000000", executable: "claude", executableVerified: false)
        let identity = raw.resolvingExecutable("/opt/homebrew/bin/node")
        XCTAssertTrue(ProcessInspector.isProtected(identity, settings: LockgateSettings(), uid: 501, cliExecutable: path, arguments: ["node", path]))
        XCTAssertFalse(ProcessInspector.isProtected(identity, settings: LockgateSettings(), uid: 501, cliExecutable: path, arguments: ["node", "/tmp/other.js"]))
    }

    func testKernelFallbackUsesExecutablePathNotMutableArgumentZero() {
        var argc: Int32 = 2
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/bin/sleep\0\0claude\0test\0".utf8))
        XCTAssertEqual(ProcessInspector.executablePath(fromKernelArguments: data), "/bin/sleep")
        XCTAssertNil(ProcessInspector.executablePath(fromKernelArguments: Data([0, 0, 0])))
        var relative = withUnsafeBytes(of: &argc) { Data($0) }
        relative.append(Data("claude\0".utf8))
        XCTAssertNil(ProcessInspector.executablePath(fromKernelArguments: relative))
        var truncated = withUnsafeBytes(of: &argc) { Data($0) }
        truncated.append(Data("/bin/sleep".utf8))
        XCTAssertNil(ProcessInspector.executablePath(fromKernelArguments: truncated))
    }

    func testUnrelatedNodeAndSimilarNamesDoNotBlockInspection() {
        let settings = LockgateSettings()
        let cli = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        for name in ["node", "bun", "claude-helper", "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
                     "/Applications/Codex.app/Contents/Resources/cua_node/bin/node"] {
            let identity = ProcessIdentity(pid: 100, uid: 501, started: "today", executable: name, executableVerified: false)
            XCTAssertFalse(ProcessInspector.hasUnresolvedCandidate(identity, settings: settings, uid: 501, cliExecutable: cli))
            let result = ProcessInspector.evaluate([identity], settings: settings, uid: 501, cliExecutable: cli,
                arguments: { _ in ["node", "/tmp/other.js"] }, lifecycle: { _ in XCTFail("Unrelated process must not block"); return .running })
            XCTAssertNil(result.failureReason)
            XCTAssertEqual(result.health, .healthy(count: 0))
        }
    }

    func testExitedCandidatesAreIgnoredButRunningUnknownKeepsVerifiedTargets() {
        let settings = LockgateSettings()
        let target = ProcessIdentity(pid: 100, uid: 501, started: "today", executable: "/Applications/Claude.app/Contents/MacOS/Claude")
        let unknown = ProcessIdentity(pid: 101, uid: 501, started: "today", executable: "claude", executableVerified: false)
        let installations = ClaudeInstallations(desktopApplications: [URL(fileURLWithPath: "/Applications/Claude.app")])
        let exited = ProcessInspector.evaluate([target, unknown], settings: settings, uid: 501, installations: installations,
            arguments: { _ in [] }, lifecycle: { _ in .gone })
        XCTAssertEqual(exited.targets, [target])
        XCTAssertNil(exited.failureReason)
        for lifecycle in [ProcessInspector.ProcessLifecycle.running, .unknown] {
            let partial = ProcessInspector.evaluate([target, unknown], settings: settings, uid: 501, installations: installations,
                arguments: { _ in [] }, lifecycle: { _ in lifecycle })
            XCTAssertEqual(partial.targets, [target])
            XCTAssertNotNil(partial.failureReason)
            XCTAssertEqual(partial.health.count, 1)
            XCTAssertNotNil(partial.health.blockingReason)
        }
    }

    func testOnlyClaudeNodeEntrypointIsTargetOrUnresolvedCandidate() {
        let settings = LockgateSettings()
        let cli = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let raw = ProcessIdentity(pid: 100, uid: 501, started: "today", executable: "node", executableVerified: false)
        let args = ["node", cli]
        XCTAssertTrue(ProcessInspector.hasUnresolvedCandidate(raw, settings: settings, uid: 501, cliExecutable: cli, arguments: args))
        let unresolved = ProcessInspector.evaluate([raw], settings: settings, uid: 501, cliExecutable: cli,
            arguments: { _ in args }, lifecycle: { _ in .running })
        XCTAssertTrue(unresolved.targets.isEmpty)
        XCTAssertNotNil(unresolved.failureReason)
        let verified = raw.resolvingExecutable("/opt/homebrew/bin/node")
        let result = ProcessInspector.evaluate([verified], settings: settings, uid: 501, cliExecutable: cli,
            arguments: { _ in args }, lifecycle: { _ in .running })
        XCTAssertEqual(result.targets, [verified])
        XCTAssertNil(result.failureReason)
    }

    func testStopperTerminatesOnlyOwnedDisposableChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        guard let target = ProcessInspector.snapshot()?.first(where: { $0.pid == child.processIdentifier }) else {
            throw XCTSkip("Process inspection unavailable in this environment")
        }
        XCTAssertTrue(target.executableVerified)
        XCTAssertEqual(target.executable, ProcessInspector.executablePath(pid: child.processIdentifier))
        let unverified = ProcessIdentity(pid: target.pid, uid: target.uid, started: target.started,
                                        executable: target.executable, executableVerified: false)
        let unverifiedReport = await ProcessStopper.stop([unverified])
        XCTAssertEqual(unverifiedReport.stopped, 0)
        XCTAssertTrue(child.isRunning)
        let stale = ProcessIdentity(pid: target.pid, uid: target.uid, started: "different start", executable: target.executable)
        let rejected = await ProcessStopper.stop([stale])
        XCTAssertEqual(rejected.stopped, 0)
        XCTAssertTrue(child.isRunning)
        let report = await ProcessStopper.stop([target])
        child.waitUntilExit()
        XCTAssertEqual(report.stopped, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(child.isRunning)
    }

    func testLegacyDirectoryIsCopiedOnceAndNeverOverwritesNewState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("AgentAccountGuardian")
        let current = root.appendingPathComponent("Lockgate")
        var state = ProtectionState()
        state.enabled = true
        state.observe(.trip("legacy lock"))
        try StateStore(directory: legacy).save(state)

        StateStore.migrateLegacyDirectory(from: legacy, to: current)
        XCTAssertEqual(try StateStore(directory: current).load().lockedReason, "legacy lock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))

        var newer = ProtectionState()
        newer.enabled = true
        newer.observe(.trip("newer lock"))
        try StateStore(directory: current).save(newer)
        StateStore.migrateLegacyDirectory(from: legacy, to: current)
        XCTAssertEqual(try StateStore(directory: current).load().lockedReason, "newer lock")
    }
}
