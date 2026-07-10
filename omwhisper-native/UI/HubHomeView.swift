//
//  HubHomeView.swift
//  OmWhisper
//
//  Placeholder only -- the real dashboard (stats cards, streak line, recent
//  dictations) is D3's job per docs/DESIGN_DIRECTION.md §5 ("New surfaces,"
//  explicitly separate from D2's "migrations"). This exists so Home has
//  somewhere to land as the hub's default selection in D2a.
//

import SwiftUI

struct HubHomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            OmOrbView(appState: appState, palette: .porcelain)
                .frame(width: 64, height: 64)
            Text("The Home dashboard arrives in D3.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Porcelain.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    HubHomeView().environment(AppState())
}
