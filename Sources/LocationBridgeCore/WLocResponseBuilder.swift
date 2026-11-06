// Derived from AppWLocMutator.swift, WLoc v1.2 (MIT).
// See ThirdParty/WLoc/PROVENANCE.md.
import Foundation
import SwiftProtobuf

struct WLocResponseBuilder {
    static let responsePrefix = Data([0, 1, 0, 0, 0, 1, 0, 0])
    static func build(requestBody: Data, target: TargetCoordinate) throws -> Data {
        guard !requestBody.isEmpty, requestBody.count <= 1_048_576 else { throw BridgeError.unsupportedPayload }
        let envelope = try ARPCEnvelope(data: requestBody)
        var message = try WLocModel(serializedBytes: envelope.payload)
        guard !message.wifiDevices.isEmpty else { throw BridgeError.unsupportedPayload }
        var location = WLocLocation()
        location.latitude = Int64((target.latitude * 100_000_000).rounded())
        location.longitude = Int64((target.longitude * 100_000_000).rounded())
        location.horizontalAccuracy = Int64(target.horizontalAccuracy.rounded())
        location.verticalAccuracy = Int64(target.verticalAccuracy.rounded())
        location.altitude = Int64(target.altitude.rounded())
        location.unknownValue4 = 3
        location.motionActivityType = 63
        location.motionActivityConfidence = 467
        for index in message.wifiDevices.indices { message.wifiDevices[index].location = location }
        message.numCellResults = nil
        message.numWifiResults = nil
        message.deviceType = nil
        let protobuf = try message.serializedData()
        guard protobuf.count <= Int(UInt16.max) else { throw BridgeError.requestTooLarge }
        var response = responsePrefix
        response.append(UInt8((protobuf.count >> 8) & 255))
        response.append(UInt8(protobuf.count & 255))
        response.append(protobuf)
        return response
    }
}
