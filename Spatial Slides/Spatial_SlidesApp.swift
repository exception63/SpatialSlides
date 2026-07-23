//
//  Spatial_SlidesApp.swift
//  Spatial Slides
//
//  Created by zhouliying on 10/07/2026.
//

import SwiftUI

@main
struct Spatial_SlidesApp: App {

    @State private var appModel = AppModel()
    @State private var presentation = PresentationModel()
    @State private var spatialBridge = SpatialSlidesBridgeHost()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(presentation)
                .environment(spatialBridge)
                .task {
                    spatialBridge.start()
                    spatialBridge.publish(presentation)
                }
        }
        .windowStyle(.plain)
        .defaultSize(width: 560, height: 760)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .environment(presentation)
                .environment(spatialBridge)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: Binding<ImmersionStyle>(
            get: { appModel.fullImmersion ? .full : .mixed },
            set: { appModel.fullImmersion = !($0 is MixedImmersionStyle) }
        ), in: .mixed, .full)
    }
}
