import SwiftUI
import ARKit
import SceneKit

/// Wraps ARSCNView so SwiftUI can display the live ARKit camera feed.
/// The view renders only the camera background — no 3D scene content.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session          // use our session; view won't create its own
        view.scene = SCNScene()         // empty scene — just the camera feed
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
