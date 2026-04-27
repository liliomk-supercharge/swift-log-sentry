import Logging

/// Converts `Logger.Metadata` to a JSON-friendly representation that preserves
/// nested structure (dictionaries and arrays stay nested rather than being
/// stringified). The result is suitable for `Breadcrumb.data` and `SentryScope.setExtras`.
enum MetadataConversion {
    static func toAny(_ metadata: Logger.Metadata) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        result.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            result[key] = unwrap(value)
        }
        return result
    }

    private static func unwrap(_ value: Logger.Metadata.Value) -> any Sendable {
        switch value {
        case .string(let s):
            return s
        case .stringConvertible(let c):
            return c.description
        case .array(let arr):
            return arr.map(unwrap)
        case .dictionary(let dict):
            return toAny(dict)
        }
    }
}
