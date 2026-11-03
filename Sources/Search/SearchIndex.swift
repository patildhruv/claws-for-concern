import Foundation

struct Hit: Identifiable {
    let session: Session
    let score: Float
    /// The transcript (`Session.key`), not the session ID: an ID filed under two project folders is two
    /// hits, and the list and the selection must tell them apart.
    var id: String { session.key }
}

/// The search box, parsed. Bare words are fuzzy terms that must all match (AND).
/// "Quoted words" must appear in that order, starting at a word boundary; the last word may be
/// unfinished, so results keep up while typing.
struct ParsedQuery {
    enum Mode { case fuzzy, exact, prefix }
    struct Term {
        let bytes: [UInt8]
        let text: String
        let mode: Mode
        let phrase: Int?        // index into `phrases` for words that came from one
    }
    private(set) var terms: [Term] = []
    private(set) var phrases: [String] = []
    var isEmpty: Bool { terms.isEmpty }

    init(_ raw: String) {
        var loose = ""
        var phrase: String?
        for ch in raw {
            if ch == "\"" || ch == "“" || ch == "”" {
                if let p = phrase { add(phrase: p); phrase = nil } else { phrase = "" }
            } else if phrase != nil {
                phrase!.append(ch)
            } else {
                loose.append(ch)
            }
        }
        if let p = phrase { add(phrase: p) }    // still typing the closing quote
        for t in Tokenizer.tokens(loose) { add(term: t, mode: .fuzzy, phrase: nil) }
    }

    private mutating func add(phrase p: String) {
        let trimmed = p.trimmingCharacters(in: .whitespaces)
        let words = Tokenizer.tokens(trimmed)
        guard !words.isEmpty else { return }
        // One quoted word means "this exact word, no fuzz".
        guard words.count > 1 || words[0] != trimmed.lowercased() else { add(term: words[0], mode: .exact, phrase: nil); return }
        phrases.append(trimmed)
        for (i, w) in words.enumerated() {
            add(term: w, mode: i == words.count - 1 ? .prefix : .exact, phrase: phrases.count - 1)
        }
    }

    private mutating func add(term: String, mode: Mode, phrase: Int?) {
        guard terms.count < 32,
              !terms.contains(where: { $0.text == term && $0.mode == mode && $0.phrase == phrase }) else { return }
        terms.append(Term(bytes: Array(term.utf8), text: term, mode: mode, phrase: phrase))
    }
}

struct SearchOutcome {
    let hits: [Hit]
    let query: ParsedQuery
    let scope: Scope
    /// For each query term, the indexed words it matched (exact, prefix, substring or typo).
    let termWords: [Set<String>]
    /// Words to highlight on their own: matches of terms that aren't part of a phrase.
    let looseWords: Set<String>
    let phrases: [PhraseMatcher]

    init(hits: [Hit], query: ParsedQuery, scope: Scope, termWords: [Set<String>]) {
        self.hits = hits
        self.query = query
        self.scope = scope
        self.termWords = termWords
        looseWords = zip(query.terms, termWords).reduce(into: Set<String>()) { acc, pair in
            if pair.0.phrase == nil { acc.formUnion(pair.1) }
        }
        phrases = query.phrases.map(PhraseMatcher.init)
    }

    /// Bit mask of the terms that came from phrase `p`.
    func phraseTerms(_ p: Int) -> UInt64 {
        query.terms.enumerated().reduce(0) { $1.element.phrase == p ? $0 | (1 << UInt64($1.offset)) : $0 }
    }
}

/// Finds a phrase in text: ASCII case-insensitive, a space in the phrase matches any run of spaces
/// or punctuation ("user agent" finds "user-agent"), and a match must start at a word boundary. Works on UTF-8 bytes, so it needs no
/// String bridging and stays fast across the whole corpus.
struct PhraseMatcher {
    private let units: [UInt8]      // lowercased, whitespace runs collapsed to one space

    init(_ phrase: String) {
        var u = [UInt8]()
        for b in phrase.utf8 {
            if Self.isSpace(b) {
                if let last = u.last, last != 0x20 { u.append(0x20) }
            } else {
                u.append(Self.fold(b))
            }
        }
        while u.last == 0x20 { u.removeLast() }
        units = u
    }

    func ranges(in text: String, first only: Bool = false) -> [Range<Int>] {
        guard let head = units.first else { return [] }
        var text = text
        return text.withUTF8 { t -> [Range<Int>] in
            var out = [Range<Int>]()
            let n = t.count
            let anchored = Self.isWordByte(head)
            var i = 0
            while i < n {
                if Self.fold(t[i]) == head && (!anchored || i == 0 || !Self.isASCIIWord(t[i - 1])), let end = match(t, at: i) {
                    out.append(i..<end)
                    if only { break }
                    i = end
                } else {
                    i += 1
                }
            }
            return out
        }
    }

