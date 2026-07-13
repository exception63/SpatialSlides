//
//  ControlBarView.swift
//  Spatial Slides
//
//  A glass control bar that floats in the immersive space and is always
//  reachable — previous / page / next / exit. This is the in-headset remote:
//  it advances the deck even when dense content leaves no empty space to tap,
//  and its exit button ends the presentation (visionOS has no ESC key).
//

import SwiftUI

struct ControlBarView: View {
    @Environment(PresentationModel.self) private var presentation
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        HStack(spacing: 20) {
            Button {
                presentation.previous()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
            .disabled(!presentation.canGoPrevious)

            VStack(spacing: 1) {
                Text(presentation.counterText)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if !presentation.beatLabel.isEmpty {   // #4: this page's attention-beat progress
                    Text("拍 " + presentation.beatLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(presentation.beatsRemaining ? Color(hex: "#FF9F0A") : .secondary)
                }
            }
            .frame(minWidth: 88)

            // Forward: builds the page's remaining beats first, then turns the page.
            Button {
                presentation.advance()
            } label: {
                Image(systemName: presentation.beatsRemaining ? "arrow.forward.circle.fill" : "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
            .disabled(!presentation.canGoNext && !presentation.beatsRemaining)
            .tint(presentation.beatsRemaining ? Color(hex: "#FF9F0A") : nil)

            Divider().frame(height: 30).overlay(.white.opacity(0.25))

            Button {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                    appModel.immersiveSpaceState = .closed
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
            .tint(.red)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
        .glassBackgroundEffect(in: .capsule)
    }
}
