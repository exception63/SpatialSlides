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

            Text(presentation.counterText)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .frame(minWidth: 88)

            Button {
                presentation.next()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
            .disabled(!presentation.canGoNext)

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
