// Derived from WLoc v1.2 (MIT); see ThirdParty/WLoc/PROVENANCE.md.
import Foundation

enum ARPCError: Error, LocalizedError {
    case truncated
    case invalidLength
    case invalidString
    case invalidVersion

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "Truncated ARPC data"
        case .invalidLength:
            return "Invalid ARPC length"
        case .invalidString:
            return "Invalid ARPC string"
        case .invalidVersion:
            return "Invalid ARPC version"
        }
    }
}

// WLoc request ARPC envelope, adapted from the MIT v1.2 source.
struct ARPCEnvelope {
    var version: String
    var locale: String
    var appIdentifier: String
    var osVersion: String
    var functionID: UInt32
    var payload: Data

    init(
        version: String,
        locale: String,
        appIdentifier: String,
        osVersion: String,
        functionID: UInt32,
        payload: Data
    ) {
        self.version = version
        self.locale = locale
        self.appIdentifier = appIdentifier
        self.osVersion = osVersion
        self.functionID = functionID
        self.payload = payload
    }

    init(data: Data) throws {
        var reader = ARPCDataReader(data: data)
        let version = try reader.readUInt16()
        let locale = try reader.readPascalString()
        let appIdentifier = try reader.readPascalString()
        let osVersion = try reader.readPascalString()
        let functionID = try reader.readUInt32()
        let payloadLength = Int(try reader.readUInt32())
        guard payloadLength <= reader.remainingCount else {
            throw ARPCError.invalidLength
        }
        let payload = try reader.readData(count: payloadLength)

        self.version = String(version)
        self.locale = locale
        self.appIdentifier = appIdentifier
        self.osVersion = osVersion
        self.functionID = functionID
        self.payload = payload
    }

    func serialize() throws -> Data {
        guard let versionNumber = UInt16(version) else {
            throw ARPCError.invalidVersion
        }
        var data = Data()
        data.appendUInt16BE(versionNumber)
        try data.appendPascalString(locale)
        try data.appendPascalString(appIdentifier)
        try data.appendPascalString(osVersion)
        data.appendUInt32BE(functionID)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

private struct ARPCDataReader {
    let data: Data
    var offset: Int = 0

    var remainingCount: Int {
        data.count - offset
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return (UInt32(bytes[0]) << 24) |
            (UInt32(bytes[1]) << 16) |
            (UInt32(bytes[2]) << 8) |
            UInt32(bytes[3])
    }

    mutating func readPascalString() throws -> String {
        let length = Int(try readUInt16())
        let bytes = try readData(count: length)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw ARPCError.invalidString
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw ARPCError.truncated
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    private mutating func readBytes(count: Int) throws -> [UInt8] {
        Array(try readData(count: count))
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendPascalString(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw ARPCError.invalidLength
        }
        appendUInt16BE(UInt16(bytes.count))
        append(bytes)
    }
}
