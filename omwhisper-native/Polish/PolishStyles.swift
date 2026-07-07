//
//  PolishStyles.swift
//  OmWhisper
//
//  Built-in style catalog. 7 styles, not the stale "6" referenced in some
//  older docs — Smart Correct was added later upstream (the old Tauri app's
//  PR #31) and this project's docs hadn't caught up. One canonical prompt per
//  style (not the old app's short/blunt-for-tiny-model variant — Foundation
//  Models is meaningfully more capable than that app's bundled 0.5B GGUF).
//
//  Fixed UUIDs (not `UUID()` per-launch) so `activePolishStyleID` survives
//  relaunches — these are permanent identifiers, never change them.
//

import Foundation

nonisolated enum PolishStyles {
    static let builtIns: [PolishStyle] = [
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000001")!,
            name: "Professional",
            prompt: """
            Rewrite the following dictated text in a formal, polished tone suitable \
            for professional communication. Preserve the original meaning and \
            approximate length. Output only the rewritten text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000002")!,
            name: "Casual",
            prompt: """
            Lightly clean up the following dictated text: remove filler words \
            ("um", "uh", "like") and fix obvious grammar mistakes, but keep \
            contractions and an informal, conversational tone. Output only the \
            cleaned text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000003")!,
            name: "Concise",
            prompt: """
            Rewrite the following dictated text to be 30-50% shorter, using active \
            voice, while preserving every piece of information. Output only the \
            rewritten text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000004")!,
            name: "Translate",
            prompt: """
            Translate the following dictated text into {language}. Preserve the \
            original meaning and tone. Output only the translated text, nothing else.
            """,
            isBuiltIn: true,
            requiresTargetLanguage: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000005")!,
            name: "Email Format",
            prompt: """
            Rewrite the following dictated text as a well-formatted email: add an \
            appropriate greeting and closing, and organize the body into clear \
            paragraphs. Output only the formatted email text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000006")!,
            name: "Meeting Notes",
            prompt: """
            Rewrite the following dictated text as structured meeting notes: use \
            bullet points, section headers where appropriate, and call out action \
            items clearly. Output only the formatted notes, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000007")!,
            name: "Smart Correct",
            prompt: """
            Clean up the following dictated text: remove filler words, fix grammar, \
            and handle spoken self-corrections (e.g. "wait no I meant Tuesday" means \
            replace the earlier day with Tuesday). Preserve the speaker's own voice \
            and wording as closely as possible — do not add content, do not rephrase \
            sentences that are already clean. Output only the corrected text, nothing else.

            Example: "so um the meeting is at 3pm wait no 4pm tomorrow" -> \
            "The meeting is at 4pm tomorrow."
            Example: "I think we should uh go with option B" -> \
            "I think we should go with option B."
            """,
            isBuiltIn: true
        ),
    ]

    static func all(customStyles: [PolishStyle]) -> [PolishStyle] {
        builtIns + customStyles
    }

    static func style(id: UUID, customStyles: [PolishStyle]) -> PolishStyle? {
        all(customStyles: customStyles).first { $0.id == id }
    }
}