    func occurs(in text: String) -> Bool { !ranges(in: text, first: true).isEmpty }

    private func match(_ t: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        var j = start
        for u in units {
            if u == 0x20 {
                guard j < t.count, Self.isSeparator(t[j]) else { return nil }
                while j < t.count && Self.isSeparator(t[j]) { j += 1 }
            } else {
                guard j < t.count, Self.fold(t[j]) == u else { return nil }
                j += 1
            }
        }
        return j
    }

    private static func fold(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b | 0x20 : b }
    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D }
    private static func isASCIIWord(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }
    private static func isWordByte(_ b: UInt8) -> Bool { isASCIIWord(b) || b >= 0x80 }
    private static func isSeparator(_ b: UInt8) -> Bool { b < 0x80 && !isASCIIWord(b) }
}

/// Inverted index over every session: word -> sessions containing it, with which parts (scope bits)
/// and how often. Immutable once built, so searches can run on any thread.
final class SearchIndex: @unchecked Sendable {
    struct Posting { let session: Int32; let mask: UInt8; let count: UInt32 }
    struct WordMatch { let word: Int; let score: Float }
    private struct Tally {
        var mask: UInt8 = 0
        var count: UInt32 = 0
        mutating func add(_ m: UInt8) { mask |= m; count &+= 1 }
    }

    let sessions: [Session]
    private(set) var vocab: [String] = []
    private var wordIDs: [String: Int] = [:]
    private var postings: [[Posting]] = []
    // All words back to back, for the fuzzy scan.
    private var wordBytes: [UInt8] = []
    private var wordStart: [Int32] = [0]
    private(set) var buildSeconds: Double = 0

