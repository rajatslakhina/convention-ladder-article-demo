import XCTest
@testable import ConventionLadder

private func masked(_ s: String) -> String { String(decoding: SourceMasker.mask(s), as: UTF8.self) }
private func hits(_ rule: any LintRule, _ s: String) -> Int { rule.offsets(inMasked: SourceMasker.mask(s)).count }

final class SourceMaskerTests: XCTestCase {
    func testCommentsAndStringContentsAreBlankedButShapeIsKept() {
        let src = "let a = \"sleep(1)\" // sleep(2)\n/* x /* nested */ sleep(3) */ let b = 1"
        let out = masked(src)
        XCTAssertEqual(out.utf8.count, src.utf8.count)
        XCTAssertEqual(out.split(separator: "\n", omittingEmptySubsequences: false).count, 2)
        XCTAssertFalse(out.contains("sleep"))
        XCTAssertTrue(out.contains("let a = \""))
        XCTAssertTrue(out.contains("let b = 1"))
    }

    func testInterpolatedCodeStaysVisible() {
        let out = masked("log(\"status \\(response!.code) done\")")
        XCTAssertTrue(out.contains("response!.code"))
        XCTAssertFalse(out.contains("status"))
        XCTAssertFalse(out.contains("done"))
    }

    func testRawAndMultilineStrings() {
        let raw = masked("let r = #\"a \"sleep(1)\" b\"# ; sleep(2)")
        XCTAssertEqual(raw.components(separatedBy: "sleep").count - 1, 1)
        let multi = masked("let m = \"\"\"\nprint(\"x\")\n\"\"\"\nprint(1)")
        XCTAssertEqual(multi.components(separatedBy: "print").count - 1, 1)
    }

    func testUnterminatedInputDoesNotCrash() {
        XCTAssertEqual(SourceMasker.mask("").count, 0)
        XCTAssertEqual(SourceMasker.mask("let s = \"open").count, 13)
        XCTAssertEqual(SourceMasker.mask("/* open").count, 7)
        XCTAssertEqual(hits(NoForceUnwrap(), "!"), 0)
        XCTAssertEqual(hits(NoForceUnwrap(), "x!"), 1)
    }

    func testPositionIsOneBased() {
        let bytes = Array("ab\ncd".utf8)
        XCTAssertEqual(SourceMasker.position(of: 3, in: bytes).line, 2)
        XCTAssertEqual(SourceMasker.position(of: 4, in: bytes).column, 2)
    }
}

final class RuleTests: XCTestCase {
    func testNoSleepInTests() {
        let rule = NoSleepInTests()
        XCTAssertEqual(hits(rule, "try await Task.sleep(for: .seconds(1))"), 1)
        XCTAssertEqual(hits(rule, "Thread.sleep(forTimeInterval: 0.5)"), 1)
        XCTAssertEqual(hits(rule, "usleep(100); sleep (1)"), 2)
        XCTAssertEqual(hits(rule, "func sleep(_ s: Double) {}"), 0)
        XCTAssertEqual(hits(rule, "// sleep(1)\nlet s = \"sleep(1)\""), 0)
        XCTAssertEqual(hits(rule, "let sleepy = 1; deepsleep(2)"), 0)
    }

    func testTheSleepRuleBlindSpotIsReal() {
        // Waiting on time without calling sleep. The rule can't see it, by design.
        XCTAssertEqual(hits(NoSleepInTests(), "DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done.fulfill() }"), 0)
    }

    func testNoForceUnwrap() {
        let rule = NoForceUnwrap()
        XCTAssertEqual(hits(rule, "let u = URL(string: s)!"), 1)
        XCTAssertEqual(hits(rule, "items.first!.name"), 1)
        XCTAssertEqual(hits(rule, "dict[\"k\"]!"), 1)
        XCTAssertEqual(hits(rule, "var name: String!"), 1)
        XCTAssertEqual(hits(rule, "if a != b, c !== d, !flag, (x)!=y {}"), 0)
        XCTAssertEqual(hits(rule, "let d = try! decode(); let v = any as! View"), 0)
        XCTAssertEqual(hits(rule, "// a! b!\nlet s = \"wow!\""), 0)
    }

    func testNoPrintInSources() {
        let rule = NoPrintInSources()
        XCTAssertEqual(hits(rule, "print(\"x\")"), 1)
        XCTAssertEqual(hits(rule, "logger.print(\"x\"); func print(_ s: String) {}"), 0)
        XCTAssertEqual(hits(rule, "// print(\"x\")\nlet fingerprint = 1; reprint()"), 0)
    }
}

final class LadderTests: XCTestCase {
    func testPlacementOrderIsTypesThenActionsThenLintThenProse() {
        XCTAssertEqual(LadderAdvisor.place(Traits(expressibleInTypes: true, aboutAnAgentAction: true)).rung, .typeSystem)
        XCTAssertEqual(LadderAdvisor.place(Traits(aboutAnAgentAction: true, mechanicallyDecidable: true)).rung, .hook)
        XCTAssertEqual(LadderAdvisor.place(Traits(mechanicallyDecidable: true)).rung, .lint)
        XCTAssertEqual(LadderAdvisor.place(Traits(mechanicallyDecidable: true, needsCrossFileContext: true)).rung, .hook)
        XCTAssertEqual(LadderAdvisor.place(Traits()).rung, .prose)
    }

