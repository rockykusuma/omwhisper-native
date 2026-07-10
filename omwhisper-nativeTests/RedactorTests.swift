import Foundation
import Testing
@testable import OmWhisper

struct RedactorTests {
    @Test func catchesEmail() {
        let r = redact("ping me at jane.doe@example.com ok")
        #expect(!r.text.contains("jane.doe@example.com"))
        #expect(r.text.contains("[REDACTED_EMAIL_1]"))
        #expect(r.mapping["[REDACTED_EMAIL_1]"] == "jane.doe@example.com")
    }

    @Test func catchesOpenAIKey() {
        let key = ["sk-", "proj-ABCdef0123456789ABCdef0123"].joined()
        let r = redact("my key is \(key) thanks")
        #expect(!r.text.contains(key))
        #expect(r.text.contains("[REDACTED_API_KEY_1]"))
        #expect(r.mapping["[REDACTED_API_KEY_1]"] == key)
    }

    @Test func catchesBearerToken() {
        let r = redact("Authorization: Bearer abcDEF123456ghiJKL")
        #expect(!r.text.contains("abcDEF123456ghiJKL"))
        #expect(r.text.contains("[REDACTED_BEARER_TOKEN_1]"))
    }

    @Test func catchesProviderKeys() {
        let cases: [(String, String)] = [
            (["xox", "b-1234567890-abcdefghijklmno"].joined(), "SLACK_TOKEN"),
            (["AKIA", "IOSFODNN7EXAMPLE"].joined(), "AWS_KEY"),
            (["ghp", "_0123456789abcdefABCDEFghijklmnopqrs"].joined(), "GITHUB_TOKEN"),
            (["AIza", "SyA1234567890abcdefghijklmnopqrstuv"].joined(), "GOOGLE_API_KEY"),
        ]
        for (secret, kind) in cases {
            let r = redact("value \(secret) end")
            #expect(!r.text.contains(secret), "\(kind) leaked")
            #expect(r.text.contains("[REDACTED_\(kind)_1]"), "expected \(kind) placeholder, got \(r.text)")
        }
    }

    @Test func catchesPrivateKeyBlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBmabc123\nDEF456ghi==\n-----END RSA PRIVATE KEY-----"
        let r = redact("here:\n\(pem)\ndone")
        #expect(!r.text.contains("MIIBmabc123"))
        #expect(r.text.contains("[REDACTED_PRIVATE_KEY_1]"))
    }

    @Test func catchesLuhnValidCardOnly() {
        let r = redact("card 4111 1111 1111 1111 not 1234 5678 9012 3456")
        #expect(!r.text.contains("4111 1111 1111 1111"))
        #expect(r.text.contains("[REDACTED_CARD_1]"))
        #expect(r.text.contains("1234 5678 9012 3456"))  // Luhn-invalid → left alone
    }

    @Test func catchesPhoneButNotYearRange() {
        let r = redact("call +1 (555) 123-4567 during 2020-2021")
        #expect(r.text.contains("[REDACTED_PHONE_1]"))
        #expect(!r.text.contains("555) 123-4567"))
        #expect(r.text.contains("2020-2021"))
    }

    @Test func catchesHighEntropySecretButNotPlainWord() {
        let secret = "Zx9Kq2Lm7Pw4Rt6Yv1Bn8Cd3Fg5Hj0"
        let r = redact("token=\(secret)")
        #expect(!r.text.contains(secret))
        #expect(r.text.contains("[REDACTED_SECRET_1]"))
        let plain = redact("supercalifragilisticexpialidocioussentence")
        #expect(plain.mapping.isEmpty, "plain word wrongly redacted: \(plain.text)")
    }

    @Test func placeholdersAreTypedAndStable() {
        let r = redact("mail a@x.com, again a@x.com, and b@y.com")
        #expect(r.text.contains("[REDACTED_EMAIL_1]"))
        #expect(r.text.contains("[REDACTED_EMAIL_2]"))
        #expect(r.text.components(separatedBy: "[REDACTED_EMAIL_1]").count - 1 == 2)  // reused for a@x.com
        #expect(r.mapping["[REDACTED_EMAIL_1]"] == "a@x.com")
        #expect(r.mapping["[REDACTED_EMAIL_2]"] == "b@y.com")
    }

    @Test func rehydrateRestoresOriginals() {
        let key = ["sk-", "ABCdef0123456789ABCdef"].joined()
        let r = redact("email a@x.com and key \(key)")
        let cloudResponse = "Sure — contact [REDACTED_EMAIL_1] using [REDACTED_API_KEY_1]."
        let restored = r.rehydrate(cloudResponse)
        #expect(restored.contains("a@x.com"))
        #expect(restored.contains(key))
        #expect(!restored.contains("[REDACTED_"))
    }

    @Test func cleanTextUnchanged() {
        let text = "Let's meet tomorrow at noon to review the roadmap."
        let r = redact(text)
        #expect(r.text == text)
        #expect(r.mapping.isEmpty)
    }
}
