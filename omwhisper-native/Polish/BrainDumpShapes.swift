//
//  BrainDumpShapes.swift
//  OmWhisper
//
//  Built-in target shapes for brain-dump mode. Each shape IS a named structuring
//  prompt (reusing PolishStyle). Fixed UUIDs so activeBrainDumpShapeID survives
//  relaunches. Kept OUT of PolishStyles.builtIns — brain-dump shapes and polish
//  styles are different concepts and never share a picker. The chunk-notes style
//  is hidden (map step of the map-reduce), same pattern as MeetingSummarizer.
//

import Foundation

nonisolated enum BrainDumpShapes {
    static let builtIns: [PolishStyle] = [
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000001")!,
            name: "Email",
            prompt: """
                Turn the following (a rambling spoken brain-dump, or terse notes from \
                one) into a clear, ready-to-send email. Add a subject line only if \
                useful. Keep the user's intent; drop filler and false starts. \
                Output ONLY the email.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000002")!,
            name: "Ticket",
            prompt: """
                Turn the following into a work/bug ticket in markdown with sections: \
                **Summary**, **Steps to reproduce** (numbered), **Expected result**, \
                **Actual result**. Omit a section only if there is genuinely nothing \
                for it. Output ONLY the ticket.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000003")!,
            name: "Outline",
            prompt: """
                Turn the following into a structured markdown outline — nested bullet \
                points grouped by topic. Preserve every distinct idea; drop filler. \
                Output ONLY the outline.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000004")!,
            name: "To-do list",
            prompt: """
                Turn the following into a markdown checklist of concrete, actionable \
                to-do items (`- [ ] …`), one action each, in a sensible order. Drop \
                filler. Output ONLY the list.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000005")!,
            name: "Meeting agenda",
            prompt: """
                Turn the following into a meeting agenda: a one-line purpose, then a \
                numbered list of agenda items (with sub-bullets for talking points \
                where useful). Output ONLY the agenda.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000006")!,
            name: "Journal",
            prompt: """
                Turn the following into a clean first-person journal entry: flowing \
                prose in a few short paragraphs, preserving the user's voice and \
                reflections. Drop filler and false starts. Output ONLY the entry.
                """,
            isBuiltIn: true),
    ]

    /// Hidden map-step style — condenses each chunk of a long ramble to notes so
    /// the reduce (shape) call stays inside SystemLLM's budget. Never shown in a picker.
    static let chunkNotesStyle = PolishStyle(
        id: UUID(uuidString: "F5B0DA00-0000-4000-8000-0000000000FF")!,
        name: "Brain-dump Chunk Notes",
        prompt: """
            Extract the key points and concrete content from this portion of a spoken \
            brain-dump into terse notes (short bullet points). Preserve names, numbers, \
            and specifics. No preamble, just the notes.
            """,
        isBuiltIn: true)

    static func all(customShapes: [PolishStyle]) -> [PolishStyle] {
        builtIns + customShapes
    }

    static func shape(id: UUID, customShapes: [PolishStyle]) -> PolishStyle? {
        all(customShapes: customShapes).first { $0.id == id }
    }
}
