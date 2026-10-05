import Foundation

/// A source file as the agent just wrote it.
public struct SourceFile: Hashable, Sendable {
    public let path: String
    public let text: String
    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// One place where a deterministic check fired.
public struct Finding: Hashable, Sendable, Identifiable {
    public let conventionID: String
    public let path: String
    public let line: Int
    public let column: Int
    public let excerpt: String
    public var id: String { "\(conventionID):\(path):\(line):\(column)" }
}

/// A lint-rung check: a pure function of one file's text.
/// It only ever sees *masked* source, so comments and string contents can't fire it.
public protocol LintRule: Sendable {
    /// Byte offsets (into the masked source) where the rule fires.
    func offsets(inMasked bytes: [UInt8]) -> [Int]
}

enum Bytes {
    static func isIdentifier(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) ||
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ||
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
        byte == UInt8(ascii: "_")
    }
    static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }
    /// The identifier that ends right before `end` (exclusive), if any.
    static func identifier(endingAt end: Int, in bytes: [UInt8]) -> (word: String, start: Int)? {
        var start = end
        while start > 0, isIdentifier(bytes[start - 1]) { start -= 1 }
        guard start < end else { return nil }
        return (String(decoding: bytes[start..<end], as: UTF8.self), start)
    }
    /// The previous identifier before `index`, skipping spaces.
    static func previousWord(before index: Int, in bytes: [UInt8]) -> String? {
        var end = index
        while end > 0, isSpace(bytes[end - 1]) { end -= 1 }
        return identifier(endingAt: end, in: bytes)?.word
    }
    /// Offsets where `word` appears as a whole identifier.
    static func occurrences(of word: String, in bytes: [UInt8]) -> [Int] {
        let needle = Array(word.utf8)
        guard !needle.isEmpty, bytes.count >= needle.count else { return [] }
        var hits: [Int] = []
        var i = 0
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle {
                let before = i > 0 ? bytes[i - 1] : UInt8(ascii: " ")
                let afterIndex = i + needle.count
                let after = afterIndex < bytes.count ? bytes[afterIndex] : UInt8(ascii: " ")
                if !isIdentifier(before), !isIdentifier(after) { hits.append(i) }
                i += needle.count
            } else {
                i += 1
            }
        }
        return hits
    }
    /// Index of the first non-space byte at or after `index`.
    static func skipSpaces(from index: Int, in bytes: [UInt8]) -> Int {
        var i = index
        while i < bytes.count, isSpace(bytes[i]) { i += 1 }
        return i
    }
}

/// "Never sleep in tests." Fires on calls to `sleep`, `usleep`, `Thread.sleep`
/// and `Task.sleep`. A *declaration* named `sleep` (`func sleep(`) does not fire.
///
/// Known blind spot, on purpose: waiting on wall-clock time some other way
/// (`DispatchQueue.main.asyncAfter`, a polling loop) is not a call to `sleep`.
/// "Wait on state, not time" is the judgment behind the rule; that part stays prose.
public struct NoSleepInTests: LintRule {
    public init() {}
    public func offsets(inMasked bytes: [UInt8]) -> [Int] {
        var hits: [Int] = []
        for word in ["sleep", "usleep"] {
            for offset in Bytes.occurrences(of: word, in: bytes) {
                let next = Bytes.skipSpaces(from: offset + word.utf8.count, in: bytes)
                guard next < bytes.count, bytes[next] == UInt8(ascii: "(") else { continue }
                if Bytes.previousWord(before: offset, in: bytes) == "func" { continue }
                hits.append(offset)
            }
        }
        return hits.sorted()
    }
}

/// "No force-unwraps in the Networking module." Fires on a postfix `!` that
/// directly follows an identifier, `)` or `]` and is not part of `!=` / `!==`.
///
/// `try!` and `as!` are not force *unwraps*; they're excluded, and the README
/// says so. Implicitly unwrapped optional declarations (`var x: String!`) do
/// fire: the convention exists to stop silent traps on nil, and an IUO is one.
public struct NoForceUnwrap: LintRule {
    public init() {}
    public func offsets(inMasked bytes: [UInt8]) -> [Int] {
        var hits: [Int] = []
        for i in 1..<max(bytes.count, 1) where bytes[i] == UInt8(ascii: "!") {
            if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "=") { continue }
            let previous = bytes[i - 1]
            if previous == UInt8(ascii: ")") || previous == UInt8(ascii: "]") {
                hits.append(i); continue
            }
            guard Bytes.isIdentifier(previous),
                  let (word, _) = Bytes.identifier(endingAt: i, in: bytes) else { continue }
            if word == "try" || word == "as" { continue }
            hits.append(i)
        }
        return hits
    }
}

/// "No print() in shipping code; use Logger." Fires on a call to `print(`.
/// A method that merely *ends* in print (`logger.print(`) or a declaration
/// (`func print(`) does not fire.
public struct NoPrintInSources: LintRule {
    public init() {}
    public func offsets(inMasked bytes: [UInt8]) -> [Int] {
        var hits: [Int] = []
        for offset in Bytes.occurrences(of: "print", in: bytes) {
            let paren = Bytes.skipSpaces(from: offset + 5, in: bytes)
            guard paren < bytes.count, bytes[paren] == UInt8(ascii: "(") else { continue }
            if offset > 0, bytes[offset - 1] == UInt8(ascii: ".") { continue }
            if Bytes.previousWord(before: offset, in: bytes) == "func" { continue }
            hits.append(offset)
        }
        return hits
    }
}

/// The comparison everyone writes first: a substring search on raw text.
/// Kept in the library so the demo can show what masking buys.
public struct NaiveGrep: Sendable {
    public let needles: [String]
    public init(needles: [String]) { self.needles = needles }
    public func lineNumbers(in text: String) -> [Int] {
        var lines: [Int] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where needles.contains(where: { line.contains($0) }) {
            lines.append(index + 1)
        }
        return lines
    }
}
