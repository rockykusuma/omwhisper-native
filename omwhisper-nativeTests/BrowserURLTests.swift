import Testing
@testable import OmWhisper

@Suite("BrowserURL")
struct BrowserURLTests {
    @Test("domain(of:) strips a www. prefix")
    func stripsWWW() {
        #expect(BrowserURL.domain(of: "https://www.example.com/page") == "example.com")
    }

    @Test("domain(of:) lowercases the host")
    func lowercases() {
        #expect(BrowserURL.domain(of: "https://Example.COM") == "example.com")
    }

    @Test("domain(of:) returns nil for a string with no host")
    func noHost() {
        #expect(BrowserURL.domain(of: "not a url") == nil)
    }

    @Test("domain matches itself exactly")
    func exactMatch() {
        #expect(BrowserURL.domain("example.com", matches: "example.com") == true)
    }

    @Test("a subdomain matches its parent domain")
    func subdomainMatches() {
        #expect(BrowserURL.domain("docs.example.com", matches: "example.com") == true)
    }

    @Test("an unrelated domain does not match")
    func unrelatedDoesNotMatch() {
        #expect(BrowserURL.domain("example.com", matches: "example.org") == false)
        #expect(BrowserURL.domain("notexample.com", matches: "example.com") == false)
    }

    @Test("isBrowser recognizes known browser bundle ids")
    func recognizesBrowsers() {
        #expect(BrowserURL.isBrowser("com.apple.Safari") == true)
        #expect(BrowserURL.isBrowser("com.google.Chrome") == true)
        #expect(BrowserURL.isBrowser("com.omwhisper.mac") == false)
    }
}
