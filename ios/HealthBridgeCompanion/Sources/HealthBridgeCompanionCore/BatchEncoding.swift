import Foundation

public struct HealthBridgeBatchEncoder {
    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func encode(_ batch: HealthBridgeBatchV1) throws -> Data {
        try encoder.encode(batch)
    }
}

public enum HealthBridgeUTCFormatter {
    public static func string(from date: Date) -> String {
        let wholeSecondDate = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: wholeSecondDate)
    }

    public static func date(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.date(from: string)
    }
}
