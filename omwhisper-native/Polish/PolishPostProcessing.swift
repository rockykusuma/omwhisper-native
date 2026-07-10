//
//  PolishPostProcessing.swift
//  OmWhisper
//
//  Port of the old Tauri app's `strip_llm_wrapper` (src-tauri/src/ai/mod.rs) — trims
//  preamble/postamble that chat models add despite being told not to ("Output:",
//  "Here is the polished text:", trailing "(I removed the filler words)"). Applied to
//  Ollama output only; Foundation Models is well-behaved and left untouched.
//

import Foundation

nonisolated func stripLLMWrapper(_ input: String) -> String {
    var text = input
    if let r = text.range(of: "Output:"), r.lowerBound == text.startIndex {
        text = String(text[r.upperBound...])
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    let lines = text.components(separatedBy: "\n")
    if lines.isEmpty { return text }

    // Drop a leading preamble line ending in ':' that is followed by a blank line.
    var start = 0
    if lines.count > 1,
       lines[0].trimmingCharacters(in: .whitespaces).hasSuffix(":"),
       lines[1].trimmingCharacters(in: .whitespaces).isEmpty {
        start = 2
    }

    // Drop trailing blank / meta-commentary lines.
    var end = lines.count
    while end > start {
        let line = lines[end - 1].trimmingCharacters(in: .whitespaces)
        if line.isEmpty || isMetaCommentary(line) { end -= 1 } else { break }
    }

    if start >= end { return text }

    var result = Array(lines[start..<end])
    if let last = result.last, let stripped = stripInlineCommentary(last) {
        result[result.count - 1] = stripped
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private nonisolated func isMetaCommentary(_ line: String) -> Bool {
    if line.hasPrefix("(") && line.hasSuffix(")") { return true }
    if line.count >= 150 { return false }
    let lower = line.lowercased()
    let prefixes = [
        "note:", "i removed some", "i removed filler", "i removed the filler",
        "i corrected the", "i corrected some", "i corrected grammar",
        "i cleaned up", "i made some adjustments", "i made some changes",
        "i made some minor", "i adjusted the",
        "let me know if you'd like", "let me know if you need any",
    ]
    if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
    if (lower.hasPrefix("here is") || lower.hasPrefix("here's")),
       line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
        return true
    }
    return false
}

private nonisolated func stripInlineCommentary(_ line: String) -> String? {
    for sep in [". ", "! ", "? "] {
        var searchStart = line.startIndex
        while let r = line.range(of: sep, range: searchStart..<line.endIndex) {
            let after = line[r.upperBound...].drop(while: { $0.isWhitespace })
            if after.count < 100, isMetaCommentary(String(after)) {
                // Keep text up to and including the punctuation mark (r.lowerBound).
                let throughPunct = line[...r.lowerBound]
                return String(throughPunct).trimmingCharacters(in: .whitespaces)
            }
            searchStart = r.upperBound
        }
    }
    return nil
}
