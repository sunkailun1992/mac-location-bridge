// CONNECT and HTTP boundaries adapted from WLoc v1.2 (MIT).
// See ThirdParty/WLoc/PROVENANCE.md. No general-purpose upstream proxying.
import Foundation

let permittedLocationHosts: Set<String> = ["gs-loc.apple.com", "gs-loc-cn.apple.com"]

struct HTTPHeader {
    let startLine: String
    let fields: [String: String]
    static func parse(_ data: Data, limit: Int = 32_768) throws -> HTTPHeader {
        guard data.count <= limit else { throw BridgeError.requestTooLarge }
        guard let text = String(data: data, encoding: .ascii), text.hasSuffix("\r\n\r\n") else {
            throw BridgeError.malformedRequest
        }
        // CRLF is one Swift Character; trim the four framing bytes, not characters.
        guard let content = String(data: data.dropLast(4), encoding: .ascii) else { throw BridgeError.malformedRequest }
        let lines = content.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { throw BridgeError.malformedRequest }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t", let colon = line.firstIndex(of: ":") else {
                throw BridgeError.malformedRequest
            }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil else {
                throw BridgeError.malformedRequest
            }
            let key = name.lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil, value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw BridgeError.malformedRequest
            }
            fields[key] = value
        }
        return HTTPHeader(startLine: first, fields: fields)
    }
}

struct ConnectTarget: Equatable {
    let host: String
    let port: Int
    static func parse(_ data: Data, headerLimit: Int = 32_768) throws -> ConnectTarget {
        let header = try HTTPHeader.parse(data, limit: headerLimit)
        let parts = header.startLine.components(separatedBy: " ")
        guard parts.count == 3, parts[0] == "CONNECT", ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]) else {
            throw BridgeError.malformedRequest
        }
        let authority = parts[1].components(separatedBy: ":")
        guard authority.count == 2, authority[1] == "443", permittedLocationHosts.contains(authority[0].lowercased()) else {
            throw BridgeError.unsupportedTarget
        }
        guard header.fields["transfer-encoding"] == nil,
              header.fields["content-length"] == nil || header.fields["content-length"] == "0" else {
            throw BridgeError.malformedRequest
        }
        let target = ConnectTarget(host: authority[0].lowercased(), port: 443)
        if let host = header.fields["host"], ![target.host, target.host + ":443"].contains(host.lowercased()) {
            throw BridgeError.unsupportedTarget
        }
        return target
    }
}

struct LocationRequestHeader {
    let contentLength: Int
    static func parse(_ data: Data, connectHost: String, bodyLimit: Int, headerLimit: Int = 32_768) throws -> LocationRequestHeader {
        let header = try HTTPHeader.parse(data, limit: headerLimit)
        let parts = header.startLine.components(separatedBy: " ")
        guard parts.count == 3, parts[0] == "POST", ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]),
              parts[1] == "/clls/wloc" || parts[1].hasPrefix("/clls/wloc?") else {
            throw BridgeError.malformedRequest
        }
        guard permittedLocationHosts.contains(connectHost), let host = header.fields["host"],
              [connectHost, connectHost + ":443"].contains(host.lowercased()) else {
            throw BridgeError.unsupportedTarget
        }
        guard header.fields["transfer-encoding"] == nil, header.fields["expect"] == nil,
              header.fields["content-encoding"] == nil || header.fields["content-encoding"]?.lowercased() == "identity",
              let length = header.fields["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length), count > 0 else {
            throw BridgeError.malformedRequest
        }
        guard count <= bodyLimit else { throw BridgeError.requestTooLarge }
        return LocationRequestHeader(contentLength: count)
    }
}
