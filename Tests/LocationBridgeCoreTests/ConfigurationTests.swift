import Foundation
import XCTest
@testable import LocationBridgeCore

final class ConfigurationTests: XCTestCase {
    func testConfigurationRejectsRemoteIdentityAndUnboundedResources() throws {
        let target = try TargetCoordinate(latitude: 0, longitude: 0)
        let local = URL(fileURLWithPath: "/nonexistent-synthetic-identity.p12")
        XCTAssertThrowsError(try BridgeServerConfiguration(identityP12URL: URL(string: "https://example.invalid/identity.p12")!, password: "", target: target))
        XCTAssertThrowsError(try BridgeServerConfiguration(identityP12URL: local, password: "", target: target, port: 443))
        XCTAssertThrowsError(try BridgeServerConfiguration(identityP12URL: local, password: "", target: target, maxConcurrentClients: 0))
        XCTAssertThrowsError(try BridgeServerConfiguration(identityP12URL: local, password: "", target: target, requestTimeout: .infinity))
        XCTAssertThrowsError(try BridgeServerConfiguration(identityP12URL: local, password: "", target: target, maximumBodyBytes: Int.max))
    }
    func testMissingIdentityCannotStartOrLeakListener() throws {
        let configuration = try BridgeServerConfiguration(identityP12URL: URL(fileURLWithPath: "/nonexistent-synthetic-identity.p12"), password: "", target: TargetCoordinate(latitude: 0, longitude: 0))
        let server = LocationBridgeServer(configuration: configuration)
        XCTAssertThrowsError(try server.start())
        XCTAssertFalse(server.snapshot().listening)
        XCTAssertEqual(server.snapshot().activeConnections, 0)
        server.stop()
        server.stop()
    }
    func testSnapshotContainsCountsWithoutTargetOrIdentityMaterial() throws {
        let configuration = try BridgeServerConfiguration(identityP12URL: URL(fileURLWithPath: "/nonexistent-synthetic-identity.p12"), password: "synthetic-password", target: TargetCoordinate(latitude: 0, longitude: 0))
        let server = LocationBridgeServer(configuration: configuration)
        let data = try JSONEncoder().encode(server.snapshot())
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["latitude", "longitude", "target", "password", "identityP12URL", "requestBody"] { XCTAssertNil(snapshot[key]) }
        XCTAssertEqual(snapshot["syntheticResponses"] as? Int, 0)
    }
}
