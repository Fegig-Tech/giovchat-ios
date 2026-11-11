import Foundation

// The protocol is parsed defensively (docs/protocol/README.md, "Versioning"): unknown fields are ignored and
// malformed values fall back instead of throwing. A small JSON model of its own keeps booleans and numbers
// apart on every platform (Foundation's JSONSerialization does not).

/// A JSON value.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The value as text; object keys are sorted so the output is stable.
    var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value):
            if value.isFinite, value == value.rounded(), abs(value) < 9.007199254740992e15 {
                out += String(Int64(value))
            } else if value.isFinite {
                out += String(value)
            } else {
                out += "null"
            }
        case .string(let value): JSONValue.writeString(value, to: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case .object(let map):
            out += "{"
            for (index, key) in map.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                JSONValue.writeString(key, to: &out)
                out += ":"
                map[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Parses `text`, or returns nil when it is not valid JSON.
    static func parse(_ text: String) -> JSONValue? {
        var parser = JSONParser(Array(text.utf8))
        return parser.document()
    }

    static func parse(_ data: Data) -> JSONValue? {
        var parser = JSONParser(Array(data))
        return parser.document()
    }

    // MARK: Lenient accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let map) = self { return map[key] }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let map) = self { return map }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}

extension Optional where Wrapped == JSONValue {
    /// The object, or an empty one.
    var object: [String: JSONValue] { self?.objectValue ?? [:] }

    var array: [JSONValue]? { self?.arrayValue }

    var string: String? {
        if case .string(let value)? = self { return value }
        return nil
    }

    /// A trimmed, non-empty string, or nil.
    var nonEmpty: String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// A finite JSON number, or nil.
    var number: Double? {
        if case .number(let value)? = self, value.isFinite { return value }
        return nil
    }

    /// A JSON number that fits an `Int` (fraction dropped), or nil. Never traps on a huge value from the network.
    var int: Int? { number.flatMap(safeInt) }

    var isTrue: Bool {
        if case .bool(true)? = self { return true }
        return false
    }

    var isFalse: Bool {
        if case .bool(false)? = self { return true }
        return false
    }

    /// `true` / `false` when the value is a JSON boolean, else nil.
    var bool: Bool? {
        if case .bool(let value)? = self { return value }
        return nil
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// Lookup that keeps the `Optional<JSONValue>` accessors usable: `map.at("title").string`.
    func at(_ key: String) -> JSONValue? { self[key] }
}

/// `value` as an `Int` (fraction dropped) when it is within +/- 2^53, else nil. `Int(Double)` traps outside the
/// `Int` range, so numbers from the network go through here.
func safeInt(_ value: Double) -> Int? {
    guard value.isFinite, abs(value) <= 9_007_199_254_740_992 else { return nil }
    return Int(value)
}

/// The object `text` holds, or an empty one when it is not valid JSON or not an object.
func parseJSONObject(_ text: String) -> [String: JSONValue] {
    JSONValue.parse(text)?.objectValue ?? [:]
}

func parseJSONObject(_ data: Data) -> [String: JSONValue] {
    JSONValue.parse(data)?.objectValue ?? [:]
}

private let httpURLPrefix = Pattern("^https?://", caseInsensitive: true)

/// An http(s) URL, or nil. Images and links from the network are used only when they pass.
func safeHTTPURL(_ value: String?) -> String? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return httpURLPrefix.matches(text) ? text : nil
}

func safeHTTPURL(_ value: JSONValue?) -> String? {
    safeHTTPURL(value.nonEmpty)
}

/// A strict RFC 8259 parser over UTF-8 bytes.
private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func document() -> JSONValue? {
        skipWhitespace()
        guard let value = value() else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func value() -> JSONValue? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map(JSONValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    private mutating func literal(_ word: String, _ value: JSONValue) -> JSONValue? {
        let utf8 = Array(word.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else { return nil }
        index += utf8.count
        return value
    }

    private mutating func object() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth < 512 else { return nil }
        index += 1
        var map: [String: JSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(map)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipWhitespace()
            guard let value = value() else { return nil }
            map[key] = value
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(map)
            }
            return nil
        }
    }

    private mutating func array() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth < 512 else { return nil }
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            guard let value = value() else { return nil }
            values.append(value)
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            return nil
        }
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func string() -> String? {
        index += 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flushRaw() -> Bool {
            if raw.isEmpty { return true }
            guard let text = String(bytes: raw, encoding: .utf8) else { return false }
            scalars.append(contentsOf: text.unicodeScalars)
            raw.removeAll(keepingCapacity: true)
            return true
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                guard flushRaw() else { return nil }
                return String(scalars)
            }
            if byte < 0x20 { return nil }
            if byte != UInt8(ascii: "\\") {
                raw.append(byte)
                index += 1
                continue
            }
            guard flushRaw() else { return nil }
            index += 1
            guard index < bytes.count else { return nil }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                guard let unit = hex4() else { return nil }
                if (0xD800...0xDBFF).contains(unit) {
                    // A high surrogate needs its low half; a lone half becomes U+FFFD, as in JavaScript text.
                    if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let save = index
                        index += 2
                        if let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                            let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                            scalars.append(Unicode.Scalar(combined)!)
                        } else {
                            index = save
                            scalars.append("\u{FFFD}")
                        }
                    } else {
                        scalars.append("\u{FFFD}")
                    }
                } else if (0xDC00...0xDFFF).contains(unit) {
                    scalars.append("\u{FFFD}")
                } else {
                    scalars.append(Unicode.Scalar(unit)!)
                }
            default:
                return nil
            }
        }
        return nil
    }

    private mutating func number() -> JSONValue? {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        func digits() -> Int {
            let from = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            return index - from
        }
        let intStart = index
        let intDigits = digits()
        guard intDigits > 0 else { return nil }
        if intDigits > 1, bytes[intStart] == UInt8(ascii: "0") { return nil }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { return nil }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { return nil }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { return nil }
        return .number(value)
    }
}
