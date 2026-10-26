import XCTest
@testable import NomadFs

final class NomadFsTests: XCTestCase {
    private let swarmKey = "4090e76685f6f17bbe398fd4b2f12945168aaaa64107b7e57fe72dffa2c9436e"

    private func write(_ path: String, _ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func writeConfig(nickname: String, port: UInt16, dir: String) throws -> String {
        let conf = """
        [node]
        nickname = "\(nickname)"
        swarm_key = "\(swarmKey)"
        key_path = "\(dir)/node.key"

        [storage]
        enabled = true
        storage_path = "\(dir)/data"

        [network]
        port = \(port)
        transport = "tcp"
        upnp_enabled = false
        enable_mdns = false
        bootstrap_peers = []
        """
        let path = "\(dir)/nomadfs.conf"
        try write(path, conf)
        return path
    }

    func testTwoNodesRoundTripThroughTheCABI() throws {
        let base = NSTemporaryDirectory() + "nomadfs-swift-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: base + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/b", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let payloadPath = "\(base)/payload.bin"
        let outPath = "\(base)/out.bin"

        let configA = try writeConfig(nickname: "swift-a", port: 13450, dir: "\(base)/a")
        let configB = try writeConfig(nickname: "swift-b", port: 13451, dir: "\(base)/b")

        let payload = Data("swift bridge payload ".utf8) + Data((0..<4096).map { UInt8($0 % 251) })
        try payload.write(to: URL(fileURLWithPath: payloadPath))

        guard let nodeA = NomadFs.open(configPath: configA) else { return XCTFail("node A did not open") }
        guard let nodeB = NomadFs.open(configPath: configB) else { return XCTFail("node B did not open") }
        defer { nodeA.close(); nodeB.close() }

        XCTAssertEqual(nodeA.run(), 0)
        XCTAssertEqual(nodeB.run(), 0)

        if let deviceId = nodeA.deviceId() {
            XCTAssertEqual(deviceId.count, 64)
            XCTAssertTrue(deviceId.allSatisfy { $0.isHexDigit })
        } else {
            XCTFail("device id missing")
        }

        XCTAssertEqual(nodeB.bootstrap(urlsCsv: "tcp://127.0.0.1:13450"), 0)
        Thread.sleep(forTimeInterval: 1.0)

        guard let cid = nodeB.put(inPath: payloadPath) else { return XCTFail("put returned nil") }
        XCTAssertEqual(cid.count, 64)

        let status = nodeA.get(cid: cid, outPath: outPath)
        XCTAssertEqual(status, 0)

        let output = try Data(contentsOf: URL(fileURLWithPath: outPath))
        XCTAssertEqual(output, payload)
    }
}
