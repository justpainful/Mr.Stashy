import Foundation

/// A loosely typed JSON tree. Platform payloads change shape often and nest deeply; decoding
/// them into rigid structs meant one renamed field threw away the whole post. Walking a tree
/// and taking what is there is more robust, and is what the extractors do.
enum JSONValue: Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: raw)
    }

    static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    init(any: Any) {
        switch any {
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(any: $0) })
        case let list as [Any]:
            self = .array(list.map { JSONValue(any: $0) })
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            // JSONSerialization represents booleans as NSNumber; CFBoolean is the tell.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        default:
            self = .null
        }
    }

    subscript(key: String) -> JSONValue {
        if case .object(let dict) = self { return dict[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let list) = self, list.indices.contains(index) { return list[index] }
        return .null
    }

    /// Walks a dotted path; numeric components index arrays.
    func path(_ components: String...) -> JSONValue {
        components.reduce(self) { current, component in
            if let index = Int(component) { return current[index] }
            return current[component]
        }
    }

    var string: String? {
        switch self {
        case .string(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        default: nil
        }
    }

    var int: Int? {
        switch self {
        case .number(let number): Int(exactly: number.rounded())
        case .string(let text): Int(text)
        default: nil
        }
    }

    var int64: Int64? {
        switch self {
        case .number(let number): Int64(exactly: number.rounded())
        case .string(let text): Int64(text)
        default: nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let number): number != 0
        case .string(let text): text == "true" ? true : text == "false" ? false : nil
        default: nil
        }
    }

    var url: URL? {
        guard let text = string, !text.isEmpty else { return nil }
        return URL(string: HTMLText.decode(text).replacingOccurrences(of: "\\/", with: "/"))
    }

    var array: [JSONValue] {
        if case .array(let list) = self { return list }
        return []
    }

    var object: [String: JSONValue] {
        if case .object(let dict) = self { return dict }
        return [:]
    }

    var isNull: Bool { self == .null }
    var exists: Bool { self != .null }

    /// Depth-first search for the first object that has `key`. Used when a payload nests the
    /// interesting node at an unpredictable depth.
    func firstObject(containing key: String) -> JSONValue? {
        switch self {
        case .object(let dict):
            if dict[key] != nil { return self }
            for value in dict.values {
                if let found = value.firstObject(containing: key) { return found }
            }
        case .array(let list):
            for value in list {
                if let found = value.firstObject(containing: key) { return found }
            }
        default:
            break
        }
        return nil
    }

    /// Every object anywhere in the tree that has `key`, in document order.
    func allObjects(containing key: String) -> [JSONValue] {
        var found: [JSONValue] = []
        collect(containing: key, into: &found)
        return found
    }

    private func collect(containing key: String, into found: inout [JSONValue]) {
        switch self {
        case .object(let dict):
            if dict[key] != nil { found.append(self) }
            for value in dict.values { value.collect(containing: key, into: &found) }
        case .array(let list):
            for value in list { value.collect(containing: key, into: &found) }
        default:
            break
        }
    }
}
