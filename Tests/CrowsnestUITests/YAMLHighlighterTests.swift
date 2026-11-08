import Foundation
import Testing
@testable import CrowsnestUI

@Suite struct YAMLHighlighterTests {
    func kinds(_ yaml: String) -> [(YAMLHighlighter.TokenKind, String)] {
        let ns = yaml as NSString
        return YAMLHighlighter.tokens(in: yaml).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    @Test func keysValuesAndComments() {
        let t = kinds("""
        apiVersion: v1 # comment
        spec:
          replicas: 3
          paused: false
          image: "nginx:1.27"
          - name: web
        """)
        #expect(t.contains { $0 == (.key, "apiVersion") })
        #expect(t.contains { $0 == (.string, "v1") })
        #expect(t.contains { $0 == (.comment, "# comment") })
        #expect(t.contains { $0 == (.number, "3") })
        #expect(t.contains { $0 == (.keyword, "false") })
        #expect(t.contains { $0 == (.string, #""nginx:1.27""#) })
        #expect(t.contains { $0 == (.punctuation, "-") })
        #expect(t.contains { $0 == (.key, "name") })
    }

    @Test func blockScalarIsNotParsedAsKeys() {
        let t = kinds("""
        data:
          script: |
            key: not-a-key
            # not a comment
          other: 1
        """)
        #expect(t.contains { $0 == (.blockScalar, "key: not-a-key") })
        #expect(t.contains { $0 == (.blockScalar, "# not a comment") })
        #expect(!t.contains { $0 == (.key, "key") })
        #expect(t.contains { $0 == (.key, "other") })
    }

    @Test func urlValueWithColonIsString() {
        let t = kinds("url: https://example.com:8443/x")
        #expect(t.contains { $0 == (.key, "url") })
        #expect(t.contains { $0 == (.string, "https://example.com:8443/x") })
    }

    @Test func autoIndent() {
        #expect(EditorTheme.indentation(after: "  spec:") == "    ")
        #expect(EditorTheme.indentation(after: "  - name: web") == "    ")
        #expect(EditorTheme.indentation(after: "    image: x") == "    ")
        #expect(EditorTheme.indentation(after: "  script: |") == "    ")
    }
}
