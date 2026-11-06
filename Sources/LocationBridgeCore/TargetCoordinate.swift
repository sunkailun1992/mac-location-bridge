import Foundation

public enum BridgeError: Error, LocalizedError {
    case invalidCoordinate, invalidConfiguration, malformedRequest, unsupportedTarget
    case identityUnavailable, socketFailure, alreadyRunning, requestTooLarge, unsupportedPayload
    public var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return "Invalid target coordinate or accuracy."
        case .invalidConfiguration: return "Invalid bridge configuration."
        case .malformedRequest: return "Malformed proxy or HTTP request."
        case .unsupportedTarget: return "Only the two Apple location hosts on port 443 are supported."
        case .identityUnavailable: return "A usable caller-provided TLS identity is required."
        case .socketFailure: return "The local socket operation failed."
        case .alreadyRunning: return "The bridge is already running."
        case .requestTooLarge: return "The request exceeds the configured limit."
        case .unsupportedPayload: return "The location payload is unsupported."
        }
    }
}

public struct TargetCoordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let altitude: Double
    public let verticalAccuracy: Double
    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double = 10,
                altitude: Double = 0, verticalAccuracy: Double = 10) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude), altitude.isFinite,
              (-12_000...1_000_000).contains(altitude), horizontalAccuracy.isFinite,
              verticalAccuracy.isFinite, (0...1_000_000).contains(horizontalAccuracy),
              (0...1_000_000).contains(verticalAccuracy), horizontalAccuracy > 0,
              verticalAccuracy > 0 else { throw BridgeError.invalidCoordinate }
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
    }
}
