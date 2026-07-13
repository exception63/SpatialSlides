//
//  ImmersiveView.swift
//  Spatial Slides
//
//  Hosts the ring stage inside the mixed immersive space.
//

import SwiftUI

struct ImmersiveView: View {
    var body: some View {
        StageView()
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
        .environment(PresentationModel())
}
