import Foundation

struct CoordinateInput {
    let latitude: Double
    let longitude: Double

    static func parse(latitude: String, longitude: String) throws -> CoordinateInput {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw InputError.invalidCoordinates
        }
        return CoordinateInput(latitude: lat, longitude: lon)
    }

    enum InputError: LocalizedError {
        case invalidCoordinates

        var errorDescription: String? {
            "请输入有效的纬度（-90～90）和经度（-180～180），使用小数点。"
        }
    }
}

enum FreshLocationFilter {
    static func accepts(timestamp: Date, horizontalAccuracy: Double,
                        requestedAt: Date, now: Date = Date()) -> Bool {
        horizontalAccuracy.isFinite && horizontalAccuracy >= 0
            && timestamp >= requestedAt && timestamp <= now.addingTimeInterval(2)
    }
}
