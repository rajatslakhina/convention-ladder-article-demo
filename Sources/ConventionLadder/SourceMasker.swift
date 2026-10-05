import Foundation

/// Blanks out the parts of Swift source that a lexical rule must never match:
/// comments and the *contents* of string literals.
///
/// The output has exactly the same number of bytes and the same line breaks as
/// the input, so a byte offset in the masked text is a byte offset in the
/// original and line numbers survive. String delimiters (`"`, `"""`, `#"`) are
/// kept so a rule can still see that a literal starts at a position, and code
/// inside string interpolation (`\(...)`) is kept visible, because a force
/// unwrap inside an interpolation is still a force unwrap.
///
/// This is a lexer, not a parser. It is deliberately small; a production rule
/// set would sit on SwiftSyntax. See the README for what that costs and buys.
public enum SourceMasker {

    private enum Context {
        case string(multiline: Bool, hashes: Int)
        case interpolation(depth: Int)
    }

    private static let space = UInt8(ascii: " ")
    private static let newline = UInt8(ascii: "\n")
    private static let quote = UInt8(ascii: "\"")
    private static let hash = UInt8(ascii: "#")
    private static let backslash = UInt8(ascii: "\\")
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")

    public static func mask(_ source: String) -> [UInt8] {
        let input = Array(source.utf8)
        var output = input
        var stack: [Context] = []
        var blockDepth = 0
        var inLineComment = false
        var i = 0

        func at(_ index: Int) -> UInt8? {
            index >= 0 && index < input.count ? input[index] : nil
        }
        func blank(_ index: Int) {
            guard index < output.count, input[index] != newline else { return }
            output[index] = space
        }
        func countHashes(from index: Int) -> Int {
            var n = 0
            while at(index + n) == hash { n += 1 }
            return n
        }

        while i < input.count {
            let byte = input[i]

            if blockDepth > 0 {
                if byte == slash, at(i + 1) == star {
                    blockDepth += 1; blank(i); blank(i + 1); i += 2; continue
                }
                if byte == star, at(i + 1) == slash {
                    blockDepth -= 1; blank(i); blank(i + 1); i += 2; continue
                }
                blank(i); i += 1; continue
            }

            if inLineComment {
                if byte == newline { inLineComment = false } else { blank(i) }
                i += 1; continue
            }

            if case let .string(multiline, hashes)? = stack.last {
                // Escape or interpolation: `\` followed by the literal's hash count.
                if byte == backslash, countHashes(from: i + 1) >= hashes {
                    let afterHashes = i + 1 + hashes
                    if at(afterHashes) == openParen {
                        for k in i...afterHashes { blank(k) }
                        stack.append(.interpolation(depth: 0))
                        i = afterHashes + 1
                        continue
                    }
                    for k in i...min(afterHashes, input.count - 1) { blank(k) }
                    i = afterHashes + 1
                    continue
                }
                // Closing delimiter.
                let closerLength = multiline ? 3 : 1
                var isCloser = true
                for k in 0..<closerLength where at(i + k) != quote { isCloser = false }
                if isCloser, countHashes(from: i + closerLength) >= hashes {
                    stack.removeLast()
                    i += closerLength + hashes
                    continue
                }
                blank(i); i += 1; continue
            }

            // Code (top level or inside an interpolation).
            if byte == slash, at(i + 1) == slash {
                inLineComment = true; blank(i); blank(i + 1); i += 2; continue
            }
            if byte == slash, at(i + 1) == star {
                blockDepth = 1; blank(i); blank(i + 1); i += 2; continue
            }
            if byte == quote || byte == hash {
                let hashes = countHashes(from: i)
                let start = i + hashes
                if at(start) == quote {
                    let multiline = at(start + 1) == quote && at(start + 2) == quote
                    stack.append(.string(multiline: multiline, hashes: hashes))
                    i = start + (multiline ? 3 : 1)
                    continue
                }
            }
            if case let .interpolation(depth)? = stack.last {
                if byte == openParen {
                    stack[stack.count - 1] = .interpolation(depth: depth + 1)
                } else if byte == closeParen {
                    if depth == 0 {
                        stack.removeLast()
                        blank(i); i += 1; continue
                    }
                    stack[stack.count - 1] = .interpolation(depth: depth - 1)
                }
            }
            i += 1
        }
        return output
    }

    /// Converts a byte offset into a 1-based (line, column) pair.
    public static func position(of offset: Int, in bytes: [UInt8]) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        var index = 0
        let end = min(offset, bytes.count)
        while index < end {
            if bytes[index] == newline { line += 1; column = 1 } else { column += 1 }
            index += 1
        }
        return (line, column)
    }
}
