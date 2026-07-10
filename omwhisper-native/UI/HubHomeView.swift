//
//  HubHomeView.swift
//  OmWhisper
//
//  The real Home dashboard (D3a) -- greeting + streak, three stat cards,
//  a 7-day quiet-reflection bar line, and the last 3 dictations with
//  Copy/Re-polish. See docs/DESIGN_DIRECTION.md §3 and docs/hub-concept.html.
//  Count-up numeral animation and the bar line's "breathing" pulse are
//  deferred to D4 (motion polish) -- this ships correct static values first.
//

import SwiftUI

struct HubHomeView: View {
    @Environment(AppState.self) private var appState

    @State private var stats: HomeStats?
    @State private var recent: [TranscriptionEntry] = []
    @State private var rePolishingID: Int64?
    @State private var copiedID: Int64?
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let stats {
                    statCards(stats)
                    weekBar(stats)
                }
                recentSection
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.Porcelain.bg)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)
            Text(streakSentence)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Porcelain.dim)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: "Good morning."
        case 12..<18: "Good afternoon."
        default: "Good evening."
        }
    }

    private var streakSentence: String {
        guard let stats else { return " " }
        return switch stats.streakDays {
        case 0: "Press ⌘⇧V to start dictating."
        case 1: "You've dictated today — nice start."
        default: "You've spoken instead of typed for \(stats.streakDays) days straight."
        }
    }

    // MARK: Stat cards

    private func statCards(_ stats: HomeStats) -> some View {
        HStack(spacing: 14) {
            statCard(label: "WORDS TODAY", value: "\(stats.wordsToday)")
            statCard(label: "TIME SAVED", value: "\(stats.minutesSavedVsTyping)", suffix: "min")
            statCard(label: "SPEAKING PACE", value: "\(stats.speakingPaceWPM)", suffix: "wpm")
        }
    }

    private func statCard(label: String, value: String, suffix: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Porcelain.dim)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.Porcelain.numeralGradient)
                if let suffix {
                    Text(suffix)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.Porcelain.dim)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omCard()
    }

    // MARK: 7-day bar

    private func weekBar(_ stats: HomeStats) -> some View {
        let maxCount = max(stats.last7DaysWordCounts.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(stats.last7DaysWordCounts.enumerated()), id: \.offset) { _, count in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.Porcelain.emerald.opacity(count == 0 ? 0.12 : 0.55))
                    // Calm ambient breath (skill §2: the field breathes, slowly).
                    // Not tied to any action, so it passes the 40th-dictation test;
                    // static under Reduced Motion.
                    .opacity(breathing && count != 0 && !reduceMotion ? 0.78 : 1.0)
                    .frame(height: max(4, 34 * Double(count) / Double(maxCount)))
            }
        }
        .frame(height: 34, alignment: .bottom)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omCard()
        .onAppear {
            guard !reduceMotion else { return }
            // ponytail: the one non-spring animation — a spring can't loop a
            // breath; a 2.5s autoreversing ease = a ~5s cycle (hub-concept.html
            // `breathebar`). Intentional exception to "one spring".
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)
            if recent.isEmpty {
                Text("Nothing dictated yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Porcelain.dim)
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { entry in
                        recentRow(entry)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private func recentRow(_ entry: TranscriptionEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .foregroundStyle(Color.Porcelain.emerald)
                .frame(width: 28, height: 28)
                .background(Color.Porcelain.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.Porcelain.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(entry.polishStyle ?? entry.source) · \(relativeTime(entry.createdAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Porcelain.dim)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(copiedID == entry.id ? "Copied" : "Copy") { copy(entry) }
                Button(rePolishingID == entry.id ? "Polishing…" : "Re-polish") {
                    Task { await rePolish(entry) }
                }
                .disabled(rePolishingID == entry.id)
            }
            .font(.system(size: 11.5))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.Porcelain.mint)
        }
        .padding(12)
        .omCard()
    }

    private func relativeTime(_ iso8601: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Data

    private func load() async {
        guard let store = appState.historyStore else { return }
        do {
            stats = try store.homeStats()
            recent = try store.fetchPage(offset: 0, limit: 3)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy(_ entry: TranscriptionEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedID = entry.id
    }

    private func rePolish(_ entry: TranscriptionEntry) async {
        rePolishingID = entry.id
        let result = await appState.rePolish(entry.rawText ?? entry.text)
        rePolishingID = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        copiedID = entry.id
    }
}

#Preview {
    HubHomeView().environment(AppState())
}
