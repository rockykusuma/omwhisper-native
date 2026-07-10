//
//  Redactor.swift
//  OmWhisper
//
//  Scrubs secrets/PII from text before it is sent to a cloud API, and re-hydrates
//  the placeholders a cloud response echoes back. Faithful port of the old Tauri
//  app's src-tauri/src/ai/redactor.rs. Cloud is the ONLY egress for polish text
//  (System/Ollama are on-device), so CloudLLM.polish calls redact() unconditionally
//  as its first step — no separate is-cloud gate. The placeholder->original mapping
//  is in-memory, per-request, and never logged or persisted.
//

import Foundation

nonisolated struct Redaction {
    /// Input with each sensitive span replaced by a typed placeholder.
    let text: String
    /// placeholder -> original. In-memory only; never log or persist.
    let mapping: [String: String]

    /// Restore any placeholders the cloud response echoed back. Order-independent:
    /// placeholders are bracket-delimited, so `[REDACTED_EMAIL_1]` (ending in `]`)
    /// is never a substring of `[REDACTED_EMAIL_11]`.
    func rehydrate(_ input: String) -> String {
        var out = input
        for (placeholder, original) in mapping where out.contains(placeholder) {
            out = out.replacingOccurrences(of: placeholder, with: original)
        }
        return out
    }
}

private nonisolated struct Detector {
    let kind: String
    let regex: NSRegularExpression
    let validate: ((String) -> Bool)?
}

private nonisolated func makeRegex(_ pattern: String, dotAll: Bool = false) -> NSRegularExpression {
    // Patterns are fixed literals ported from the working Rust; try! is a build-time
    // assertion they compile, not runtime input handling.
    try! NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : [])
}

private enum RedactorRegistry {
    // Highest priority first (index 0 wins overlap ties). Built once; the array is
    // immutable and NSRegularExpression is safe for concurrent matching, so
    // nonisolated(unsafe) on the literal (Detector isn't provably Sendable).
    nonisolated(unsafe) static let detectors: [Detector] = [
        Detector(kind: "PRIVATE_KEY",
                 regex: makeRegex(#"-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----.*?-----END[A-Z0-9 ]*PRIVATE KEY-----"#, dotAll: true),
                 validate: nil),
        Detector(kind: "AWS_KEY",        regex: makeRegex(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),      validate: nil),
        Detector(kind: "SLACK_TOKEN",    regex: makeRegex(#"\bxox[baprs]-[0-9A-Za-z-]{10,}"#),     validate: nil),
        Detector(kind: "GITHUB_TOKEN",   regex: makeRegex(#"\bgh[posru]_[0-9A-Za-z]{20,}"#),       validate: nil),
        Detector(kind: "GOOGLE_API_KEY", regex: makeRegex(#"\bAIza[0-9A-Za-z_\-]{35}"#),           validate: nil),
        Detector(kind: "API_KEY",        regex: makeRegex(#"\bsk-(?:proj-)?[0-9A-Za-z_\-]{16,}"#), validate: nil),
        Detector(kind: "BEARER_TOKEN",   regex: makeRegex(#"\bBearer\s+[0-9A-Za-z._\-]{12,}"#),    validate: nil),
        Detector(kind: "EMAIL",          regex: makeRegex(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#), validate: nil),
        Detector(kind: "CARD",           regex: makeRegex(#"\b\d(?:[ \-]?\d){12,18}\b"#),          validate: luhnValid),
        Detector(kind: "PHONE",          regex: makeRegex(#"\+?\d[\d\s().\-]{5,}\d"#),             validate: isPhone),
        Detector(kind: "SECRET",         regex: makeRegex(#"[A-Za-z0-9]{28,}"#),                   validate: isHighEntropySecret),
    ]
}

nonisolated func redact(_ text: String) -> Redaction {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)

    struct Candidate { let start: Int; let end: Int; let priority: Int; let kind: String; let value: String }
    var candidates: [Candidate] = []
    for (priority, det) in RedactorRegistry.detectors.enumerated() {
        for m in det.regex.matches(in: text, range: full) {
            let value = ns.substring(with: m.range)
            if det.validate?(value) ?? true {
                candidates.append(Candidate(start: m.range.location,
                                            end: m.range.location + m.range.length,
                                            priority: priority, kind: det.kind, value: value))
            }
        }
    }
    // Earliest start wins; ties by detector priority (lower index = higher). Greedy keep.
    candidates.sort { $0.start != $1.start ? $0.start < $1.start : $0.priority < $1.priority }
    var accepted: [Candidate] = []
    var lastEnd = 0
    for c in candidates where c.start >= lastEnd {
        lastEnd = c.end
        accepted.append(c)
    }
    // Stable typed placeholders; build output in one pass over NSString ranges.
    var mapping: [String: String] = [:]
    var placeholderFor: [String: String] = [:]
    var counters: [String: Int] = [:]
    var out = ""
    var cursor = 0
    for m in accepted {
        let placeholder: String
        if let existing = placeholderFor[m.value] {
            placeholder = existing
        } else {
            let n = (counters[m.kind] ?? 0) + 1
            counters[m.kind] = n
            placeholder = "[REDACTED_\(m.kind)_\(n)]"
            placeholderFor[m.value] = placeholder
            mapping[placeholder] = m.value
        }
        out += ns.substring(with: NSRange(location: cursor, length: m.start - cursor))
        out += placeholder
        cursor = m.end
    }
    out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
    return Redaction(text: out, mapping: mapping)
}

// MARK: Validators (ported line-for-line)

private nonisolated func luhnValid(_ s: String) -> Bool {
    let digits = s.unicodeScalars.compactMap { ("0"..."9").contains($0) ? Int($0.value - 48) : nil }
    guard (13...19).contains(digits.count) else { return false }
    var sum = 0, double = false
    for d in digits.reversed() {
        var x = d
        if double { x *= 2; if x > 9 { x -= 9 } }
        sum += x
        double.toggle()
    }
    return sum % 10 == 0
}

private nonisolated func isPhone(_ s: String) -> Bool {
    let digitCount = s.filter { $0.isASCII && $0.isNumber }.count
    guard (7...15).contains(digitCount) else { return false }
    let plus = s.drop(while: { $0.isWhitespace }).first == "+"
    let seps = s.filter { " -().".contains($0) }.count
    return (plus && digitCount >= 8) || (seps >= 1 && digitCount >= 10)
}

private nonisolated func isHighEntropySecret(_ s: String) -> Bool {
    guard s.count >= 28 else { return false }
    let hasDigit = s.contains { $0.isASCII && $0.isNumber }
    let hasAlpha = s.contains { $0.isASCII && $0.isLetter }
    return hasDigit && hasAlpha && shannonEntropy(s) >= 3.2
}

private nonisolated func shannonEntropy(_ s: String) -> Double {
    let bytes = Array(s.utf8)
    guard !bytes.isEmpty else { return 0 }
    var counts = [Int](repeating: 0, count: 256)
    for b in bytes { counts[Int(b)] += 1 }
    let len = Double(bytes.count)
    return counts.filter { $0 > 0 }.reduce(0.0) { acc, c in
        let p = Double(c) / len
        return acc - p * log2(p)
    }
}
