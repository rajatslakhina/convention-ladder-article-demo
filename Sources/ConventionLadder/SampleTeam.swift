import Foundation

/// A constructed team: ten lines from an iOS team's CLAUDE.md, and a 30-turn
/// agent session that writes eight files. Nothing here was produced by a real
/// model; the session is built so every rule has a true positive, a true
/// negative and, for honesty, one thing it cannot see.
public enum SampleTeam {

    public static let conventions: [Convention] = [
        Convention(
            id: "no-sleep-in-tests",
            prose: "Never sleep in tests. Wait on an expectation or on state, never on time.",
            traits: Traits(mechanicallyDecidable: true),
            scope: "Tests/",
            lint: NoSleepInTests(),
            guidance: """
            Tests wait on state, not time. Replace the sleep with an expectation fulfilled by the state change:
              let loaded = expectation(description: "feed loaded")
              model.onLoad = { loaded.fulfill() }
              await fulfillment(of: [loaded], timeout: 2)
            """),
        Convention(
            id: "no-force-unwrap-networking",
            prose: "No force-unwraps in the Networking module.",
            traits: Traits(mechanicallyDecidable: true),
            scope: "Sources/Networking/",
            lint: NoForceUnwrap(),
            guidance: """
            Networking code must not trap on nil. Bind and throw instead:
              guard let url = URL(string: base) else { throw APIError.invalidURL(base) }
            """),
        Convention(
            id: "no-print",
            prose: "No print() in shipping code. Use the module's Logger.",
            traits: Traits(mechanicallyDecidable: true),
            scope: "Sources/",
            lint: NoPrintInSources(),
            guidance: """
            Use the module's Logger so output is levelled and redactable:
              Logger.ui.debug("profile tapped")
            """),
        Convention(
            id: "money-is-decimal",
            prose: "Money is never a Double. Use the Money type.",
            traits: Traits(expressibleInTypes: true, mechanicallyDecidable: true)),
        Convention(
            id: "feature-isolation",
            prose: "Feature modules never import each other.",
            traits: Traits(expressibleInTypes: true, mechanicallyDecidable: true, needsCrossFileContext: true)),
        Convention(
            id: "package-resolved",
            prose: "Never edit Package.resolved by hand. Change Package.swift and resolve.",
            traits: Traits(aboutAnAgentAction: true, mechanicallyDecidable: true)),
        Convention(
            id: "tests-before-done",
            prose: "Run the full test suite before you say a task is done.",
            traits: Traits(aboutAnAgentAction: true, mechanicallyDecidable: true, needsCrossFileContext: true)),
        Convention(
            id: "composition",
            prose: "Prefer composition over subclassing for view models.",
            traits: Traits()),
        Convention(
            id: "checkout-failure-mode",
            prose: "If a change touches checkout, say in the PR which failure it prevents and how you know.",
            traits: Traits()),
        Convention(
            id: "main-actor-scope",
            prose: "Keep @MainActor off model types unless they own UI state.",
            traits: Traits()),
    ]

    public static let hook = ProtectedPathHook(
        conventionID: "package-resolved",
        protectedSuffixes: ["Package.resolved"],
        guidance: "Package.resolved is generated. Edit Package.swift, then run `swift package resolve`.")

    // MARK: - Files the agent writes

    static let apiClientV1 = SourceFile(path: "Sources/Networking/APIClient.swift", text: """
    import Foundation

    struct APIClient {
        let base: String
        // TODO: drop the ! below once config is typed
        func feed() async throws -> [Post] {
            let url = URL(string: base + "/feed")!
            let (data, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode != 200 { throw APIError.badStatus }
            let page = try JSONDecoder().decode(Page.self, from: data)
            return page.items.first!.posts
        }
    }
    """)

    static let feedTestsV1 = SourceFile(path: "Tests/FeedTests.swift", text: """
    import XCTest

    final class FeedTests: XCTestCase {
        // We used to sleep(1) here and it was flaky on CI.
        func testFeedLoads() async throws {
            let model = FeedModel()
            model.load()
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(model.state, .loaded, "sleep(1) should not be needed")
        }
    }
    """)

