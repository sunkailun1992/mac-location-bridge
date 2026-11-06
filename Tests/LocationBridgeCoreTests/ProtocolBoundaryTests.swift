import Foundation
import XCTest
@testable import LocationBridgeCore

final class ProtocolBoundaryTests: XCTestCase {
    func testConnectRejectsUnknownHostAndPort() {
        for authority in ["example.invalid:443", "gs-loc.apple.com:80", "gs-loc.apple.com", "gs-loc.apple.com:invalid"] {
            XCTAssertThrowsError(try ConnectTarget.parse(Data("CONNECT \(authority) HTTP/1.1\r\n\r\n".utf8)), authority)
        }
    }
    func testConnectRejectsMalformedHeader() {
        for text in ["CONNECT gs-loc.apple.com:443", "CONNECT gs-loc.apple.com:443 HTTP/1.1\r\nBadHeader\r\n\r\n", "CONNECT gs-loc.apple.com:443 HTTP/1.1\r\n\r\nextra"] {
            XCTAssertThrowsError(try ConnectTarget.parse(Data(text.utf8)))
        }
    }
    func testCoordinateRejectsNonFiniteAndOutOfRangeValues() {
        for pair in [(Double.nan, 0.0), (0.0, Double.infinity), (90.1, 0.0), (0.0, -180.1)] {
            XCTAssertThrowsError(try TargetCoordinate(latitude: pair.0, longitude: pair.1))
        }
        XCTAssertThrowsError(try TargetCoordinate(latitude: 0, longitude: 0, horizontalAccuracy: -1))
    }
}

final class HTTPRequestBoundaryTests: XCTestCase {
    private func parse(_ extra: String, length: String = "12", path: String = "/clls/wloc") throws -> LocationRequestHeader {
        try LocationRequestHeader.parse(Data("POST \(path) HTTP/1.1\r\nHost: gs-loc.apple.com\r\nContent-Length: \(length)\r\n\(extra)\r\n".utf8), connectHost: "gs-loc.apple.com", bodyLimit: 128)
    }
    func testValidLocationRequestAccepted() throws { XCTAssertEqual(try parse("").contentLength, 12) }
    func testUnknownPathAndAmbiguousFramingRejected() {
        XCTAssertThrowsError(try parse("", path: "/other"))
        XCTAssertThrowsError(try parse("Transfer-Encoding: chunked\r\n"))
        XCTAssertThrowsError(try parse("Content-Length: 12\r\n"))
        XCTAssertThrowsError(try parse("", length: "-1"))
        XCTAssertThrowsError(try parse("", length: "129"))
        XCTAssertThrowsError(try parse("Host: example.invalid\r\n"))
    }
    func testBothExactConnectHostsAccepted() throws {
        for host in ["gs-loc.apple.com", "gs-loc-cn.apple.com"] {
            XCTAssertEqual(try ConnectTarget.parse(Data("CONNECT \(host):443 HTTP/1.1\r\n\r\n".utf8)).host, host)
        }
    }
}
