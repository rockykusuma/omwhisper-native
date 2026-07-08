import Testing
@testable import OmWhisper

@Suite("MemoryCapture domain exclusion")
struct MemoryCaptureExclusionTests {
    @Test("a snapshot with no url is never domain-excluded")
    func noURLNeverExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: nil, excludedDomains: ["example.com"]) == false)
    }

    @Test("an excluded domain is excluded")
    func excludedDomainExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://example.com/page", excludedDomains: ["example.com"]) == true)
    }

    @Test("a subdomain of an excluded domain is excluded")
    func subdomainExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://mail.example.com/inbox", excludedDomains: ["example.com"]) == true)
    }

    @Test("an unrelated domain is not excluded")
    func unrelatedNotExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://other.com/page", excludedDomains: ["example.com"]) == false)
    }

    @Test("an empty exclusion list excludes nothing")
    func emptyListExcludesNothing() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://example.com/page", excludedDomains: []) == false)
    }
}
