import SwiftUI

@main
struct SpatialCameraApp: App {
    @State private var cameraModel = SpatialCameraModel()
    @State private var recorder = SpatialRecordingController()

    var body: some Scene {
        WindowGroup {
            SpatialCameraView()
                .environment(cameraModel)
                .environment(recorder)
                .task {
                    cameraModel.start()
                }
        }
    }
}
