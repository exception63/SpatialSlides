import ARKit
import RealityKit
import SpatialBridgeKit
import SwiftUI
import UIKit

struct SpatialARView: UIViewRepresentable {
    @Environment(SpatialCameraModel.self) private var model
    @Environment(SpatialRecordingController.self) private var recorder

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        view.session.run(configuration)
        view.renderOptions.insert(.disableMotionBlur)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.update(
            snapshot: model.snapshot,
            alignmentFrame: model.alignmentFrame,
            calibrationOrigin: model.calibrationOrigin,
            showAlignmentFixture: !recorder.isRecording && !recorder.isPreparing,
            assetURL: model.assetURL(for:),
            modelAssetURLs: model.availableModelAssetURLs,
            reportRenderIssue: model.reportRenderIssue(_:),
            sceneRevision: model.sceneRevision,
            alignmentRevision: model.alignmentRevision
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var arView: ARView?
        private let model: SpatialCameraModel
        private let renderer = SpatialSlidesARSceneRenderer()

        init(model: SpatialCameraModel) {
            self.model = model
        }

        func attach(to view: ARView) {
            arView = view
            renderer.attach(to: view)
        }

        func update(
            snapshot: BridgeSlidesSnapshot?,
            alignmentFrame: SharedAlignmentFrame?,
            calibrationOrigin: SIMD3<Float>?,
            showAlignmentFixture: Bool,
            assetURL: (String) -> URL?,
            modelAssetURLs: [URL],
            reportRenderIssue: @escaping (String) -> Void,
            sceneRevision: Int,
            alignmentRevision: Int
        ) {
            renderer.update(
                snapshot: snapshot,
                alignmentFrame: alignmentFrame,
                calibrationOrigin: calibrationOrigin,
                showAlignmentFixture: showAlignmentFixture,
                assetURL: assetURL,
                modelAssetURLs: modelAssetURLs,
                reportRenderIssue: reportRenderIssue,
                sceneRevision: sceneRevision,
                alignmentRevision: alignmentRevision
            )
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView, model.alignmentFrame == nil else { return }
            let point = recognizer.location(in: arView)
            let query = arView.makeRaycastQuery(
                from: point,
                allowing: .estimatedPlane,
                alignment: .any
            )
            guard let query, let result = arView.session.raycast(query).first else { return }
            let position = result.worldTransform.columns.3
            model.captureCalibrationPoint([position.x, position.y, position.z])
        }
    }
}
