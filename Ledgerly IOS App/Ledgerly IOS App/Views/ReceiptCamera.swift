import SwiftUI
import VisionKit

struct ReceiptCamera: UIViewControllerRepresentable {
    let onImages: ([Data]) -> Void
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
            guard scan.pageCount > 0, scan.pageCount <= ReceiptPageArchive.maximumPages else {
                parent.onError("Scan between 1 and \(ReceiptPageArchive.maximumPages) pages for one receipt.")
                return
            }
            do {
                let pages = try (0..<scan.pageCount).map { try ReceiptImageStore.normalized(scan.imageOfPage(at: $0)) }
                parent.onImages(pages)
            } catch { parent.onError(error.localizedDescription) }
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
