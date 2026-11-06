import CFNetwork
import Darwin
import Foundation
import SwiftProtobuf
import XCTest
@testable import LocationBridgeCore

final class ResponseAndSocketTests: XCTestCase {
    func testSyntheticResponseUsesValidatedTargetAndPreservesUnknownWireFields() throws {
        var wifi = WLocWifiDevice()
        wifi.bssid = "synthetic-radio"
        var message = WLocModel()
        message.wifiDevices = [wifi]
        message.numCellResults = 2
        message.numWifiResults = 3
        var payload = try message.serializedData()
        payload.append(contentsOf: [0xA0, 0x06, 0x07]) // Unknown field 100, integer 7.
        let envelope = ARPCEnvelope(version: "1", locale: "test", appIdentifier: "test.invalid", osVersion: "test", functionID: 1, payload: payload)
        let target = try TargetCoordinate(latitude: 10, longitude: 20, horizontalAccuracy: 15, altitude: 25)
        let response = try WLocResponseBuilder.build(requestBody: envelope.serialize(), target: target)
        XCTAssertEqual(Array(response.prefix(8)), [0, 1, 0, 0, 0, 1, 0, 0])
        XCTAssertEqual((Int(response[8]) << 8) | Int(response[9]), response.count - 10)
        let decoded = try WLocModel(serializedBytes: response.dropFirst(10))
        XCTAssertEqual(decoded.wifiDevices.count, 1)
        XCTAssertEqual(decoded.wifiDevices[0].bssid, "synthetic-radio")
        XCTAssertEqual(decoded.wifiDevices[0].location?.latitude, 1_000_000_000)
        XCTAssertEqual(decoded.wifiDevices[0].location?.longitude, 2_000_000_000)
        XCTAssertEqual(decoded.wifiDevices[0].location?.horizontalAccuracy, 15)
        XCTAssertNil(decoded.numCellResults)
        XCTAssertNil(decoded.numWifiResults)
        XCTAssertTrue(try decoded.serializedData().suffix(3).elementsEqual([0xA0, 0x06, 0x07]))
    }

    func testMalformedOrEmptyWiFiPayloadRejected() throws {
        let target = try TargetCoordinate(latitude: 0, longitude: 0)
        for body in [Data(), Data([0]), Data(repeating: 255, count: 20)] {
            XCTAssertThrowsError(try WLocResponseBuilder.build(requestBody: body, target: target))
        }
        let envelope = ARPCEnvelope(version: "1", locale: "test", appIdentifier: "test.invalid", osVersion: "test", functionID: 1, payload: Data())
        XCTAssertThrowsError(try WLocResponseBuilder.build(requestBody: envelope.serialize(), target: target))
    }

    func testRepeatedCloseDoesNotCloseDescriptorReusedByUnrelatedFile() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let oldFD = pair[0]
        defer { Darwin.close(pair[1]) }
        let owner = SocketHandle(oldFD)
        owner.close()
        let logger = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? logger.close() }
        XCTAssertEqual(logger.fileDescriptor, oldFD, "fixture must naturally reuse the released descriptor")
        owner.close()
        owner.shutdown()
        XCTAssertNotEqual(fcntl(logger.fileDescriptor, F_GETFD), -1)
        XCTAssertNoThrow(try logger.write(contentsOf: Data("synthetic-marker".utf8)))
    }

    func testBorrowedCFStreamsLeaveNativeSocketForItsSoleOwner() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let owner = SocketHandle(pair[0])
        defer { owner.close(); Darwin.close(pair[1]) }
        try autoreleasepool {
            var inputRef: Unmanaged<CFReadStream>?
            var outputRef: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocket(nil, owner.descriptor, &inputRef, &outputRef)
            let input = try XCTUnwrap(inputRef?.takeRetainedValue())
            let output = try XCTUnwrap(outputRef?.takeRetainedValue())
            let key = CFStreamPropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket)
            XCTAssertTrue(CFReadStreamSetProperty(input, key, kCFBooleanFalse))
            XCTAssertTrue(CFWriteStreamSetProperty(output, key, kCFBooleanFalse))
            XCTAssertTrue(CFReadStreamOpen(input))
            CFReadStreamClose(input)
            CFWriteStreamClose(output)
        }
        XCTAssertNotEqual(fcntl(owner.descriptor, F_GETFD), -1)
        owner.close()
        XCTAssertEqual(owner.descriptor, -1)
    }
}