    init(sessions: [Session]) {
        self.sessions = sessions
        let t0 = CFAbsoluteTimeGetCurrent()
        // Tokenise in parallel, merge serially, a chunk at a time to cap peak memory.
        let chunk = 48
        var lo = 0
        while lo < sessions.count {
            let base = lo
            let hi = min(lo + chunk, sessions.count)
            var tallies = [[String: Tally]](repeating: [:], count: hi - lo)
            tallies.withUnsafeMutableBufferPointer { buf in
                let out = buf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: hi - base) { k in out[k] = Self.tally(sessions[base + k]) }
            }
            for (k, words) in tallies.enumerated() {
                for (word, t) in words {
                    let id: Int
                    if let known = wordIDs[word] {
                        id = known
                    } else {
                        id = vocab.count
                        wordIDs[word] = id
                        vocab.append(word)
                        postings.append([])
                    }
                    postings[id].append(Posting(session: Int32(base + k), mask: t.mask, count: t.count))
                }
            }
            lo = hi
        }
        wordStart.reserveCapacity(vocab.count + 1)
        for w in vocab {
            wordBytes.append(contentsOf: w.utf8)
            wordStart.append(Int32(wordBytes.count))
        }
        buildSeconds = CFAbsoluteTimeGetCurrent() - t0
    }

    private static func tally(_ s: Session) -> [String: Tally] {
        var words = [String: Tally]()
        func add(_ text: String, _ mask: UInt8) {
            Tokenizer.scan(text) { tok, _ in
                words[String(decoding: tok, as: UTF8.self), default: Tally()].add(mask)
            }
        }
        add(s.metaText, Scope.meta.rawValue)
        for m in s.messages { add(m.text, m.scope.rawValue) }
        return words
    }

    func documentFrequency(_ word: String) -> Int { wordIDs[word].map { postings[$0].count } ?? 0 }

    // MARK: Search

    /// `ranks` are the usage figures Cost and Context sort by (`UsageRank`), keyed by session ID.
    func search(_ q: ParsedQuery, scope: Scope, sort: SortMode, ranks: [String: UsageRank] = [:],
                cancelled: () -> Bool) -> SearchOutcome? {
        let n = sessions.count
        guard !q.isEmpty else {
            var hits = sessions.sorted { $0.modified > $1.modified }.map { Hit(session: $0, score: 0) }
            if sort.usesFigures { UsageRank.order(&hits, by: sort, ranks: ranks) }
            return SearchOutcome(hits: hits, query: q, scope: scope, termWords: [])
        }
        let allowed = scope.union(.meta).rawValue
        var total = [Float](repeating: 0, count: n)
        var alive = [Bool](repeating: true, count: n)
        var termWords = [Set<String>]()

        for term in q.terms {
            if cancelled() { return nil }
            var best = [Float](repeating: 0, count: n)
            var words = Set<String>()
            for m in matchWords(term) {
                var used = false
                for p in postings[m.word] where p.mask & allowed != 0 {
                    // Diminishing credit for repetition; a hit in the name, folder or id counts extra.
                    var s = m.score * (1 + 0.15 * log2(Float(p.count)))
                    if p.mask & Scope.meta.rawValue != 0 { s *= 1.6 }
                    let i = Int(p.session)
                    if s > best[i] { best[i] = s }
                    used = true
                }
                if used { words.insert(vocab[m.word]) }
            }
            termWords.append(words)
            for i in 0..<n {
                if best[i] == 0 { alive[i] = false } else { total[i] += best[i] }
            }
        }

        var survivors = (0..<n).filter { alive[$0] }
        if !q.phrases.isEmpty {
            let matchers = q.phrases.map(PhraseMatcher.init)
            let candidates = survivors
            var keep = [Bool](repeating: false, count: candidates.count)
            keep.withUnsafeMutableBufferPointer { buf in
                let dst = buf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: candidates.count) { k in
                    dst[k] = matchers.allSatisfy { Self.contains(sessions[candidates[k]], $0, scope: scope) }
                }
            }
            if cancelled() { return nil }
            survivors = candidates.indices.filter { keep[$0] }.map { candidates[$0] }
        }

        let now = Date()
        var hits = survivors.map { i -> Hit in
            let days = now.timeIntervalSince(sessions[i].modified) / 86_400
            let recency = Float(max(0, 1 - days / 90)) * 0.1     // a nudge between otherwise equal matches
            return Hit(session: sessions[i], score: total[i] + recency)
        }
        switch sort {
        case .relevance:
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.session.modified > $1.session.modified }
        case .recent:
            hits.sort { $0.session.modified > $1.session.modified }
        case .cost, .context:
            UsageRank.order(&hits, by: sort, ranks: ranks)
        }
        return SearchOutcome(hits: hits, query: q, scope: scope, termWords: termWords)
    }

    private static func contains(_ s: Session, _ phrase: PhraseMatcher, scope: Scope) -> Bool {
        phrase.occurs(in: s.metaText) || s.messages.contains { !scope.isDisjoint(with: $0.scope) && phrase.occurs(in: $0.text) }
    }

    /// Indexed words matching a term. Exact 1.0; prefix 0.6–0.9 (closer to 0.9 the more of the word
    /// is typed); one typo 0.7; substring 0.5; two typos 0.45. Typos are allowed from 4 letters (one)
    /// and 8 letters (two); a swap of neighbouring letters counts as one.
    func matchWords(_ term: ParsedQuery.Term) -> [WordMatch] {
        if term.mode == .exact { return wordIDs[term.text].map { [WordMatch(word: $0, score: 1)] } ?? [] }
        let fuzzy = term.mode == .fuzzy
        let tl = term.bytes.count
        let k = !fuzzy ? 0 : tl >= 8 ? 2 : tl >= 4 ? 1 : 0
        var out = [WordMatch]()
        wordBytes.withUnsafeBufferPointer { vb in
            term.bytes.withUnsafeBufferPointer { tb in
                guard let vbase = vb.baseAddress, let t = tb.baseAddress else { return }
                for w in 0..<vocab.count {
                    let s = Int(wordStart[w])
                    let wl = Int(wordStart[w + 1]) - s
                    let wp = vbase + s
                    if wl == tl && memcmp(wp, t, tl) == 0 {
                        out.append(WordMatch(word: w, score: 1)); continue
                    }
                    if wl > tl {
                        if memcmp(wp, t, tl) == 0 {
                            out.append(WordMatch(word: w, score: 0.6 + 0.3 * Float(tl) / Float(wl))); continue
                        }
                        if fuzzy && tl >= 3 && memmem(wp, wl, t, tl) != nil {
                            out.append(WordMatch(word: w, score: 0.5)); continue
                        }
                    }
                    if k > 0 && abs(wl - tl) <= k, let d = Self.editDistance(t, tl, wp, wl, max: k), d > 0 {
                        out.append(WordMatch(word: w, score: d == 1 ? 0.7 : 0.45))
                    }
                }
            }
        }
        return out
    }

    /// Optimal-string-alignment distance (Levenshtein plus adjacent swaps), or nil if above `k`.
    static func editDistance(_ a: UnsafePointer<UInt8>, _ n: Int, _ b: UnsafePointer<UInt8>, _ m: Int, max k: Int) -> Int? {
        if abs(n - m) > k { return nil }
        if n == 0 || m == 0 { return max(n, m) <= k ? max(n, m) : nil }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (m + 1)) { buf -> Int? in
            var twoUp = buf.baseAddress!
            var up = twoUp + (m + 1)
            var row = up + (m + 1)
            for j in 0...m { up[j] = j }
            for i in 1...n {
                row[0] = i
                var rowMin = i
                for j in 1...m {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    var v = Swift.min(up[j] + 1, row[j - 1] + 1, up[j - 1] + cost)
                    if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                        v = Swift.min(v, twoUp[j - 2] + 1)
                    }
                    row[j] = v
                    if v < rowMin { rowMin = v }
                }
                if rowMin > k { return nil }
                (twoUp, up, row) = (up, row, twoUp)
            }
            return up[m] <= k ? up[m] : nil
        }
    }
}
