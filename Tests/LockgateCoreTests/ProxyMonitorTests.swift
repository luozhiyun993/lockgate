import XCTest
@testable import LockgateCore

final class ProxyMonitorTests: XCTestCase {
    /// 取自 mihomo v1.19.34 `GET /connections` 的真实返回（删去了无关字段）。
    private let sample = #"""
    {"downloadTotal":2317657,"uploadTotal":406,"memory":0,"connections":[
      {"id":"b8752b82","metadata":{"network":"tcp","type":"HTTP","sourceIP":"127.0.0.1","destinationIP":"127.0.0.1",
        "sourcePort":"64134","destinationPort":"48080","host":"","process":"curl","processPath":"/usr/bin/curl",
        "remoteDestination":"127.0.0.1","sniffHost":""},
       "upload":85,"download":2317657,"start":"2026-11-21T17:53:19.853292+08:00","chains":["DIRECT"],
       "providerChains":[""],"rule":"IPCIDR","rulePayload":"127.0.0.0/8"},
      {"id":"e9bbbdb6","metadata":{"network":"tcp","type":"Socks5","sourceIP":"127.0.0.1","destinationIP":"",
        "sourcePort":"64135","destinationPort":"443","host":"example.com","process":"curl","processPath":"/usr/bin/curl",
        "remoteDestination":"192.0.2.1","sniffHost":""},
       "upload":321,"download":0,"start":"2026-11-21T17:53:19.854723+08:00","chains":["节点 A","PROXY"],
       "providerChains":["",""],"rule":"Match","rulePayload":""},
      {"id":"reject01","metadata":{"network":"udp","type":"Tun","destinationIP":"203.0.113.7","destinationPort":"53",
        "host":"","process":"","sniffHost":"ads.blocked.test"},
       "upload":0,"download":0,"start":"bad-date","chains":["REJECT-DROP"],"rule":"DomainSuffix","rulePayload":"blocked.test"},
      {"metadata":{"host":"no-id.example"}}
    ]}
    """#

    func testParsesRealConnectionList() throws {
        let snapshot = try XCTUnwrap(ConnectionParser.parse(Data(sample.utf8)))
        XCTAssertEqual(snapshot.downloadTotal, 2_317_657)
        XCTAssertEqual(snapshot.uploadTotal, 406)
        XCTAssertEqual(snapshot.connections.map(\.id), ["b8752b82", "e9bbbdb6", "reject01"])

        let direct = snapshot.connections[0]
        XCTAssertEqual(direct.destination, "127.0.0.1:48080")
        XCTAssertEqual(direct.route, .direct)
        XCTAssertEqual(direct.outbound, "DIRECT")
        XCTAssertEqual(direct.ruleText, "IPCIDR（127.0.0.0/8）")
        XCTAssertEqual(direct.process, "curl")
        XCTAssertEqual(direct.inboundTitle, "HTTP 代理")
        XCTAssertEqual(direct.download, 2_317_657)
        XCTAssertEqual(direct.start.map { Int($0.timeIntervalSince1970) }, 1_795_254_799)

        let proxied = snapshot.connections[1]
        XCTAssertEqual(proxied.destination, "example.com:443")
        XCTAssertEqual(proxied.route, .proxied)
        XCTAssertEqual(proxied.outbound, "节点 A")
        XCTAssertEqual(proxied.chainText, "PROXY → 节点 A")
        XCTAssertEqual(proxied.ruleText, "Match")
        XCTAssertEqual(proxied.inboundTitle, "SOCKS 代理")

        let rejected = snapshot.connections[2]
        XCTAssertEqual(rejected.host, "ads.blocked.test", "没有域名时使用嗅探到的主机名")
        XCTAssertEqual(rejected.route, .rejected)
        XCTAssertEqual(rejected.inboundTitle, "TUN")
        XCTAssertNil(rejected.start)
    }

    func testRejectsMalformedPayloadAndAcceptsEmptyList() {
        XCTAssertNil(ConnectionParser.parse(Data("not json".utf8)))
        XCTAssertEqual(ConnectionParser.parse(Data(#"{"downloadTotal":1,"uploadTotal":2,"connections":null}"#.utf8)),
                       ConnectionSnapshot(uploadTotal: 2, downloadTotal: 1, connections: []))
    }

    func testRouteClassification() {
        XCTAssertEqual(ConnectionRoute(outbound: "DIRECT"), .direct)
        XCTAssertEqual(ConnectionRoute(outbound: "REJECT"), .rejected)
        XCTAssertEqual(ConnectionRoute(outbound: "REJECT-DROP"), .rejected)
        XCTAssertEqual(ConnectionRoute(outbound: "🇯🇵 东京 01"), .proxied)
        XCTAssertEqual(ConnectionRecord(id: "x", host: "h", chains: []).outbound, "未知")
    }

    func testUsageGroupsByActualOutbound() {
        let connections = [
            ConnectionRecord(id: "1", host: "a", chains: ["东京", "PROXY"], upload: 10, download: 100),
            ConnectionRecord(id: "2", host: "b", chains: ["东京", "AUTO", "PROXY"], upload: 5, download: 50),
            ConnectionRecord(id: "3", host: "c", chains: ["DIRECT"], upload: 1, download: 1000),
            ConnectionRecord(id: "4", host: "d", chains: ["REJECT"])
        ]
        let usage = ConnectionParser.usage(connections)
        XCTAssertEqual(usage.map(\.name), ["DIRECT", "东京", "REJECT"])
        XCTAssertEqual(usage[1], OutboundUsage(name: "东京", route: .proxied, connections: 2, upload: 15, download: 150))
        XCTAssertEqual(usage[0].route, .direct)
        XCTAssertEqual(usage[2].total, 0)
        XCTAssertEqual(ConnectionParser.speed(2048), "2.0 KB/s")
        XCTAssertEqual(ConnectionParser.speed(-5), "0 B/s")
    }

    func testProcessLookupIsAlwaysEnabledForMonitoring() throws {
        let runtime = CoreRuntime(mixedPort: 17890, controllerPort: 51234, secret: "s", mode: .rule, tun: false)
        let composed = try ProfileComposer.compose(profile: "find-process-mode: off\nproxies: []\n", runtime: runtime)
        XCTAssertFalse(composed.contains("find-process-mode: off"))
        XCTAssertTrue(composed.contains("find-process-mode: \"always\""))
    }
}
