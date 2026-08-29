import Foundation
import XCTest

final class BuilderArtifactShareTests: XCTestCase {
    private let artifactID = "bar_" + String(repeating: "a", count: 64)
    private let token = String(repeating: "b", count: 64)

    func testProductionLinkParsesToFragmentFreeRequest() throws {
        let input = "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)"
        let reference = try BuilderArtifactShareReference(parsing: input)
        XCTAssertEqual(reference.artifactID, artifactID)
        XCTAssertEqual(reference.sourceHost, BuilderArtifactShareReference.productionHost)
        XCTAssertEqual(reference.requestURL.absoluteString, "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)")
        XCTAssertNil(reference.requestURL.fragment)
        XCTAssertNil(reference.requestURL.query)
        XCTAssertEqual(reference.authorizationHeaderValue, "ThumbleShare \(token)")
    }

    func testLoopbackRequiresExplicitLocalPolicyAndPort() throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            for scheme in ["http", "https"] {
                let input = "\(scheme)://\(host):8080/share/\(artifactID)#token=\(token)"
                XCTAssertThrowsError(try BuilderArtifactShareReference(parsing: input))
                let reference = try BuilderArtifactShareReference(parsing: input, policy: .localTesting)
                XCTAssertEqual(reference.requestURL.port, 8080)
            }
        }
        XCTAssertThrowsError(try BuilderArtifactShareReference(
            parsing: "http://localhost/share/\(artifactID)#token=\(token)",
            policy: .localTesting
        ))
    }

    func testRejectsAdversarialOriginsPathsQueriesAndFragments() {
        let vectors = [
            "http://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)",
            "https://THUMBLE-MCP-GATEWAY.FLY.DEV/share/\(artifactID)#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev:443/share/\(artifactID)#token=\(token)",
            "https://user@thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev.evil.example/share/\(artifactID)#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)?token=\(token)#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev//share/\(artifactID)#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)/#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev/share/%62ar_\(String(repeating: "a", count: 64))#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)&token=\(token)",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)&x=1",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#x=1",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=%62\(String(repeating: "b", count: 63))",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(String(repeating: "b", count: 63))",
            "https://thumble-mcp-gateway.fly.dev/share/bar_\(String(repeating: "g", count: 64))#token=\(token)",
            "https://thumble-mcp-gateway.fly.dev/share/\(artifactID)#token=\(token)\n",
        ]
        for value in vectors {
            XCTAssertThrowsError(
                try BuilderArtifactShareReference(parsing: value),
                "Unexpectedly accepted \(value.prefix(80))"
            )
        }
    }

    func testResemblanceClassificationDoesNotAccept() {
        XCTAssertTrue(BuilderArtifactShareReference.resemblesHostedShare("https://evil.example/share/nope"))
        XCTAssertTrue(BuilderArtifactShareReference.resemblesHostedShare("garbage#token=bad"))
        XCTAssertFalse(BuilderArtifactShareReference.resemblesHostedShare("pairing payload"))
        XCTAssertFalse(BuilderArtifactShareReference.resemblesHostedShare("file:///tmp/share/controller.pocketpad"))
    }
}
