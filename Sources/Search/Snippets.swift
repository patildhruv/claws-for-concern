import SwiftUI

struct Excerpt: Identifiable {
    let id: Int             // message index within the session
    let kind: Message.Kind
    let subagent: Bool
    let date: Date?
    let text: AttributedString
}

/// Turns search hits into readable excerpts with the matched words highlighted.
enum Snippets {
    /// Which query terms appear in `text` (bit per term) and the byte ranges to highlight:
    /// loose words on their own, phrases as a whole.
    static func scan(_ text: String, _ out: SearchOutcome) -> (terms: UInt64, ranges: [Range<Int>]) {
        var terms: UInt64 = 0
        var ranges = [Range<Int>]()
        if !out.looseWords.isEmpty {
            Tokenizer.scan(text) { tok, range in
                let word = String(decoding: tok, as: UTF8.self)
                guard out.looseWords.contains(word) else { return }
                for (t, words) in out.termWords.enumerated() where out.query.terms[t].phrase == nil && words.contains(word) {
                    terms |= 1 << UInt64(t)
                }
                ranges.append(range)
            }
        }
        for (p, phrase) in out.phrases.enumerated() {
            let found = phrase.ranges(in: text)
            if !found.isEmpty {
                terms |= out.phraseTerms(p)
                ranges += found
            }
        }
        if !out.phrases.isEmpty { ranges.sort { $0.lowerBound < $1.lowerBound } }
        return (terms, ranges)
    }

    /// The one-line preview under a result: the first message that matches the most terms.
    static func row(_ s: Session, _ out: SearchOutcome) -> AttributedString? {
        if out.query.isEmpty { return s.firstPrompt.map { AttributedString($0) } }
        let all = out.termWords.count
        var best: (index: Int, hits: Int, ranges: [Range<Int>])?
        for (i, m) in s.messages.enumerated() where !out.scope.isDisjoint(with: m.scope) {
            let r = scan(m.text, out)
            let hits = r.terms.nonzeroBitCount
            guard hits > 0 else { continue }
            if hits > (best?.hits ?? 0) { best = (i, hits, r.ranges) }
            if hits == all { break }
        }
        guard let best else { return nil }
        return excerpt(s.messages[best.index].text, ranges: best.ranges, before: 50, after: 240)
    }

    /// Row previews for several hits, computed in parallel.
    static func rows(_ hits: [Hit], _ out: SearchOutcome) -> [String: AttributedString] {
        var previews = [AttributedString?](repeating: nil, count: hits.count)
        previews.withUnsafeMutableBufferPointer { buf in
            let dst = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: hits.count) { i in dst[i] = row(hits[i].session, out) }
        }
        var map = [String: AttributedString]()
        for (i, hit) in hits.enumerated() { if let p = previews[i] { map[hit.id] = p } }
        return map
    }

    /// Every matching message in a session (or, with no query, the user's prompts).
    static func list(_ s: Session, _ out: SearchOutcome?, limit: Int) -> (items: [Excerpt], total: Int) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var items = [Excerpt]()
        var total = 0
        for (i, m) in s.messages.enumerated() {
            let text: AttributedString
            if let out, !out.query.isEmpty {
                guard !out.scope.isDisjoint(with: m.scope) else { continue }
                let r = scan(m.text, out)
                guard r.terms != 0 else { continue }
                total += 1
                guard items.count < limit else { continue }
                text = excerpt(m.text, ranges: r.ranges, before: 140, after: 520)
            } else {
                guard m.kind == .prompt, !m.subagent, let shown = Prompts.display(m.text, limit: 600) else { continue }
                total += 1
                guard items.count < limit else { continue }
                text = AttributedString(shown)
            }
            items.append(Excerpt(id: i, kind: m.kind, subagent: m.subagent,
                                 date: m.timestamp.flatMap(iso.date(from:)), text: text))
        }
        return (items, total)
    }

    /// A window of `text` starting a little before the first match, whitespace collapsed,
    /// with every match inside the window highlighted.
    static func excerpt(_ text: String, ranges: [Range<Int>], before: Int, after: Int) -> AttributedString {
        var text = text
        return text.withUTF8 { buf -> AttributedString in
            let n = buf.count
            guard let first = ranges.first else { return AttributedString() }
            var lo = max(0, first.lowerBound - before)
            var hi = min(n, first.lowerBound + after)
            while lo < first.lowerBound && buf[lo] & 0xC0 == 0x80 { lo += 1 }
            while hi < n && buf[hi] & 0xC0 == 0x80 { hi += 1 }
            if lo > 0, let space = (lo..<first.lowerBound).first(where: { buf[$0] == 0x20 || buf[$0] == 0x0A }) {
                lo = space + 1      // don't open on half a word
            }
            func piece(_ r: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: buf[r]), as: UTF8.self) }

            var b = Builder()
            if lo > 0 { b.add("… ", marked: false) }
            var pos = lo
            for r in ranges where r.lowerBound >= pos && r.upperBound <= hi {
                b.add(piece(pos..<r.lowerBound), marked: false)
                b.add(piece(r), marked: true)
                pos = r.upperBound
            }
            b.add(piece(pos..<hi), marked: false)
            if hi < n { b.add(" …", marked: false) }
            return b.result
        }
    }

    private struct Builder {
        var result = AttributedString()
        var lastWasSpace = true

        mutating func add(_ s: String, marked: Bool) {
            var plain = ""
            plain.reserveCapacity(s.utf8.count)
            for ch in s {
                if ch.isWhitespace {
                    if !lastWasSpace { plain.append(" "); lastWasSpace = true }
                } else {
                    plain.append(ch)
                    lastWasSpace = false
                }
            }
            guard !plain.isEmpty else { return }
            var a = AttributedString(plain)
            if marked {
                a.backgroundColor = Color.yellow.opacity(0.35)
                a.foregroundColor = Color.primary
                a.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(a)
        }
    }

    /// Plain text for the terminal; matches in bold yellow when `ansi`.
    static func terminal(_ a: AttributedString, ansi: Bool) -> String {
        var s = ""
        for run in a.runs {
            let piece = String(a[run.range].characters)
            s += ansi && run.inlinePresentationIntent != nil ? "\u{1B}[1;33m\(piece)\u{1B}[0m" : piece
        }
        return s
    }
}
