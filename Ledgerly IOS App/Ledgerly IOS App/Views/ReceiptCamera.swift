import SwiftUI
import VisionKit

struct ReceiptCamera: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: ReceiptCamera
        init(parent: ReceiptCamera) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let data = scan.pageCount > 0 ? scan.imageOfPage(at: 0).jpegData(compressionQuality: 0.9) : nil
            if let data { parent.onImage(data) }
            else { parent.onError("No receipt image was captured.") }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.onError(error.localizedDescription)
        }
    }
}