    func testSampleTeamSplitsTenLinesAcrossFourRungs() {
        let rungs = SampleTeam.conventions.map(\.placement.rung)
        XCTAssertEqual(rungs.count, 10)
        XCTAssertEqual(rungs.filter { $0 == .typeSystem }.count, 2)
        XCTAssertEqual(rungs.filter { $0 == .lint }.count, 3)
        XCTAssertEqual(rungs.filter { $0 == .hook }.count, 2)
        XCTAssertEqual(rungs.filter { $0 == .prose }.count, 3)
    }

    func testScope() {
        let c = SampleTeam.conventions[1]
        XCTAssertTrue(c.applies(to: "Sources/Networking/APIClient.swift"))
        XCTAssertFalse(c.applies(to: "Sources/Features/ProfileView.swift"))
    }
}

final class GateTests: XCTestCase {
    let gate = LintGate(conventions: SampleTeam.conventions)

    func testHookBlocksGeneratedFileOnly() {
        XCTAssertNotEqual(SampleTeam.hook.decide(editing: "Package.resolved"), .allow)
        XCTAssertEqual(SampleTeam.hook.decide(editing: "Package.swift"), .allow)
    }

    func testFeedbackIsEmptyWhenNothingFires() {
        XCTAssertEqual(gate.feedback(for: gate.findings(in: [SampleTeam.feedTestsV2, SampleTeam.apiClientV2])), "")
    }

    func testFeedbackCarriesGuidanceAndExactLocation() {
        let text = gate.feedback(for: gate.findings(in: [SampleTeam.feedTestsV1]))
        XCTAssertTrue(text.hasPrefix("[no-sleep-in-tests] Tests wait on state, not time."))
        XCTAssertTrue(text.contains("Tests/FeedTests.swift:8: try await Task.sleep(for: .seconds(1))"))
    }

    func testFindingsAcrossTheSession() {
        let findings = gate.findings(in: SampleTeam.allWrites)
        XCTAssertEqual(findings.map { "\($0.path):\($0.line)" }, [
            "Sources/Features/ProfileView.swift:8",
            "Sources/Networking/APIClient.swift:7",
            "Sources/Networking/APIClient.swift:11",
            "Sources/Networking/Logging.swift:5",
            "Tests/FeedTests.swift:8",
        ])
        // ProfileView's `user.name!` is outside the Networking scope, so it doesn't fire.
        XCTAssertFalse(findings.contains { $0.excerpt.contains("user.name!") })
    }

    func testNaiveGrepFlags13LinesWhereSixAreReal() {
        let writes = SampleTeam.allWrites
        let sleep = NaiveGrep(needles: ["sleep("])
        let print = NaiveGrep(needles: ["print("])
        let bang = NaiveGrep(needles: ["!"])
        var naive = 0
        for w in writes {
            if w.path.hasPrefix("Tests/") { naive += sleep.lineNumbers(in: w.text).count }
            if w.path.hasPrefix("Sources/") { naive += print.lineNumbers(in: w.text).count }
            if w.path.hasPrefix("Sources/Networking/") { naive += bang.lineNumbers(in: w.text).count }
        }
        XCTAssertEqual(naive, 13)
        XCTAssertEqual(gate.findings(in: writes).count, 5)
        // 5 lint findings + 1 hook block = 6 real violations; grep alone can't see the hook one.
    }
}

final class SessionCostTests: XCTestCase {
    func testReplayNumbersQuotedInTheArticle() {
        let r = SampleTeam.replay()
        XCTAssertEqual(r.turns, 30)
        XCTAssertEqual(r.proseBlockTokens, 150)
        XCTAssertEqual(r.judgmentBlockTokens, 51)
        XCTAssertEqual(r.proseOnlyTokens, 4_500)
        XCTAssertEqual(r.ladderTokens, 1_832)
        XCTAssertEqual(r.turnsWithFeedback, 5)
        XCTAssertEqual(r.events.count, 6)
        XCTAssertEqual(r.events.map(\.turn), [2, 2, 5, 9, 12, 24])
        XCTAssertFalse(r.events.contains { $0.path == "Tests/CheckoutTests.swift" })
    }

    func testEmptySession() {
        let r = SessionCost.replay([], conventions: SampleTeam.conventions, hook: SampleTeam.hook)
        XCTAssertEqual(r.proseOnlyTokens, 0)
        XCTAssertEqual(r.ladderTokens, 0)
        XCTAssertEqual(r.turnsWithFeedback, 0)
    }

    func testTokenEstimate() {
        XCTAssertEqual(TokenEstimate.approx(""), 0)
        XCTAssertEqual(TokenEstimate.approx("abcde"), 2)
    }
}
