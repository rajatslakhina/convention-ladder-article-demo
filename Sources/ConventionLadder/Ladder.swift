import Foundation

/// Where a team convention lives. Ordered from "the compiler enforces it" to
/// "a model is asked to remember it".
public enum Rung: Int, CaseIterable, Comparable, Sendable, Identifiable {
    case typeSystem = 0
    case lint
    case hook
    case prose

    public var id: Int { rawValue }
    public static func < (a: Rung, b: Rung) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .typeSystem: return "Type system / build graph"
        case .lint: return "Lint (per-file, deterministic)"
        case .hook: return "Agent hook (fires on an action)"
        case .prose: return "Prose in CLAUDE.md"
        }
    }

    /// When the rung costs context tokens.
    public var tokenCost: String {
        switch self {
        case .typeSystem: return "never (the build fails instead)"
        case .lint, .hook: return "only when it fires"
        case .prose: return "every turn"
        }
    }
}

/// The questions a lead answers about a convention before deciding where it lives.
public struct Traits: Hashable, Sendable {
    /// Could a type, an access level or a module boundary make the wrong code not compile?
    public var expressibleInTypes: Bool
    /// Is it about an *action* the agent takes (editing a path, claiming "done"),
    /// rather than about the code it produces?
    public var aboutAnAgentAction: Bool
    /// Can a program decide it, with no taste involved?
    public var mechanicallyDecidable: Bool
    /// Does deciding it need more than the one file being edited?
    public var needsCrossFileContext: Bool

    public init(expressibleInTypes: Bool = false,
                aboutAnAgentAction: Bool = false,
                mechanicallyDecidable: Bool = false,
                needsCrossFileContext: Bool = false) {
        self.expressibleInTypes = expressibleInTypes
        self.aboutAnAgentAction = aboutAnAgentAction
        self.mechanicallyDecidable = mechanicallyDecidable
        self.needsCrossFileContext = needsCrossFileContext
    }
}

public struct Placement: Hashable, Sendable {
    public let rung: Rung
    public let reason: String
}

/// Places a convention on the lowest rung that can actually hold it.
/// The order of the questions is the whole policy: try to make the mistake
/// impossible, then detectable, and only then ask a model to remember it.
public enum LadderAdvisor {
    public static func place(_ traits: Traits) -> Placement {
        if traits.expressibleInTypes {
            return Placement(rung: .typeSystem,
                             reason: "The wrong version can be made not to compile.")
        }
        if traits.aboutAnAgentAction {
            return Placement(rung: .hook,
                             reason: "It's about what the agent does, not what the code says; check it at the action.")
        }
        if traits.mechanicallyDecidable && !traits.needsCrossFileContext {
            return Placement(rung: .lint,
                             reason: "One file is enough to decide it, and no taste is involved.")
        }
        if traits.mechanicallyDecidable {
            return Placement(rung: .hook,
                             reason: "Decidable, but needs the whole repo; run it at a boundary (Stop / pre-commit).")
        }
        return Placement(rung: .prose,
                         reason: "It needs judgment. Keep it as prose, and keep it short.")
    }
}

/// A line from a team's CLAUDE.md, plus what the lead decided about it.
public struct Convention: Identifiable, Sendable {
    public let id: String
    /// The sentence as it appears in CLAUDE.md today.
    public let prose: String
    public let traits: Traits
    /// Path prefix the convention applies to ("" = everywhere).
    public let scope: String
    /// The deterministic check, when the convention has one in this demo.
    public let lint: (any LintRule)?
    /// What the agent is told *when the check fires*: the rule plus a corrective example.
    public let guidance: String

    public init(id: String, prose: String, traits: Traits, scope: String = "",
                lint: (any LintRule)? = nil, guidance: String = "") {
        self.id = id
        self.prose = prose
        self.traits = traits
        self.scope = scope
        self.lint = lint
        self.guidance = guidance
    }

    public var placement: Placement { LadderAdvisor.place(traits) }

    public func applies(to path: String) -> Bool {
        scope.isEmpty || path.hasPrefix(scope)
    }
}