    static let feedView = SourceFile(path: "Sources/Features/FeedView.swift", text: """
    import SwiftUI

    struct FeedView: View {
        let posts: [Post]
        var body: some View {
            List(posts) { post in
                Text(post.title)
            }
        }
    }
    """)

    static let packageResolved = SourceFile(path: "Package.resolved", text: """
    { "pins": [], "version": 3 }
    """)

    static let profileView = SourceFile(path: "Sources/Features/ProfileView.swift", text: """
    import SwiftUI

    struct ProfileView: View {
        let user: User
        var body: some View {
            // print("debug: \\(user)")
            Button(user.name!) {
                print("profile tapped")
            }
        }
    }
    """)

    static let endpoint = SourceFile(path: "Sources/Networking/Endpoint.swift", text: """
    import Foundation

    struct Endpoint {
        let path: String
        var isRoot: Bool { path != "/" }
        func validated() -> Endpoint? {
            !path.isEmpty ? self : nil
        }
    }
    """)

    static let apiClientV2 = SourceFile(path: "Sources/Networking/APIClient.swift", text: """
    import Foundation

    struct APIClient {
        let base: String
        func feed() async throws -> [Post] {
            guard let url = URL(string: base + "/feed") else { throw APIError.invalidURL(base) }
            let (data, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode != 200 { throw APIError.badStatus }
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard let first = page.items.first else { return [] }
            return first.posts
        }
    }
    """)

    static let feedTestsV2 = SourceFile(path: "Tests/FeedTests.swift", text: """
    import XCTest

    final class FeedTests: XCTestCase {
        func testFeedLoads() async throws {
            let model = FeedModel()
            let loaded = expectation(description: "feed loaded")
            model.onLoad = { loaded.fulfill() }
            model.load()
            await fulfillment(of: [loaded], timeout: 2)
            XCTAssertEqual(model.state, .loaded)
        }
    }
    """)

    static let networkLogging = SourceFile(path: "Sources/Networking/Logging.swift", text: """
    import OSLog

    extension APIClient {
        func log(_ response: HTTPURLResponse?) {
            Logger.network.debug("status \\(response!.statusCode)")
        }
    }
    """)

    /// The blind spot: waiting on time without calling `sleep`.
    static let checkoutTests = SourceFile(path: "Tests/CheckoutTests.swift", text: """
    import XCTest

    final class CheckoutTests: XCTestCase {
        func testPayButtonEnables() {
            let model = CheckoutModel()
            let done = expectation(description: "wait")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done.fulfill() }
            wait(for: [done], timeout: 2)
            XCTAssertTrue(model.canPay)
        }
    }
    """)

    /// Every file the session writes, in order (the demo's "repo" view).
    public static var allWrites: [SourceFile] {
        session.flatMap(\.writes)
    }

    /// A 30-turn session. Writes happen on 10 turns; the rest are reads,
    /// builds and conversation, which still pay for whatever sits in CLAUDE.md.
    public static let session: [AgentTurn] = (1...30).map { index in
        switch index {
        case 2: return AgentTurn(index: index, writes: [apiClientV1])
        case 5: return AgentTurn(index: index, writes: [feedTestsV1])
        case 7: return AgentTurn(index: index, writes: [feedView])
        case 9: return AgentTurn(index: index, writes: [packageResolved])
        case 12: return AgentTurn(index: index, writes: [profileView])
        case 14: return AgentTurn(index: index, writes: [endpoint])
        case 17: return AgentTurn(index: index, writes: [apiClientV2])
        case 21: return AgentTurn(index: index, writes: [feedTestsV2])
        case 24: return AgentTurn(index: index, writes: [networkLogging])
        case 27: return AgentTurn(index: index, writes: [checkoutTests])
        default: return AgentTurn(index: index)
        }
    }

    public static func replay() -> SessionReport {
        SessionCost.replay(session, conventions: conventions, hook: hook)
    }
}
