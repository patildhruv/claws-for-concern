import Foundation

/// Splits text into lowercased word tokens: runs of letters, digits and combining marks.
/// Everything else (punctuation, underscores, em dashes, smart quotes, emoji) separates words,
/// so "web_scrape.cjs" is three words and Devanagari words keep their vowel signs.
enum Tokenizer {
    static let minBytes = 2
    static let maxBytes = 40    // longer runs are hashes, base64 and the like

    /// Calls `body` with each token's lowercased UTF-8 bytes and its byte range in `text`.
    static func scan(_ text: String, _ body: (UnsafeBufferPointer<UInt8>, Range<Int>) -> Void) {
        var text = text
        text.withUTF8 { scan(bytes: $0, body) }
    }

    static func scan(bytes buf: UnsafeBufferPointer<UInt8>, _ body: (UnsafeBufferPointer<UInt8>, Range<Int>) -> Void) {
        var token = [UInt8]()
        token.reserveCapacity(64)
        var start = -1
        let n = buf.count
        var i = 0

        func flush(_ end: Int) {
            if token.count >= minBytes && token.count <= maxBytes {
                token.withUnsafeBufferPointer { body($0, start..<end) }
            }
            token.removeAll(keepingCapacity: true)
            start = -1
        }

        while i < n {
            let b = buf[i]
            if b < 0x80 {
                if (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) {
                    if start < 0 { start = i }
                    token.append(b)
                } else if b >= 0x41 && b <= 0x5A {
                    if start < 0 { start = i }
                    token.append(b | 0x20)
                } else if start >= 0 {
                    flush(i)
                }
                i += 1
                continue
            }
            let (scalar, len) = decode(buf, at: i)
            if let scalar, isWordScalar(scalar) {
                if start < 0 { start = i }
                let p = scalar.properties
                if p.changesWhenLowercased {
                    token.append(contentsOf: p.lowercaseMapping.utf8)
                } else {
                    token.append(contentsOf: UnsafeBufferPointer(rebasing: buf[i..<i + len]))
                }
            } else if start >= 0 {
                flush(i)
            }
            i += len
        }
        if start >= 0 { flush(n) }
    }

    /// Decodes the multi-byte UTF-8 sequence at `i`. Malformed input yields (nil, 1).
    static func decode(_ buf: UnsafeBufferPointer<UInt8>, at i: Int) -> (Unicode.Scalar?, Int) {
        let b = buf[i]
        var len = 0
        var v: UInt32 = 0
        if b & 0xE0 == 0xC0 { len = 2; v = UInt32(b & 0x1F) }
        else if b & 0xF0 == 0xE0 { len = 3; v = UInt32(b & 0x0F) }
        else if b & 0xF8 == 0xF0 { len = 4; v = UInt32(b & 0x07) }
        else { return (nil, 1) }
        guard i + len <= buf.count else { return (nil, 1) }
        for k in 1..<len {
            let c = buf[i + k]
            guard c & 0xC0 == 0x80 else { return (nil, 1) }
            v = (v << 6) | UInt32(c & 0x3F)
        }
        return (Unicode.Scalar(v), len)
    }

    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        let p = s.properties
        if p.isAlphabetic { return true }
        switch p.generalCategory {
        case .decimalNumber, .letterNumber, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    static func tokens(_ text: String) -> [String] {
        var out = [String]()
        scan(text) { tok, _ in out.append(String(decoding: tok, as: UTF8.self)) }
        return out
    }
}
