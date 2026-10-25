import Foundation

/// A JSON value that keeps object key order and the original number text, so editing
/// ~/.claude/settings.json changes only the keys we touch. `serialized()` reproduces
/// JavaScript's `JSON.stringify(value, null, 2)`, which is how Claude Code writes that file.
indirect enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }
        set {
            guard case var .object(pairs) = self else { return }
            if let i = pairs.firstIndex(where: { $0.0 == key }) {
                if let newValue { pairs[i].1 = newValue } else { pairs.remove(at: i) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
            self = .object(pairs)
        }
    }

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }

    // MARK: Serialising

    func serialized(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case let .object(pairs):
            if pairs.isEmpty { return "{}" }
            let body = pairs.map { "\(inner)\(JSONValue.quote($0.0)): \($0.1.serialized(indent: inner))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(indent)}"
        case let .array(items):
            if items.isEmpty { return "[]" }
            let body = items.map { inner + $0.serialized(indent: inner) }
            return "[\n" + body.joined(separator: ",\n") + "\n\(indent)]"
        case let .string(s): return JSONValue.quote(s)
        case let .number(n): return n
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    struct ParseError: Error, CustomStringConvertible {
        let offset: Int; let reason: String
        var description: String { "JSON parse error at byte \(offset): \(reason)" }
    }

    static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i, reason: "trailing characters") }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        func fail(_ r: String) -> ParseError { ParseError(offset: i, reason: r) }

        mutating func value() throws -> JSONValue {
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("expected \(word)") }
            i += w.count
        }

        mutating func number() throws -> JSONValue {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .utf8),
                  Double(s) != nil else { throw fail("bad number") }
            return .number(s)
        }

        mutating func object() throws -> JSONValue {
            i += 1; skipWS()
            var pairs: [(String, JSONValue)] = []
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let k = try string()
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
                i += 1; skipWS()
                pairs.append((k, try value()))
                skipWS()
                guard i < bytes.count else { throw fail("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw fail("expected , or }")
            }
        }

        mutating func array() throws -> JSONValue {
            i += 1; skipWS()
            var items: [JSONValue] = []
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < bytes.count else { throw fail("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { throw fail("bad \\u escape") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw fail("bad escape") }
                let e = bytes[i]; i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var v = try hex4()
                    if (0xD800...0xDBFF).contains(v), i + 6 <= bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let lo = try hex4()
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(v).map(Character.init) ?? "\u{FFFD}").utf8))
                default: throw fail("bad escape")
                }
            }
            guard let s = String(bytes: out, encoding: .utf8) else { throw fail("invalid UTF-8") }
            return s
        }
    }
}
