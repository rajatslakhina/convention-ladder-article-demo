import SwiftUI
import ConventionLadder

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

enum DemoTab: String, CaseIterable, Identifiable {
    case ladder, findings, session
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ladder: return "Ladder"
        case .findings: return "Findings"
        case .session: return "Session"
        }
    }
}

/// Launch arguments (used by CI to take screenshots):
///   -tab ladder|findings|session
///   -naive YES   (Findings tab: compare with a plain grep)
struct RootView: View {
    @State private var tab: DemoTab

    init() {
        let raw = UserDefaults.standard.string(forKey: "tab") ?? DemoTab.ladder.rawValue
        _tab = State(initialValue: DemoTab(rawValue: raw) ?? .ladder)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .ladder: LadderView()
                case .findings: FindingsView()
                case .session: SessionView()
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("View", selection: $tab) {
                    ForEach(DemoTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle("Convention ladder")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Ladder

struct LadderView: View {
    private let conventions = SampleTeam.conventions

    var body: some View {
        List {
            Section {
                Text("10 lines from a team's CLAUDE.md, each placed on the lowest rung that can hold it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Rung.allCases) { rung in
                let items = conventions.filter { $0.placement.rung == rung }
                Section {
                    ForEach(items) { convention in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(convention.prose)
                                .font(.subheadline)
                            Text(convention.placement.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Circle().fill(color(for: rung)).frame(width: 10, height: 10)
                        Text(rung.title)
                        Spacer()
                        Text("\(items.count)")
                    }
                } footer: {
                    Text("Context cost: \(rung.tokenCost)")
                }
            }
        }
    }
}

func color(for rung: Rung) -> Color {
    switch rung {
    case .typeSystem: return .green
    case .lint: return .blue
    case .hook: return .orange
    case .prose: return .gray
    }
}

// MARK: - Findings

struct FindingsView: View {
    @State private var showNaive = UserDefaults.standard.bool(forKey: "naive")
    private let gate = LintGate(conventions: SampleTeam.conventions)

    private var findings: [Finding] { gate.findings(in: SampleTeam.allWrites) }

    private var naiveLines: [(path: String, line: Int, text: String)] {
        var result: [(String, Int, String)] = []
        for file in SampleTeam.allWrites {
            var needles: [String] = []
            if file.path.hasPrefix("Tests/") { needles.append("sleep(") }
            if file.path.hasPrefix("Sources/") { needles.append("print(") }
            if file.path.hasPrefix("Sources/Networking/") { needles.append("!") }
            guard !needles.isEmpty else { continue }
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            for number in NaiveGrep(needles: needles).lineNumbers(in: file.text) {
                let index = number - 1
                let text = lines.indices.contains(index) ? lines[index].trimmingCharacters(in: .whitespaces) : ""
                result.append((file.path, number, text))
            }
        }
        return result
    }

    private var realKeys: Set<String> { Set(findings.map { "\($0.path):\($0.line)" }) }

    private var falsePositives: Int {
        let keys = realKeys
        return naiveLines.filter { !keys.contains("\($0.path):\($0.line)") }.count
    }

    private var firedConventions: [Convention] {
        let ids = Set(findings.map(\.conventionID))
        return SampleTeam.conventions.filter { ids.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Compare with a plain grep", isOn: $showNaive)
                if showNaive {
                    Text("grep flags \(naiveLines.count) lines; \(falsePositives) of them are comments, strings, `!=` or a `!` negation.")
                        .font(.footnote)
                } else {
                    Text("\(findings.count) lint findings across the session, plus 1 edit blocked by the Package.resolved hook. CheckoutTests' asyncAfter wait is not caught: that judgment stays prose.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if showNaive {
                Section("Plain grep") {
                    ForEach(Array(naiveLines.enumerated()), id: \.offset) { _, hit in
                        let real = realKeys.contains("\(hit.path):\(hit.line)")
                        HStack(alignment: .top) {
                            Image(systemName: real ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(real ? .green : .red)
                            codeRow(path: hit.path, line: hit.line, text: hit.text)
                        }
                    }
                }
            } else {
                ForEach(firedConventions) { convention in
                    Section(convention.id) {
                        Text(convention.guidance)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        ForEach(findings.filter { $0.conventionID == convention.id }) { finding in
                            codeRow(path: finding.path, line: finding.line, text: finding.excerpt)
                        }
                    }
                }
            }
        }
    }

    private func codeRow(path: String, line: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(path):\(line)").font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - Session

struct SessionView: View {
    private let report = SampleTeam.replay()

    var body: some View {
        List {
            Section("30-turn constructed session") {
                bar(label: "Everything as prose", value: report.proseOnlyTokens, color: .gray)
                bar(label: "On the ladder", value: report.ladderTokens, color: .blue)
                Text("Prose pays \(report.proseBlockTokens) tokens every turn and catches nothing by itself. The ladder pays \(report.judgmentBlockTokens) for the judgment lines, plus guidance on the \(report.turnsWithFeedback) turns where a check fired.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("When a check fired") {
                ForEach(Array(report.events.enumerated()), id: \.offset) { _, event in
                    HStack {
                        Text("Turn \(event.turn)").font(.caption.monospacedDigit()).frame(width: 60, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(event.conventionID).font(.subheadline)
                            Text(event.path).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text("Token counts are bytes/4 estimates, and both columns use the same estimator. With prompt caching the prose column is cheaper in money; it still takes up the window on every turn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bar(label: String, value: Int, color: Color) -> some View {
        let maxValue = max(report.proseOnlyTokens, report.ladderTokens, 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(value) tokens").font(.subheadline.monospacedDigit())
            }
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(value) / CGFloat(maxValue))
            }
            .frame(height: 12)
        }
        .padding(.vertical, 4)
    }
}
