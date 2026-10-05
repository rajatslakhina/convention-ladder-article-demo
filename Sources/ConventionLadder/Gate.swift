import Foundation

/// Runs the lint-rung conventions over files and hands back guidance only for
/// what actually fired. This is the SwiftFairy-style shape: the agent never has
/// to remember the rule; it's told the rule at the line where it matters.
public struct LintGate: Sendable {
    public let conventions: [Convention]

    public init(conventions: [Convention]) {
        self.conventions = conventions.filter { $0.lint != nil }
    }

    public func findings(in files: [SourceFile]) -> [Finding] {
        var result: [Finding] = []
        for file in files {
            let masked = SourceMasker.mask(file.text)
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            for convention in conventions where convention.applies(to: file.path) {
                guard let rule = convention.lint else { continue }
                for offset in rule.offsets(inMasked: masked) {
                    let position = SourceMasker.position(of: offset, in: masked)
                    let lineIndex = position.line - 1
                    let excerpt = lines.indices.contains(lineIndex)
                        ? lines[lineIndex].trimmingCharacters(in: .whitespaces) : ""
                    result.append(Finding(conventionID: convention.id, path: file.path,
                                          line: position.line, column: position.column,
                                          excerpt: excerpt))
                }
            }
        }
        return result.sorted { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
    }

    /// The text that goes back into the agent's context: one guidance block per
    /// convention that fired, followed by the exact locations. Empty when nothing fired.
    public func feedback(for findings: [Finding]) -> String {
        guard !findings.isEmpty else { return "" }
        var blocks: [String] = []
        for convention in conventions {
            let hits = findings.filter { $0.conventionID == convention.id }
            guard !hits.isEmpty else { continue }
            let locations = hits.map { "  \($0.path):\($0.line): \($0.excerpt)" }.joined(separator: "\n")
            blocks.append("[\(convention.id)] \(convention.guidance)\n\(locations)")
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// A hook-rung check. Modelled on a Claude Code PreToolUse hook: it sees the
/// action before it happens and can block it, and the reason it gives is fed
/// back to the agent (in Claude Code, exit code 2 + stderr).
public struct ProtectedPathHook: Sendable {
    public enum Decision: Equatable, Sendable {
        case allow
        case block(reason: String)
    }

    public let conventionID: String
    public let protectedSuffixes: [String]
    public let guidance: String

    public init(conventionID: String, protectedSuffixes: [String], guidance: String) {
        self.conventionID = conventionID
        self.protectedSuffixes = protectedSuffixes
        self.guidance = guidance
    }

    public func decide(editing path: String) -> Decision {
        protectedSuffixes.contains(where: { path.hasSuffix($0) })
            ? .block(reason: "[\(conventionID)] \(guidance)\n  blocked: \(path)")
            : .allow
    }
}
