//
//  DesignGalleryView.swift
//  OmWhisper
//
//  Debug-only: renders every D1 Porcelain foundation piece together so they
//  can be checked live before D2 wires them into real hub screens. Whole file
//  gated #if DEBUG, matching Meetings/MeetingSelfTest.swift's convention --
//  this view must not exist in release builds.
//

#if DEBUG
import SwiftUI

struct DesignGalleryView: View {
    @State private var selectedRow = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                SectionHeader(eyebrow: "D1 — Foundations", title: "Design Gallery")

                orbRow
                cardRow
                navRow
            }
            .padding(32)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color.Porcelain.bg)
    }

    private var orbRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Orb — dark HUD vs. Porcelain").font(.headline)
            HStack(spacing: 20) {
                ZStack {
                    Color.omBackground
                    OmOrbView(appState: AppState(), palette: .dark)
                        .frame(width: 64, height: 64)
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                ZStack {
                    Color.Porcelain.bg
                    OmOrbView(appState: AppState(), palette: .porcelain)
                        .frame(width: 64, height: 64)
                }
                .frame(width: 140, height: 140)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.Porcelain.hair))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var cardRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("omCard").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("WORDS TODAY").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.Porcelain.dim)
                Text("1,284").font(.system(size: 40, weight: .bold)).foregroundStyle(Color.Porcelain.numeralGradient)
            }
            .padding(20)
            .frame(width: 220, alignment: .leading)
            .omCard()
        }
    }

    private var navRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NavRow").font(.headline)
            VStack(spacing: 2) {
                NavRow(icon: "house", title: "Home", isSelected: selectedRow == 0)
                    .onTapGesture { selectedRow = 0 }
                NavRow(icon: "clock", title: "History", isSelected: selectedRow == 1)
                    .onTapGesture { selectedRow = 1 }
                NavRow(icon: "person.2", title: "Meetings", isSelected: selectedRow == 2, badge: "S3")
                    .onTapGesture { selectedRow = 2 }
            }
            .frame(width: 220)
            .padding(10)
            .omCard()
        }
    }
}

#Preview {
    DesignGalleryView()
}
#endif
