import Foundation

/// A rough token estimate: UTF-8 bytes / 4, rounded up. It's the usual rule of
/// thumb for English and code, not a tokenizer. Every number this demo prints is
/// a *relative* comparison made with the same estimator on both sides.
public enum TokenEstimate {
    public static func approx(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }
}

/// One turn of a (constructed) agent session: the files it wrote and the paths
/// it tried to edit.
public struct AgentTurn: Sendable {
    public let index: Int
    public let writes: [SourceFile]
    public init(index: Int, writes: [SourceFile] = []) {
        self.index = index
        self.writes = writes
    }
}

public struct SessionReport: Sendable {
    public let turns: Int
    /// Tokens spent if every convention stays prose in CLAUDE.md.
    public let proseOnlyTokens: Int
    /// Tokens spent when conventions sit on the ladder: the judgment lines stay
    /// prose, and checks add guidance only on the turns where they fire.
    public let ladderTokens: Int
    /// Turns on which at least one lint or hook check fired.
    public let turnsWithFeedback: Int
    /// Every finding / block, in turn order.
    public let events: [(turn: Int, conventionID: String, path: String)]
    /// Per-turn context cost of the full prose block.
    public let proseBlockTokens: Int
    /// Per-turn context cost of the judgment-only prose block.
    public let judgmentBlockTokens: Int
}

public enum SessionCost {
    /// Replays a session under both policies.
    ///
    /// The prose-only policy pays for every CLAUDE.md line on every turn, and
    /// never catches anything: compliance is up to the model. The ladder policy
    /// pays for the judgment lines on every turn and for guidance only when a
    /// check fires. Type-system conventions cost nothing in either column here:
    /// the build fails before the agent's context is involved.
    public static func replay(_ turns: [AgentTurn],
                              conventions: [Convention],
                              hook: ProtectedPathHook) -> SessionReport {
        let proseBlock = conventions.map { "- " + $0.prose }.joined(separator: "\n")
        let judgmentBlock = conventions
            .filter { $0.placement.rung == .prose }
            .map { "- " + $0.prose }
            .joined(separator: "\n")
        let proseBlockTokens = TokenEstimate.approx(proseBlock)
        let judgmentBlockTokens = TokenEstimate.approx(judgmentBlock)

        let gate = LintGate(conventions: conventions)
        var ladder = 0
        var withFeedback = 0
        var events: [(Int, String, String)] = []

        for turn in turns {
            ladder += judgmentBlockTokens
            var feedback: [String] = []

            var allowed: [SourceFile] = []
            for write in turn.writes {
                switch hook.decide(editing: write.path) {
                case .allow:
                    allowed.append(write)
                case .block(let reason):
                    feedback.append(reason)
                    events.append((turn.index, hook.conventionID, write.path))
                }
            }
            let findings = gate.findings(in: allowed)
            for finding in findings {
                events.append((turn.index, finding.conventionID, finding.path))
            }
            let lintFeedback = gate.feedback(for: findings)
            if !lintFeedback.isEmpty { feedback.append(lintFeedback) }

            if !feedback.isEmpty {
                withFeedback += 1
                ladder += TokenEstimate.approx(feedback.joined(separator: "\n\n"))
            }
        }

        return SessionReport(turns: turns.count,
                             proseOnlyTokens: proseBlockTokens * turns.count,
                             ladderTokens: ladder,
                             turnsWithFeedback: withFeedback,
                             events: events,
                             proseBlockTokens: proseBlockTokens,
                             judgmentBlockTokens: judgmentBlockTokens)
    }
}
